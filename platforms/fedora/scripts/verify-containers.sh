#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/containers.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/containers.sh"

skip_smoke_test="false"
failures=0

# Overridable so tests can point these at a mocked podman without touching a
# real registry, port range, or filesystem.
smoke_image="${PODMAN_SMOKE_IMAGE:-docker.io/library/busybox:stable}"
port_base="${PODMAN_SMOKE_PORT_BASE:-18000}"
subuid_file="${SUBUID_FILE:-/etc/subuid}"
subgid_file="${SUBGID_FILE:-/etc/subgid}"

while (($#)); do
  case "$1" in
  --skip-smoke-test)
    skip_smoke_test="true"
    shift
    ;;
  *)
    printf 'Unknown option: %s\n' "$1" >&2
    exit 2
    ;;
  esac
done

pass() {
  printf '\033[1;32m✓\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m✗\033[0m %s\n' "$*" >&2
  failures=$((failures + 1))
}

warning() {
  printf '\033[1;33m!\033[0m %s\n' "$*" >&2
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

check_command() {
  local command_name="$1"

  if command -v "$command_name" >/dev/null 2>&1; then
    pass "$command_name: $(command -v "$command_name")"
  else
    fail "$command_name not found"
  fi
}

section "Containers commands"
for command_name in podman podman-compose; do
  check_command "$command_name"
done

if ((failures > 0)); then
  exit 1
fi

section "Podman version and rootless status"

if podman_version_output="$(podman version 2>&1)"; then
  pass "podman version"
  printf '%s\n' "$podman_version_output" | sed 's/^/  /'
else
  fail "podman version failed"
fi

rootless_state="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
if [[ "$rootless_state" == "true" ]]; then
  pass "podman info reports rootless execution"
else
  fail "podman info does not report rootless execution (got: ${rootless_state:-unknown})"
fi

network_backend="$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || true)"
if [[ -n "$network_backend" ]]; then
  pass "rootless network backend: $network_backend"
else
  warning "Could not determine the rootless network backend"
fi

section "subuid/subgid mapping"

current_user="$(id -un)"

if subid_entry_exists "$subuid_file" "$current_user"; then
  pass "$current_user has a subuid range in $subuid_file"
else
  fail "$current_user has no subuid range in $subuid_file"
fi

if subid_entry_exists "$subgid_file" "$current_user"; then
  pass "$current_user has a subgid range in $subgid_file"
else
  fail "$current_user has no subgid range in $subgid_file"
fi

section "Rootless API socket"

if systemctl --user is-enabled --quiet podman.socket 2>/dev/null; then
  pass "podman.socket is enabled (socket-activated, user-scoped)"
  if systemctl --user is-active --quiet podman.socket 2>/dev/null; then
    pass "podman.socket is active"
  fi
else
  pass "podman.socket is not enabled (default; enable with --api-socket if needed)"
fi

if ((failures > 0)); then
  printf '\n\033[1;31mContainers verification failed:\033[0m %d failure(s)\n' \
    "$failures"
  exit 1
fi

if [[ "$skip_smoke_test" == "true" ]]; then
  printf '\n\033[1;32mContainers verification passed (smoke test skipped).\033[0m\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# Rootless smoke test: pull, run, build, bind mount, named volume, localhost
# port publishing, container-to-container networking, and Compose. Every
# resource below is uniquely named per run and removed on exit so repeated
# runs never leave containers/images/volumes/networks behind.
# ---------------------------------------------------------------------------

run_id="$$-$RANDOM"
smoke_container="dotfiles-podman-smoke-$run_id"
smoke_server="dotfiles-podman-smoke-server-$run_id"
smoke_volume="dotfiles-podman-smoke-vol-$run_id"
smoke_network="dotfiles-podman-smoke-net-$run_id"
smoke_build_tag="dotfiles-podman-smoke-build-$run_id"
smoke_port=$((port_base + (RANDOM % 500)))
smoke_compose_port=$((port_base + 500 + (RANDOM % 500)))
smoke_build_dir=""
smoke_bind_dir=""
smoke_compose_dir=""

cleanup_smoke_test() {
  podman stop "$smoke_container" >/dev/null 2>&1 || true
  podman stop "$smoke_server" >/dev/null 2>&1 || true
  if [[ -n "$smoke_compose_dir" && -f "$smoke_compose_dir/compose.yaml" ]]; then
    podman compose -f "$smoke_compose_dir/compose.yaml" down -v >/dev/null 2>&1 ||
      true
  fi
  podman network rm -f "$smoke_network" >/dev/null 2>&1 || true
  podman volume rm -f "$smoke_volume" >/dev/null 2>&1 || true
  podman rmi -f "$smoke_build_tag" >/dev/null 2>&1 || true
  [[ -n "$smoke_build_dir" ]] && rm -rf -- "$smoke_build_dir"
  [[ -n "$smoke_bind_dir" ]] && rm -rf -- "$smoke_bind_dir"
  [[ -n "$smoke_compose_dir" ]] && rm -rf -- "$smoke_compose_dir"
}
trap cleanup_smoke_test EXIT

# wait_for_content <times> <expected> <command...>: retries a possibly-not-
# yet-ready check (a freshly started container's port or network listener)
# instead of racing it, and requires the expected body rather than just a
# response — busybox httpd returns 404 for a directory with no index file,
# which a bare "did curl succeed" check would misreport as unreachable.
wait_for_content() {
  local times="$1"
  local expected="$2"
  shift 2

  local attempt output
  for ((attempt = 0; attempt < times; attempt++)); do
    output="$("$@" 2>/dev/null)" && [[ "$output" == "$expected" ]] && return 0
    sleep 0.5
  done
  return 1
}

section "Rootless smoke test"

if podman pull -q "$smoke_image" >/dev/null 2>&1; then
  pass "pull: $smoke_image"
else
  fail "pull failed: $smoke_image"
fi

if podman run --rm "$smoke_image" true >/dev/null 2>&1; then
  pass "run: minimal container executes and exits cleanly"
else
  fail "run failed for $smoke_image"
fi

smoke_build_dir="$(mktemp -d)"
cat >"$smoke_build_dir/Containerfile" <<EOF
FROM $smoke_image
RUN echo dotfiles-podman-smoke > /smoke.txt
EOF

if podman build -q -t "$smoke_build_tag" "$smoke_build_dir" >/dev/null 2>&1 &&
  [[ "$(podman run --rm "$smoke_build_tag" cat /smoke.txt 2>/dev/null)" \
    == "dotfiles-podman-smoke" ]]; then
  pass "build: Containerfile builds and the built image runs"
else
  fail "build failed or the built image did not run as expected"
fi

smoke_bind_dir="$(mktemp -d)"
printf 'dotfiles-podman-smoke\n' >"$smoke_bind_dir/file"

# ':Z' relabels the bind mount for exclusive use by this container. Without
# it, an SELinux-enforcing host denies the container access to the host path.
if [[ "$(podman run --rm -v "$smoke_bind_dir:/data:Z" "$smoke_image" \
  cat /data/file 2>/dev/null)" == "dotfiles-podman-smoke" ]]; then
  pass "bind mount: SELinux-labeled (:Z) host directory is readable"
else
  fail "bind mount test failed"
fi

if podman volume create "$smoke_volume" >/dev/null 2>&1 &&
  podman run --rm -v "$smoke_volume:/data" "$smoke_image" \
    sh -c 'echo dotfiles-podman-smoke > /data/file' >/dev/null 2>&1 &&
  [[ "$(podman run --rm -v "$smoke_volume:/data" "$smoke_image" \
    cat /data/file 2>/dev/null)" == "dotfiles-podman-smoke" ]]; then
  pass "named volume: data persists across containers"
else
  fail "named volume test failed"
fi

# busybox httpd 404s on a directory with no index file, so seed one before
# serving it -- a bare listener with nothing to serve isn't a meaningful
# "is this reachable" check anyway.
serve_smoke_content='mkdir -p /srv && echo dotfiles-podman-smoke > /srv/index.html && httpd -f -p 8080 -h /srv'

if podman run -d --rm --name "$smoke_container" \
  -p "127.0.0.1:$smoke_port:8080" "$smoke_image" \
  sh -c "$serve_smoke_content" >/dev/null 2>&1; then
  if wait_for_content 10 "dotfiles-podman-smoke" \
    curl -fsS "http://127.0.0.1:$smoke_port/"; then
    pass "localhost port publishing: 127.0.0.1:$smoke_port reachable"
  else
    fail "published port 127.0.0.1:$smoke_port never became reachable"
  fi
  podman stop "$smoke_container" >/dev/null 2>&1 || true
else
  fail "could not start the port-publishing smoke container"
fi

if podman network create "$smoke_network" >/dev/null 2>&1 &&
  podman run -d --rm --network "$smoke_network" --name "$smoke_server" \
    "$smoke_image" sh -c "$serve_smoke_content" >/dev/null 2>&1; then
  if wait_for_content 10 "dotfiles-podman-smoke" \
    podman run --rm --network "$smoke_network" "$smoke_image" \
    wget -qO- "http://$smoke_server:8080/"; then
    pass "container networking: name resolution and connectivity via $smoke_network"
  else
    fail "container-to-container networking test failed"
  fi
  podman stop "$smoke_server" >/dev/null 2>&1 || true
else
  fail "could not create the smoke test network or server container"
fi

smoke_compose_dir="$(mktemp -d)"
cat >"$smoke_compose_dir/compose.yaml" <<EOF
services:
  web:
    image: $smoke_image
    command: httpd -f -p 8080 -h /srv
    ports:
      - "127.0.0.1:$smoke_compose_port:8080"
    volumes:
      - smoke-data:/srv
    depends_on:
      - seed
  seed:
    image: $smoke_image
    command: sh -c "echo dotfiles-podman-smoke > /srv/index.html"
    volumes:
      - smoke-data:/srv
volumes:
  smoke-data:
EOF

if podman compose -f "$smoke_compose_dir/compose.yaml" up -d >/dev/null 2>&1; then
  if wait_for_content 10 "dotfiles-podman-smoke" \
    curl -fsS "http://127.0.0.1:$smoke_compose_port/"; then
    pass "compose: multi-service project reachable on 127.0.0.1:$smoke_compose_port"
  else
    fail "compose project never became reachable"
  fi
  podman compose -f "$smoke_compose_dir/compose.yaml" down -v >/dev/null 2>&1
else
  fail "podman compose up failed"
fi

printf '\n'
if ((failures > 0)); then
  printf '\033[1;31mContainers verification failed:\033[0m %d failure(s)\n' \
    "$failures"
  exit 1
fi

printf '\033[1;32mContainers verification passed.\033[0m\n'
