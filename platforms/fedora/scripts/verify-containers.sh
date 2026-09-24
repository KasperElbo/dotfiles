#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/verify.sh"
# shellcheck source=../../../common/lib/install-lifecycle.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/install-lifecycle.sh"
# shellcheck source=../lib/containers.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/containers.sh"

verify_reset

skip_smoke_test="false"

# Overridable so tests can point these at a mocked podman without touching a
# real registry, port range, or filesystem.
#
# The smoke image is pinned by manifest-list digest, not by the :stable tag it
# was taken from. A tag is a moving reference, so the same verification run
# could pull different content on two machines, and restoring "the state before
# the run" would be meaningless when the thing restored is not the thing that
# was there. A digest makes the pull reproducible and makes the restore exact.
# network-source: smoke-image-busybox
smoke_image="${PODMAN_SMOKE_IMAGE:-docker.io/library/busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662}"
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

section "Containers commands"
for command_name in podman podman-compose; do
  check_command "$command_name"
done

if ((VERIFY_FAILURES > 0)); then
  finish_verification "Containers verification"
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

# ---------------------------------------------------------------------------
# Rootless API socket
#
# The installer records the requested socket selection as api_socket= in the
# containers profile state, so verification compares observed state against
# that recorded intent instead of accepting either outcome. Only the
# user-scoped unit counts: a system-scoped podman.socket is a root-owned,
# Docker-compatible endpoint that this rootless profile never requests and
# that a rootless client does not use, so it can never satisfy the
# requirement. Every query here is read-only; nothing is enabled or started.
# ---------------------------------------------------------------------------

section "Rootless API socket"

containers_state="${CONTAINERS_STATE_FILE:-$XDG_CONFIG_HOME/dotfiles/containers.conf}"
api_socket_intent=""
api_socket_running="false"

user_socket_enabled() {
  systemctl --user is-enabled --quiet podman.socket 2>/dev/null
}

user_socket_active() {
  systemctl --user is-active --quiet podman.socket 2>/dev/null
}

# Reported only to explain a user-socket failure: an operator who enabled the
# system unit needs to be told why it does not count, rather than seeing a
# bare "not enabled" next to a socket they know exists.
system_socket_present() {
  systemctl is-enabled --quiet podman.socket 2>/dev/null ||
    systemctl is-active --quiet podman.socket 2>/dev/null
}

