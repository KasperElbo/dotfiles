#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
container="dotfiles-fedora-${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-0}"
# Pinned by digest: this job proves a clean install against one exact base
# image rather than whatever the tag points at today. Bump it together
# with config/network-sources.tsv (validation-image-fedora).
# network-source: validation-image-fedora
base_image="${DOTFILES_FEDORA_IMAGE:-docker.io/library/fedora@sha256:43b29f65a41eb9c35e1cd5323e3bdf3b655c2357a9f4f1ff2f9c2798e5045d80}"
runtime_image="dotfiles-fedora-systemd-${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-0}"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker image rm -f "$runtime_image" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# The official Fedora container image is intentionally minimal and does not
# contain systemd or /sbin/init. Build a disposable derivative instead of
# assuming a workstation-like init system is present in the transport image.
printf 'Building disposable systemd image from %s\n' "$base_image"
docker build \
  --build-arg "BASE_IMAGE=$base_image" \
  --tag "$runtime_image" \
  - <<'EOF_DOCKERFILE' >/dev/null
# network-source: validation-image-fedora
ARG BASE_IMAGE=docker.io/library/fedora@sha256:43b29f65a41eb9c35e1cd5323e3bdf3b655c2357a9f4f1ff2f9c2798e5045d80
FROM ${BASE_IMAGE}
RUN dnf --assumeyes --setopt=install_weak_deps=False install systemd && \
    dnf clean all
STOPSIGNAL SIGRTMIN+3
EOF_DOCKERFILE

printf 'Starting disposable Fedora systemd environment from %s\n' "$runtime_image"
docker run --detach --name "$container" \
  --privileged --cgroupns=host \
  --tmpfs /run --tmpfs /run/lock \
  --volume /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --volume "$repo_root:/workspace:ro" \
  "$runtime_image" /usr/lib/systemd/systemd >/dev/null

systemd_ready=false
for _ in {1..30}; do
  if docker exec "$container" systemctl show --property=Version >/dev/null 2>&1; then
    systemd_ready=true
    break
  fi
  sleep 1
done
if [[ "$systemd_ready" != true ]]; then
  printf 'Fedora systemd environment did not become ready. Container log follows:\n' >&2
  docker logs "$container" >&2 || true
  exit 1
fi

# The Fedora container is intentionally only the transport. Seed the pieces a
# normal Fedora workstation image already owns so the repository installer is
# tested against its actual system assumptions rather than weakened for CI.
#
# D-Bus is one of those pieces. systemd lets root talk to it over its private
# socket, so root systemctl works without a bus, but an unprivileged client
# needs the system bus. The installer's verifier runs as the normal test user,
# so without D-Bus it could not query any system unit and reported firewalld
# inactive. firewalld is itself a D-Bus service, so the broker is seeded and
# started before it.
#
# procps-ng (ps, pgrep) is one more. Every Fedora install carries it and the
# official container image strips it. No Mistakes runs ps itself: its
# installer finishes with `no-mistakes daemon restart`, and the daemon it
# starts is identified through `ps -p <pid> -o lstart=`. The 2026-09-23 run,
# the first to select --ai here, died at "inspect daemon process: exec: \"ps\":
# executable file not found". The user manager seeded below is the other half
# of that failure.
docker exec "$container" dnf --assumeyes install \
  dbus-broker firewalld git procps-ng sudo shadow-utils >/dev/null
docker exec "$container" systemctl daemon-reload
docker exec "$container" systemctl enable --now dbus-broker.service >/dev/null
docker exec "$container" systemctl enable --now firewalld.service >/dev/null

