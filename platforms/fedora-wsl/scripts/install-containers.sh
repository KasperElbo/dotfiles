#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/wsl.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/wsl.sh"
# shellcheck source=../lib/containers.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/containers.sh"

dry_run="false"
validate_only="false"
forwarded_args=()

usage() {
  cat <<'EOF'
Usage: ./platforms/fedora-wsl/scripts/install-containers.sh [options]

Install the optional, rootless-first Podman container development profile
inside Fedora WSL. This is a thin WSL preflight wrapper around Fedora's own
platforms/fedora/scripts/install-containers.sh, which does the actual
package install, subuid/subgid, API socket, and verification work: none of
that logic is WSL-specific. What differs under WSL is the preconditions --
this profile requires systemd as PID 1 AND a reachable systemd --user
session (unlike the rest of the Fedora WSL profile, where systemd is
optional -- and PID 1 alone is not enough, see README.md's "Podman
containers under WSL"), cgroup v2, and unprivileged user namespaces, and
checks all four before making any change.

Options:
  --api-socket       Enable the rootless Podman API socket (socket-activated,
                     user-scoped) for Docker-compatible client tooling
  --dry-run          Show the containers plan without changing anything
  --validate         Validate an existing containers installation only
  -h, --help         Show this help
EOF
}

while (($#)); do
  case "$1" in
  --dry-run)
    dry_run="true"
    forwarded_args+=("$1")
    shift
    ;;
  --validate)
    validate_only="true"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    forwarded_args+=("$1")
    shift
    ;;
  esac
done

if [[ "$dry_run" == "true" && "$validate_only" == "true" ]]; then
  die "--dry-run and --validate cannot be combined"
fi

if [[ "$validate_only" == "true" ]]; then
  exec "$DOTFILES_ROOT/platforms/fedora-wsl/scripts/verify-containers.sh"
fi

if [[ "$dry_run" == "true" ]]; then
  cat <<'EOF'

Fedora WSL containers preflight
--------------------------------

Requires (checked before any change is made, not shown as a plan item
below since none of them install or configure anything):
  - systemd as PID 1 (podman.socket and rootless cgroup v2 delegation both
    need a real systemd --user instance; unlike the rest of this WSL
    profile, this is a hard requirement here)
  - a reachable systemd --user session (D-Bus bus). PID 1 alone is not
    enough: WSL does not open a full login/PAM session by default, so
    enable it once with 'sudo loginctl enable-linger "$(id -un)"' and
    restart this WSL distribution if this check fails.
  - cgroup v2 unified hierarchy
  - unprivileged user namespaces enabled

Reuses Fedora's own containers profile unchanged for everything else
(packages, subuid/subgid, API socket, verification). See below.

EOF
  exec "$DOTFILES_ROOT/platforms/fedora/scripts/install-containers.sh" \
    "${forwarded_args[@]}"
fi

require_wsl_containers_prereqs

exec "$DOTFILES_ROOT/platforms/fedora/scripts/install-containers.sh" \
  "${forwarded_args[@]}"