# The path the unit actually listens on, read from the unit rather than
# assumed. A socket unit can be overridden with a different ListenStream, and a
# check that stats a path the unit does not use would report on a file nobody
# talks to while the real endpoint went unlooked at.
user_socket_listen_path() {
  local line value
  while IFS= read -r line; do
    value="${line#Listen=}"
    [[ "$value" != "$line" ]] || continue
    # systemd spells this "Listen=/run/user/1000/podman/podman.sock (Stream)".
    value="${value% (*}"
    [[ "$value" == /* ]] || continue
    printf '%s\n' "$value"
    return 0
  done < <(systemctl --user show podman.socket --property=Listen 2>/dev/null)
  return 1
}

if [[ -e "$containers_state" ]]; then
  if api_socket_intent="$(profile_state_read "$containers_state" api_socket \
    containers 2>/dev/null)"; then
    case "$api_socket_intent" in
    enabled | required | true) api_socket_intent="enabled" ;;
    disabled | not-required | false) api_socket_intent="disabled" ;;
    *) api_socket_intent="unknown" ;;
    esac
  else
    api_socket_intent="unknown"
  fi

  if [[ "$api_socket_intent" == "unknown" ]]; then
    fail "recorded containers state is missing or invalid api_socket in" \
      "$containers_state; re-run ./scripts/install-containers.sh" \
      "[--api-socket] to re-record the profile"
  fi
elif [[ -f "$(install_state_path)" ]] &&
  install_capabilities="$(profile_state_read "$(install_state_path)" \
    requested_capabilities install 2>/dev/null)" &&
  [[ ",$install_capabilities," == *,containers,* ]]; then
  api_socket_intent="unknown"
  fail "the containers profile is selected in $(install_state_path) but" \
    "$containers_state is missing; re-run ./scripts/install-containers.sh" \
    "[--api-socket] to re-record the profile"
else
  api_socket_intent="unrecorded"
  not_observed "no containers profile selection is recorded in" \
    "$containers_state; the rootless API socket cannot be checked against a" \
    "recorded intent (run ./scripts/install-containers.sh to record one)"
fi

case "$api_socket_intent" in
enabled)
  if ! user_socket_enabled; then
    if system_socket_present; then
      fail "api_socket=enabled was recorded, but the user-scoped" \
        "podman.socket is not enabled; a system-scoped podman.socket is" \
        "present and does not satisfy this rootless profile -- run:" \
        "systemctl --user enable --now podman.socket"
    else
      fail "api_socket=enabled was recorded, but 'systemctl --user" \
        "is-enabled podman.socket' does not report it enabled -- run:" \
        "systemctl --user enable --now podman.socket"
    fi
  elif ! user_socket_active; then
    fail "podman.socket is enabled but not active for the user, so the" \
      "recorded API socket is not usable -- run: systemctl --user start" \
      "podman.socket"
  else
    pass "podman.socket is enabled and active for the user" \
      "(socket-activated, user-scoped), as recorded"
    api_socket_running="true"
  fi
  ;;
disabled)
  if user_socket_enabled; then
    # Reconciliation is not part of this profile's contract: the socket may
    # have been enabled deliberately after installation. Report the drift
    # without failing a machine that is otherwise exactly as recorded.
    warning "api_socket=disabled was recorded, but the user-scoped" \
      "podman.socket is enabled; re-run ./scripts/install-containers.sh" \
      "--api-socket to record it, or: systemctl --user disable --now" \
      "podman.socket"
  else
    pass "podman.socket is not enabled, as recorded (api_socket=disabled)"
  fi
  ;;
esac

# ---------------------------------------------------------------------------
# API socket ownership and mode
#
# The socket this profile enables is the one thing it installs that is
# equivalent to shell access: anything that can talk to it can run a container
# with an arbitrary bind mount. Up to here the section reads a systemd unit
# state, which says the endpoint is running and nothing about the shape it is
# running in -- the same proxy-instead-of-property gap verify_terra_trust_root
# and the hardening drop-in checks were changed to close. In the default
# rootless layout the socket sits under an $XDG_RUNTIME_DIR that systemd
# creates 0700 and owns, so this is expected to pass everywhere; it is here so
# that a non-default runtime directory, a unit overridden with another
# ListenStream or SocketMode, or a distribution change is noticed rather than
# assumed away. A path that cannot be resolved or stat'd is unobserved, not a
# failure, the way the rest of this file treats a state it cannot read.
# ---------------------------------------------------------------------------

if [[ "$api_socket_running" == "true" ]]; then
  section "API socket ownership and mode"

  # Owner reads have no portable stat spelling the way verify_file_mode gives
  # the mode one, and this verifier is Fedora's, so GNU stat is the primary
  # with the BSD form behind it for a shared-library move later.
  api_socket_owner_of() {
    stat -c '%U' "$1" 2>/dev/null || stat -f '%Su' "$1" 2>/dev/null || true
  }

  if api_socket_path="$(user_socket_listen_path)"; then
    api_socket_path_source="systemctl --user show podman.socket"
  else
    api_socket_path="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
    api_socket_path_source="the default rootless layout"
  fi

  api_socket_owner="$(api_socket_owner_of "$api_socket_path")"

  if [[ ! -S "$api_socket_path" ]]; then
    not_observed "podman.socket is active but $api_socket_path" \
      "($api_socket_path_source) is not a socket, so its owner and mode" \
      "cannot be checked"
  elif ! api_socket_mode="$(verify_file_mode "$api_socket_path")" ||
    [[ -z "$api_socket_owner" ]]; then
    not_observed "podman.socket is active but the owner and mode of" \
      "$api_socket_path could not be read, so they cannot be checked"
  else
    # The owner is compared by name rather than with [[ -O ]] so the check can
    # say what it saw: a verifier that reports "wrong owner" without naming the
    # owner leaves the reader to go and run stat themselves.
    if [[ "$api_socket_owner" != "$current_user" ]]; then
      fail "$api_socket_path is owned by $api_socket_owner, not" \
        "$current_user; a rootless API socket this user does not own is not" \
        "the endpoint this profile enabled"
    elif ((8#$api_socket_mode & 8#7)); then
      fail "$api_socket_path is mode $api_socket_mode, which is open to every" \
        "user on this machine; anything that can reach it can run a container" \
        "with an arbitrary bind mount -- expected 0660 or narrower"
    elif (((8#$api_socket_mode & 8#70) > 8#60)); then
      fail "$api_socket_path is mode $api_socket_mode, which grants its group" \
        "more than read and write -- expected 0660 or narrower"
    else
      pass "$api_socket_path ($api_socket_path_source) is owned by" \
        "$api_socket_owner, mode $api_socket_mode"
    fi

    api_socket_dir="$(dirname -- "$api_socket_path")"
    if ! api_socket_dir_mode="$(verify_file_mode "$api_socket_dir")"; then
      not_observed "the mode of $api_socket_dir could not be read, so the" \
        "directory holding the API socket cannot be checked"
    elif ((8#$api_socket_dir_mode & 8#77)); then
      fail "$api_socket_dir is mode $api_socket_dir_mode, so users other than" \
        "$current_user can reach the API socket inside it -- expected 0700"
    else
      pass "$api_socket_dir is mode $api_socket_dir_mode, so the API socket" \
        "is reachable by $current_user only"
    fi
  fi
fi

if ((VERIFY_FAILURES > 0)); then
  finish_verification "Containers verification"
  exit 1
fi

if [[ "$skip_smoke_test" == "true" ]]; then
  printf '\n'
  pass "container smoke test skipped (--skip-smoke-test); inspection only"
  finish_verification "Containers verification"
  exit $?
fi

# ---------------------------------------------------------------------------
# Rootless smoke test: pull, run, build, bind mount, named volume, localhost
# port publishing, container-to-container networking, and Compose. Every
# resource below is uniquely named per run and removed on exit so repeated
# runs never leave containers/images/volumes/networks behind.
#
# The pinned smoke image is the one resource this run does not name itself, so
# it gets the only treatment that can leave local image storage as it found it:
# record whether it was already present, and afterwards remove it only if this
# run is what introduced it. A machine that already had the image keeps it
# (removing it would be a mutation in the other direction, and would make the
# next run pull again); a machine that did not, ends the run without it.
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

smoke_image_id() {
  podman image inspect --format '{{.Id}}' "$smoke_image" 2>/dev/null || true
}

smoke_image_present() {
  podman image exists "$smoke_image" >/dev/null 2>&1
}

# Read before anything is pulled, so the run knows which of the two restores it
# owes: remove what it introduced, or leave what was already there alone.
if smoke_image_present; then
  smoke_image_was_present="true"
  smoke_image_id_before="$(smoke_image_id)"
else
  smoke_image_was_present="false"
  smoke_image_id_before=""
fi

# Idempotent: the cleanup trap calls this on every exit path, and the reporting
# block below calls it once more so the run can say what it restored.
restore_smoke_image() {
  [[ "$smoke_image_was_present" == "false" ]] || return 0
  smoke_image_present || return 0
  podman rmi -f "$smoke_image" >/dev/null 2>&1 || true
}

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
  restore_smoke_image
}

# Restore, then re-raise so the caller still sees the interruption it sent.
# Bash runs an EXIT trap for TERM and HUP too, so those two are named for the
# same reason platforms/macos/scripts/verify.sh names them: the restore should
# not rest on that. SIGINT is the one that does not work without a handler --
# a Ctrl-C reaches the whole foreground process group, the podman it landed on
# exits on its own, and bash then sees a child that was not killed by SIGINT,
# discards the interrupt, and runs the rest of the smoke test. Without this an
# interrupted verification keeps pulling and building and finishes as though
# nothing had happened.
on_smoke_signal() {
  cleanup_smoke_test
  trap - INT TERM HUP EXIT
  kill -s "$1" "$$"
}
trap cleanup_smoke_test EXIT
trap 'on_smoke_signal INT' INT
trap 'on_smoke_signal TERM' TERM
trap 'on_smoke_signal HUP' HUP

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

# An image this machine already has is not re-fetched: the probe then reaches
# neither the network nor image storage, which is the strongest way to keep the
# reference naming the image it named before. Only a machine that does not have
# it pulls, and that is the pull this run owes a removal for.
if [[ "$smoke_image_was_present" == "true" ]]; then
  pass "pull: $smoke_image is already in local image storage and is not" \
    "re-fetched"
elif podman pull -q "$smoke_image" >/dev/null 2>&1; then
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

# not-a-staged-installer: this repository's own script, run inside the container.
if podman run -d --rm --name "$smoke_container" \
  -p "127.0.0.1:$smoke_port:8080" "$smoke_image" \
  sh -c "$serve_smoke_content" >/dev/null 2>&1; then
  if wait_for_content 10 "dotfiles-podman-smoke" \
    curl -fsS "http://127.0.0.1:$smoke_port/"; then # network-source: local-only
    pass "localhost port publishing: 127.0.0.1:$smoke_port reachable"
  else
    fail "published port 127.0.0.1:$smoke_port never became reachable"
  fi
  podman stop "$smoke_container" >/dev/null 2>&1 || true
else
  fail "could not start the port-publishing smoke container"
fi

if podman network create "$smoke_network" >/dev/null 2>&1 &&
  # not-a-staged-installer: the same script, inside the container.
  podman run -d --rm --network "$smoke_network" --name "$smoke_server" \
    "$smoke_image" sh -c "$serve_smoke_content" >/dev/null 2>&1; then
  if wait_for_content 10 "dotfiles-podman-smoke" \
    podman run --rm --network "$smoke_network" "$smoke_image" \
    wget -qO- "http://$smoke_server:8080/"; then # network-source: local-only
    pass "container networking: name resolution and connectivity via $smoke_network"
  else
    fail "container-to-container networking test failed"
  fi
  podman stop "$smoke_server" >/dev/null 2>&1 || true
else
  fail "could not create the smoke test network or server container"
fi

smoke_compose_dir="$(mktemp -d)"
# No depends_on: podman-compose implements it via 'podman wait --condition=...'
# on the dependency container, which never resolves once a fast-exiting
# one-shot job like 'seed' has already finished before the wait starts --
# it blocks on a state *transition* that will never happen again, hanging
# 'podman compose up -d' indefinitely. Starting both services concurrently
# and letting wait_for_content's retry below absorb the brief race (web may
# 404 for a moment until seed writes its file) avoids that hang entirely.
cat >"$smoke_compose_dir/compose.yaml" <<EOF
services:
  web:
    image: $smoke_image
    command: httpd -f -p 8080 -h /srv
    ports:
      - "127.0.0.1:$smoke_compose_port:8080"
    volumes:
      - smoke-data:/srv
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
    curl -fsS "http://127.0.0.1:$smoke_compose_port/"; then # network-source: local-only
    pass "compose: multi-service project reachable on 127.0.0.1:$smoke_compose_port"
  else
    fail "compose project never became reachable"
  fi
  podman compose -f "$smoke_compose_dir/compose.yaml" down -v >/dev/null 2>&1
else
  fail "podman compose up failed"
fi

# ---------------------------------------------------------------------------
# Local image state
#
# The restore itself also runs from the cleanup trap, so this section exists to
# report it: a verifier that quietly puts things back leaves no evidence that it
# did, and "verification left no trace" is a claim the docs make on this
# script's behalf. Running it here rather than only in the trap is also what
# lets a restore that did not work be said out loud, instead of the image
# quietly staying on the machine.
# ---------------------------------------------------------------------------

section "Local image state"

restore_smoke_image

if [[ "$smoke_image_was_present" == "true" ]]; then
  smoke_image_id_after="$(smoke_image_id)"
  if [[ -z "$smoke_image_id_before" ]]; then
    not_observed "the smoke image was already present before this run, but its" \
      "image ID could not be read, so this run cannot show that it is unchanged"
  elif [[ "$smoke_image_id_after" == "$smoke_image_id_before" ]]; then
    pass "smoke image was already present and is kept, unchanged at" \
      "$smoke_image_id_after"
  else
    fail "the smoke image was $smoke_image_id_before before this run and is" \
      "${smoke_image_id_after:-gone} after it; verification was supposed to" \
      "leave an image it did not introduce alone"
  fi
elif smoke_image_present; then
  # A failure here would be a verdict on the verifier's housekeeping rather
  # than on the machine's containers profile, which is what this script is
  # being asked about. The image is still there either way, so say so and name
  # the command, as platforms/macos/scripts/verify.sh does.
  warning "verification pulled $smoke_image and could not remove it again;" \
    "remove it with: podman rmi -f $smoke_image"
else
  pass "smoke image was introduced by this run and has been removed again;" \
    "local image storage is as it was found"
fi

finish_verification "Containers verification"
