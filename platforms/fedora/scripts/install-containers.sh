#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/fedora.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/fedora.sh"
# shellcheck source=../lib/containers.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/containers.sh"

target_user="${SUDO_USER:-${USER:-$(id -un)}}"
dry_run="false"
validate_only="false"
api_socket="false"

container_packages=(
  podman
  podman-compose
)

usage() {
  cat <<'EOF'
Usage: ./platforms/fedora/scripts/install-containers.sh [options]

Install the optional, rootless-first Podman container development profile.

Options:
  --api-socket       Enable the rootless Podman API socket (socket-activated,
                     user-scoped) for Docker-compatible client tooling
  --dry-run          Show the containers plan without changing anything
  --validate         Validate an existing containers installation only
  -h, --help         Show this help

Installs podman and podman-compose from Fedora/DNF. Rootless networking
(netavark/aardvark-dns/pasta) and the crun OCI runtime arrive as ordinary DNF
dependencies of podman and are validated at runtime rather than pinned here.
Allocates a subuid/subgid range for the invoking user only if one is not
already present. Does not install Buildah or Skopeo (podman build already
wraps Buildah, and this profile's workflows do not need Skopeo's standalone
registry-inspection features), Docker Engine, or a docker->podman alias.
EOF
}

while (($#)); do
  case "$1" in
  --api-socket)
    api_socket="true"
    shift
    ;;
  --dry-run)
    dry_run="true"
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
    die "Unknown option: $1"
    ;;
  esac
done

if [[ "$dry_run" == "true" && "$validate_only" == "true" ]]; then
  die "--dry-run and --validate cannot be combined"
fi

if [[ "$validate_only" == "true" ]]; then
  exec "$DOTFILES_ROOT/platforms/fedora/scripts/verify-containers.sh"
fi

if [[ "$dry_run" == "true" ]]; then
  subuid_file="${SUBUID_FILE:-/etc/subuid}"
  subgid_file="${SUBGID_FILE:-/etc/subgid}"

  if subid_entry_exists "$subuid_file" "$target_user" &&
    subid_entry_exists "$subgid_file" "$target_user"; then
    subid_plan="$target_user already has a subuid/subgid range; left unchanged"
  else
    subid_plan="allocate a fresh, non-overlapping subuid/subgid range for $target_user"
  fi

  cat <<EOF

Fedora containers (Podman) installation plan
----------------------------------------------

Runtime:              Podman, rootless by default
OCI runtime:           crun (installed as a podman dependency)
Rootless networking:   netavark/aardvark-dns + pasta or slirp4netns
                       (installed as podman dependencies; verified at runtime)
Compose:               podman-compose, used automatically by 'podman compose'
Buildah / Skopeo:      not installed (no concrete value beyond podman here)
Docker Engine/alias:   not installed
Rootless API socket:   $api_socket
subuid/subgid:         $subid_plan

Packages:
$(printf '  %s\n' "${container_packages[@]}")

Steps:
  1. Install the packages listed above with DNF.
  2. Ensure $target_user has a subuid/subgid range (allocate one only if missing).
EOF

  if [[ "$api_socket" == "true" ]]; then
    cat <<'EOF'
  3. Enable the rootless, socket-activated user API socket (podman.socket)
     for $XDG_RUNTIME_DIR/podman/podman.sock. Not exposed over TCP.
EOF
    step=4
  else
    step=3
  fi

  cat <<EOF
  $step. Record the profile in \$XDG_CONFIG_HOME/dotfiles/containers.conf.
  $((step + 1)). Validate rootless pull/run/build, bind mounts, named volumes,
     localhost port publishing, container networking, and Compose end to end.

Does not weaken SELinux or firewalld, does not install Docker Engine, and
does not alias docker to podman.

No changes were made.

EOF
  exit 0
fi

require_fedora

info "Installing Podman container packages"
sudo dnf install -y "${container_packages[@]}"

subuid_file="${SUBUID_FILE:-/etc/subuid}"
subgid_file="${SUBGID_FILE:-/etc/subgid}"

info "Checking subuid/subgid ranges for $target_user"
ensure_subid_ranges "$target_user" "$subuid_file" "$subgid_file"

api_socket_state="disabled"
if [[ "$api_socket" == "true" ]]; then
  info "Enabling the rootless Podman API socket (user-scoped, socket-activated)"
  systemctl --user enable --now podman.socket
  api_socket_state="enabled"
fi

state_file="$XDG_CONFIG_HOME/dotfiles/containers.conf"
ensure_dir "$(dirname "$state_file")"
{
  printf 'profile=containers\n'
  printf 'runtime=podman\n'
  printf 'mode=rootless\n'
  printf 'compose_provider=podman-compose\n'
  printf 'api_socket=%s\n' "$api_socket_state"
  printf 'user=%s\n' "$target_user"
} | atomic_write_file "$state_file"

info "Validating the Fedora containers profile"
if "$DOTFILES_ROOT/platforms/fedora/scripts/verify-containers.sh"; then
  success "Fedora containers profile installed"
else
  warn "Containers packages were installed, but validation reported problems"
  exit 1
fi