# The same rule again, for the KDE capability. --kde installs each Catppuccin
# global theme with `kpackagetool6 -t Plasma/LookAndFeel -i`, which needs the
# KPackage package structure plugin of that type, and that plugin arrives with
# the Plasma desktop rather than with the tool. A Fedora KDE workstation owns
# it; this transport image owns nothing of Plasma, so the first flavour died at
# "Could not load package structure Plasma/LookAndFeel" on the 2026-09-21
# scheduled run.
#
# It is seeded here rather than declared in the capability's packages because
# --kde themes an existing desktop and must not install one: a machine without
# Plasma is told to install Plasma, and this is where CI becomes such a
# machine. plasma-workspace is the package to name -- the structure plugin and
# plasma-apply-lookandfeel both arrive with it or with something it requires --
# and it is a large transaction, which is part of why this job is slow.
docker exec "$container" dnf --assumeyes install plasma-workspace >/dev/null

# Dolphin, for the same reason and from the same rule. The KDE capability
# exists to make Dolphin's sftp:// locations work, so the Fedora verifier
# requires the file manager on a machine that selected --kde -- and the
# capability declares kio-extras rather than Dolphin, because it must no more
# install the file manager than it installs Plasma.
#
# That check had never run here. It is gated on plasmashell, which nothing in
# this container provided until plasma-workspace was seeded above, so the SFTP
# baseline was quietly skipped rather than verified.
docker exec "$container" dnf --assumeyes install dolphin >/dev/null

# sudo approves an account through pam_unix, which shells out to the setuid
# unix_chkpwd helper whenever it cannot read the shadow entry itself. That
# helper does not work inside a privileged Fedora container on a GitHub-hosted
# Ubuntu runner, so every sudo call in this fixture failed with "PAM account
# management error: Authentication service cannot retrieve authentication info"
# before the installer could reach its package-manager path. This is a known
# container-transport defect (fedora-cloud/docker-brew-fedora#117), not
# installer behavior, so approve container-local accounts from /etc/passwd
# directly. Authorization is still decided by the real sudoers rules below and
# the installer still performs every privileged action through real sudo.
#
# systemd-user is the PAM stack user@.service opens a session through, and it
# takes the same pam_unix account path, so the user manager seeded further
# down gets the same treatment. systemd ships that stack in the vendor
# directory, /usr/lib/pam.d, so the override is written to /etc/pam.d, which
# takes precedence, from whichever copy exists.
docker exec "$container" bash -c \
  'for stack in sudo systemd-user; do
     source_stack="/etc/pam.d/$stack"
     [[ -f "$source_stack" ]] || source_stack="/usr/lib/pam.d/$stack"
     printf "%s\n" "account    sufficient    pam_localuser.so" >"/etc/pam.d/$stack.dotfiles-ci" &&
     cat "$source_stack" >>"/etc/pam.d/$stack.dotfiles-ci" &&
     cat "/etc/pam.d/$stack.dotfiles-ci" >"/etc/pam.d/$stack" &&
     rm -f "/etc/pam.d/$stack.dotfiles-ci" || exit 1
   done'

create_test_user() {
  local user="$1"
  docker exec "$container" useradd --create-home --shell /bin/bash "$user"
  docker exec "$container" bash -c \
    "printf '%s\\n' '$user ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/$user && chmod 0440 /etc/sudoers.d/$user"

  # Fail here with a fixture-specific error instead of letting the installer
  # appear to fail before its package-manager path.
  if ! docker exec --user "$user" --env HOME="/home/$user" \
    "$container" sudo -n -v; then
    printf 'Disposable Fedora user %s does not have working non-interactive sudo.\n' "$user" >&2
    printf 'Container sudo diagnostics follow.\n' >&2
    docker exec "$container" getent passwd "$user" >&2 || true
    docker exec "$container" bash -c \
      "getent shadow '$user' || printf 'no shadow entry for %s\\n' '$user'" >&2 || true
    docker exec "$container" cat /etc/pam.d/sudo >&2 || true
    docker exec "$container" cat "/etc/sudoers.d/$user" >&2 || true
    docker exec --user "$user" --env HOME="/home/$user" \
      "$container" sudo -n -l >&2 || true
    return 1
  fi
}

create_test_user dotfiles
create_test_user dotfiles-negative

