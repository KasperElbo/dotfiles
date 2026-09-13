#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
container="dotfiles-fedora-${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-0}"
image="${DOTFILES_FEDORA_IMAGE:-fedora:44}"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

printf 'Starting disposable Fedora systemd environment from %s\n' "$image"
docker run --detach --name "$container" \
  --privileged --cgroupns=host \
  --tmpfs /run --tmpfs /run/lock \
  --volume /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --volume "$repo_root:/workspace:ro" \
  "$image" /sbin/init >/dev/null

for _ in {1..30}; do
  if docker exec "$container" systemctl show --property=Version >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker exec "$container" systemctl show --property=Version >/dev/null

# The Fedora container is intentionally only the transport. Seed the pieces a
# normal Fedora workstation image already owns so the repository installer is
# tested against its actual system assumptions rather than weakened for CI.
docker exec "$container" dnf --assumeyes install \
  firewalld git sudo shadow-utils >/dev/null
docker exec "$container" systemctl enable --now firewalld.service >/dev/null

create_test_user() {
  local user="$1"
  docker exec "$container" useradd --create-home --shell /bin/bash "$user"
  docker exec "$container" bash -c \
    "printf '%s\\n' '$user ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/$user && chmod 0440 /etc/sudoers.d/$user"
}

create_test_user dotfiles
create_test_user dotfiles-negative

docker exec --user dotfiles --env HOME=/home/dotfiles "$container" \
  git config --global --add safe.directory /workspace

run_as_user() {
  docker exec --user dotfiles \
    --env HOME=/home/dotfiles \
    --env USER=dotfiles \
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

install_command='./install.sh --platform fedora --no-kde --no-latex --non-interactive'

printf '\n==> Invalid package must fail through the real installer\n'
set +e
negative_output="$(run_as_negative_user "$install_command" 2>&1)"
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

printf '\n==> Idempotent rerun\n'
run_as_user "$install_command"
run_as_user './platforms/fedora/scripts/verify.sh'

printf '\n==> Selected-state transition (theme macchiato -> mocha)\n'
run_as_user './install.sh --platform fedora --theme mocha --no-kde --no-latex --non-interactive'
run_as_user "grep -Fxq mocha \"\${XDG_CONFIG_HOME:-\$HOME/.config}/dotfiles/theme\""
run_as_user './platforms/fedora/scripts/verify.sh'

printf '\nFedora disposable real-install sequence passed.\n'