# The verifier queries system units as the unprivileged install user. Fail here
# with a fixture-specific error instead of letting that surface later as a
# confusing "firewalld.service is not active" verification failure.
if ! docker exec --user dotfiles --env HOME=/home/dotfiles "$container" \
  systemctl is-active --quiet firewalld.service; then
  printf 'Disposable Fedora container cannot query system units as a normal user.\n' >&2
  printf 'Container D-Bus and service diagnostics follow.\n' >&2
  docker exec "$container" ls -l /run/dbus >&2 || true
  docker exec "$container" systemctl --no-pager --full status dbus-broker.service >&2 || true
  docker exec "$container" systemctl --no-pager --full status firewalld.service >&2 || true
  docker exec --user dotfiles --env HOME=/home/dotfiles "$container" \
    systemctl is-active firewalld.service >&2 || true
  exit 1
fi

# A per-user systemd manager, the last piece a workstation owns. Logging in --
# at the console, in a desktop session or over SSH -- starts user@<uid>.service
# through pam_systemd and points XDG_RUNTIME_DIR at it, and `systemctl --user`
# talks to nothing else. docker exec is not a login, so without this seed every
# user unit the installer or an upstream enables fails at "Failed to connect to
# user scope bus". The No Mistakes installer enables one: it runs the push-gate
# daemon as a systemd user service, and only falls back to a detached process
# when there is no manager. Seeding the manager keeps this job on the path a
# real login takes instead of the fallback.
dotfiles_uid="$(docker exec "$container" id -u dotfiles)"
dotfiles_runtime_dir="/run/user/$dotfiles_uid"
if ! docker exec "$container" systemctl start "user@$dotfiles_uid.service" ||
  ! docker exec --user dotfiles --env HOME=/home/dotfiles \
  --env XDG_RUNTIME_DIR="$dotfiles_runtime_dir" "$container" \
  systemctl --user show --property=Version >/dev/null; then
  printf 'Disposable Fedora container has no working systemd user manager for dotfiles.\n' >&2
  printf 'Container user-manager diagnostics follow.\n' >&2
  docker exec "$container" systemctl --no-pager --full status "user@$dotfiles_uid.service" >&2 || true
  docker exec "$container" journalctl --no-pager -n 50 -u "user@$dotfiles_uid.service" >&2 || true
  docker exec "$container" ls -la "$dotfiles_runtime_dir" >&2 || true
  exit 1
fi

docker exec --user dotfiles --env HOME=/home/dotfiles "$container" \
  git config --global --add safe.directory /workspace

# GITHUB_TOKEN and GH_TOKEN are forwarded for the optional-profile install
# below: two of the AI components resolve their own "latest" release through
# api.github.com, and mise asks the same API about its GitHub-backed tools.
# Unauthenticated that is 60 requests an hour shared with every other tenant on
# the runner's address, which the macOS job has failed on with nothing wrong on
# its own side. Both spellings, because an upstream that reads either finds it.
# They are empty outside CI and the workflow's permissions are contents:read,
# so the token can read this repository and nothing else.
run_as_user() {
  docker exec --user dotfiles \
    --env HOME=/home/dotfiles \
    --env USER=dotfiles \
    --env "XDG_RUNTIME_DIR=$dotfiles_runtime_dir" \
    --env "GITHUB_TOKEN=${GITHUB_TOKEN:-}" \
    --env "GH_TOKEN=${GH_TOKEN:-}" \
    --workdir /workspace \
    "$container" bash -lc "$1"
}

# Use an isolated user and a writable repository copy so the deliberately bad
# package exercises the real installer path without contaminating the clean
# positive-install HOME or modifying the checked-out source tree.
docker exec "$container" cp -a /workspace /tmp/dotfiles-invalid
docker exec "$container" sed -i \
  '/^packages=(/a\  dotfiles-package-that-must-not-exist' \
  /tmp/dotfiles-invalid/platforms/fedora/scripts/install-system.sh
docker exec "$container" chown -R dotfiles-negative:dotfiles-negative /tmp/dotfiles-invalid

after_negative_cleanup() {
  docker exec "$container" rm -rf /tmp/dotfiles-invalid >/dev/null 2>&1 || true
}

run_as_negative_user() {
  docker exec --user dotfiles-negative \
    --env HOME=/home/dotfiles-negative \
    --env USER=dotfiles-negative \
    --env XDG_CONFIG_HOME=/home/dotfiles-negative/.config \
    --env XDG_DATA_HOME=/home/dotfiles-negative/.local/share \
    --env XDG_STATE_HOME=/home/dotfiles-negative/.local/state \
    --workdir /tmp/dotfiles-invalid \
    "$container" bash -lc "$1"
}

# --kde and --sway are selected rather than left to detection so this sequence
# is the real-installation evidence config/capabilities.tsv claims for them:
# a capability that is never selected here is never installed or verified end
# to end, whatever its verifier mentions. --latex stays off and says so in the
# registry's ci_scope column, because TeX Live is gigabytes on every run.
#
# The optional profiles are selected in the positive sequence only. Their rows
# claimed real-installation evidence while nothing on this platform had ever
# passed their flags: the check that was meant to catch that read one flat set
# of flags for every platform, so the macOS job's --ocaml and --ai satisfied
# the Fedora and Fedora WSL rows too. The negative case keeps the base command,
# because what it proves is that an invalid package stops the installer, and
# installing an AI profile first would only make it slower to prove.
#
# Which is why its flags are not evidence for anything. This run is asserted to
# *fail*, so --kde and --sway here install neither; counting them let the
# positive sequence drop --kde with fedora/kde still passing, on the strength
# of a run that never completed. The annotation is what scripts/
# validate-capabilities.py reads to leave this invocation out of the walk.
# ci-selection: not-an-installation an injected invalid package aborts this run
base_command='./install.sh --platform fedora --kde --sway --no-latex --non-interactive'
install_command='./install.sh --platform fedora --kde --sway --no-latex \
  --ocaml --ai --codex --firstmate --gnhf --backpass --non-interactive'

printf '\n==> Invalid package must fail through the real installer\n'
set +e
negative_output="$(run_as_negative_user "$base_command" 2>&1)"
negative_status=$?
set -e
printf '%s\n' "$negative_output"
if ((negative_status == 0)); then
  printf 'Installer unexpectedly succeeded with a deliberately invalid Fedora package.\n' >&2
  exit 1
fi
if ! grep -Fq 'dotfiles-package-that-must-not-exist' <<<"$negative_output"; then
  printf 'Installer failed before reaching the injected invalid Fedora package.\n' >&2
  exit 1
fi
printf 'PASS: invalid Fedora package failure propagates through the real installer.\n'
after_negative_cleanup

printf '\n==> Clean Fedora installation\n'
run_as_user "$install_command"

printf '\n==> Independent Fedora verifier\n'
run_as_user './platforms/fedora/scripts/verify.sh'

# The declared verifier of the dev-workflows capability, run against the real
# installation: .NET, Angular/TypeScript, Python and JSON with the mise
# runtimes, Neovim and Mason inventory the installer actually provisioned. It
# runs from a fresh Zsh login, the environment a user runs it from, because
# a workflow whose toolchain is not on PATH reports SKIP rather than running.
printf '\n==> Installed development workflow smoke tests\n'
run_as_user "zsh -lic './scripts/test-dev-workflows.sh --all'"

printf '\n==> Idempotent rerun\n'
run_as_user "$install_command"
run_as_user './platforms/fedora/scripts/verify.sh'

printf '\n==> Selected-state transition (theme macchiato -> mocha)\n'
run_as_user "$install_command --theme mocha"
run_as_user "grep -Fxq mocha \"\${XDG_CONFIG_HOME:-\$HOME/.config}/dotfiles/theme\""
run_as_user './platforms/fedora/scripts/verify.sh'

printf '\nFedora disposable real-install sequence passed.\n'
