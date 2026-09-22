#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap

# The verifier's smoke image is pinned by digest in config/network-sources.tsv,
# and validate-network-sources.py already requires the verifier to name that
# exact digest. Deriving the reference here rather than repeating the digest
# keeps a deliberate bump to one file, while still failing this suite if the
# verifier is ever unpinned back to a moving tag.
smoke_image_digest="$(awk -F'\t' '$1 == "smoke-image-busybox" { print $9 }' \
  "$repo_root/config/network-sources.tsv")"
if [[ "$smoke_image_digest" != sha256:* ]]; then
  printf 'smoke-image-busybox is not pinned to a digest: %s\n' \
    "$smoke_image_digest" >&2
  exit 1
fi
smoke_image_ref="docker.io/library/busybox@$smoke_image_digest"

# The store lines the stub writes, as the verifier's own reference names them.
smoke_image_in_store() {
  grep -qF "$smoke_image_ref"$'\t' "$1/podman-images" 2>/dev/null
}

# The acceptance criterion is that nothing the run created survives any exit
# path, so this reads the stub's own stores rather than the verifier's output.
assert_no_smoke_resources() {
  local root="$1"
  local leftovers
  leftovers="$(cat "$root/podman-resources" 2>/dev/null)"
  if [[ -n "$leftovers" ]]; then
    printf 'containers, volumes, networks or Compose projects survived:\n%s\n' \
      "$leftovers" >&2
    exit 1
  fi
  if grep -q 'dotfiles-podman-smoke-build-' "$root/podman-images" 2>/dev/null; then
    printf 'the built smoke image survived:\n%s\n' \
      "$(cat "$root/podman-images")" >&2
    exit 1
  fi
}

assert_no_temporary_files() {
  local root="$1"
  local leftovers
  leftovers="$(find "$root/tmp" -mindepth 1 2>/dev/null)"
  if [[ -n "$leftovers" ]]; then
    printf 'temporary files survived the run:\n%s\n' "$leftovers" >&2
    exit 1
  fi
}

new_test_root() {
  test_new_root
  test_root="$TEST_ROOT"

  local mock_bin="$test_root/bin"
  mkdir -p "$test_root/etc"
  : >"$test_root/subuid"
  : >"$test_root/subgid"
  : >"$test_root/user-enabled-units"
  : >"$test_root/user-active-units"
  : >"$test_root/system-enabled-units"
  : >"$test_root/system-active-units"
  : >"$test_root/commands.log"
  # Local image storage, modelled as "<reference>\t<image id>" per line. The
  # verifier's restore is a claim about this store, so a stub that always
  # answered "the image is there" (or always "it is not") could not tell a
  # working restore from a broken one.
  : >"$test_root/podman-images"
  # Volumes, networks and Compose projects the run created and has not removed.
  : >"$test_root/podman-resources"
  mkdir -p "$test_root/tmp"

  # DNF uses the shared exact-argv contract so renamed packages or unexpected
  # package-manager flags fail this high-risk installer suite immediately.
  test_stub_init "$test_root"
  test_stub_install "$test_root" dnf
  test_stub_install "$test_root" sudo
  test_stub_install "$test_root" systemctl
  test_stub_allow "$test_root" dnf install -y podman podman-compose
  test_stub_allow "$test_root" sudo dnf install -y podman podman-compose
  test_stub_allow "$test_root" sudo usermod --add-subuids 100000-165535 tester
  test_stub_allow "$test_root" sudo usermod --add-subgids 100000-165535 tester
  test_stub_allow "$test_root" sudo usermod --add-subuids 165536-231071 tester
  test_stub_allow "$test_root" sudo usermod --add-subgids 165536-231071 tester
  test_stub_allow "$test_root" systemctl --user enable --now podman.socket
  test_stub_allow "$test_root" systemctl --user is-enabled --quiet podman.socket
  test_stub_allow "$test_root" systemctl --user is-active --quiet podman.socket
  # The verifier only consults the system scope to explain why a system-scoped
  # socket does not satisfy the user-scoped requirement; it is never enabled.
  test_stub_allow "$test_root" systemctl is-enabled --quiet podman.socket
  test_stub_allow "$test_root" systemctl is-active --quiet podman.socket

  cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$mock_bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
-un) printf 'tester\n' ;;
*) printf 'tester\n' ;;
esac
EOF

  cat >"$mock_bin/usermod" <<'EOF'
#!/usr/bin/env bash
printf 'usermod %s\n' "$*" >>"$COMMAND_LOG"

subuid_range=""
subgid_range=""
user=""

while (($#)); do
  case "$1" in
  --add-subuids)
    subuid_range="$2"
    shift 2
    ;;
  --add-subgids)
    subgid_range="$2"
    shift 2
    ;;
  *)
    user="$1"
    shift
    ;;
  esac
done

if [[ -n "$subuid_range" ]]; then
  start="${subuid_range%-*}"
  end="${subuid_range#*-}"
  printf '%s:%s:%s\n' "$user" "$start" "$((end - start + 1))" >>"$SUBUID_FILE"
fi

if [[ -n "$subgid_range" ]]; then
  start="${subgid_range%-*}"
  end="${subgid_range#*-}"
  printf '%s:%s:%s\n' "$user" "$start" "$((end - start + 1))" >>"$SUBGID_FILE"
fi
EOF

  cat >"$test_root/handlers/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"
exec "$@"
EOF

  cat >"$test_root/handlers/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$COMMAND_LOG"

if [[ $# -eq 4 && "$1" == --user && "$2" == enable &&
  "$3" == --now && "$4" == podman.socket ]]; then
  grep -qx podman.socket "$USER_ENABLED_UNITS" 2>/dev/null ||
    printf 'podman.socket\n' >>"$USER_ENABLED_UNITS"
  grep -qx podman.socket "$USER_ACTIVE_UNITS" 2>/dev/null ||
    printf 'podman.socket\n' >>"$USER_ACTIVE_UNITS"
  exit 0
fi

if [[ $# -eq 4 && "$1" == --user && "$2" == is-enabled &&
  "$3" == --quiet && "$4" == podman.socket ]]; then
  grep -qx podman.socket "$USER_ENABLED_UNITS" 2>/dev/null
  exit $?
fi

if [[ $# -eq 4 && "$1" == --user && "$2" == is-active &&
  "$3" == --quiet && "$4" == podman.socket ]]; then
  grep -qx podman.socket "$USER_ACTIVE_UNITS" 2>/dev/null
  exit $?
fi

if [[ $# -eq 3 && "$1" == is-enabled && "$2" == --quiet &&
  "$3" == podman.socket ]]; then
  grep -qx podman.socket "$SYSTEM_ENABLED_UNITS" 2>/dev/null
  exit $?
fi

if [[ $# -eq 3 && "$1" == is-active && "$2" == --quiet &&
  "$3" == podman.socket ]]; then
  grep -qx podman.socket "$SYSTEM_ACTIVE_UNITS" 2>/dev/null
  exit $?
fi

printf 'strict systemctl fixture rejected unsupported argv: %s\n' "$*" >&2
exit 96
EOF

  cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$COMMAND_LOG"
if [[ $# -ne 2 || "$1" != -fsS || "$2" != http://127.0.0.1:*/* ]]; then
  printf 'strict curl fixture rejected unsupported argv: %s\n' "$*" >&2
  exit 96
fi
if [[ "${MOCK_CURL_EXIT:-0}" == 0 ]]; then
  printf '%s' "${MOCK_CURL_OUTPUT-dotfiles-podman-smoke}"
fi
exit "${MOCK_CURL_EXIT:-0}"
EOF

  cat >"$mock_bin/podman-compose" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$mock_bin/podman" <<'EOF'
#!/usr/bin/env bash
printf 'podman %s\n' "$*" >>"$COMMAND_LOG"

image_store_id() {
  local line
  line="$(grep -F "$1"$'\t' "$PODMAN_IMAGE_STORE" 2>/dev/null | head -1)" || true
  [[ -n "$line" ]] || return 1
  printf '%s\n' "${line#*$'\t'}"
}

image_store_set() {
  image_store_remove "$1"
  printf '%s\t%s\n' "$1" "$2" >>"$PODMAN_IMAGE_STORE"
}

resource_store_remove() {
  local remaining
  remaining="$(grep -vxF "$1"$'\t'"$2" "$PODMAN_RESOURCE_STORE" 2>/dev/null)" || true
  if [[ -n "$remaining" ]]; then
    printf '%s\n' "$remaining" >"$PODMAN_RESOURCE_STORE"
  else
    : >"$PODMAN_RESOURCE_STORE"
  fi
}

image_store_remove() {
  local remaining
  remaining="$(grep -vF "$1"$'\t' "$PODMAN_IMAGE_STORE" 2>/dev/null)" || true
  if [[ -n "$remaining" ]]; then
    printf '%s\n' "$remaining" >"$PODMAN_IMAGE_STORE"
  else
    : >"$PODMAN_IMAGE_STORE"
  fi
}

subcommand="${1:-}"
shift || true

# Models the smoke image disappearing from storage part-way through a run that
# did not introduce it -- the shape an over-broad restore, or a podman prune
# landing alongside, would take.
if [[ -n "${MOCK_PODMAN_EVICT_ON:-}" && "$subcommand" == "${MOCK_PODMAN_EVICT_ON}" ]]; then
  image_store_remove "$MOCK_PODMAN_EVICT_IMAGE"
fi

# Models an interruption landing while this podman call is in flight: a Ctrl-C
# reaching the whole foreground process group (INT, which the child reports as
# 130), or a TERM sent to the verifier alone.
# It fires once: the cleanup path re-runs some of these same subcommands, and a
# hook that signalled again there would be testing re-entrancy rather than the
# interruption.
if [[ -n "${MOCK_PODMAN_SIGNAL_ON:-}" && "$subcommand" == "${MOCK_PODMAN_SIGNAL_ON}" ]] &&
  [[ ! -e "$PODMAN_IMAGE_STORE.signalled" ]]; then
  : >"$PODMAN_IMAGE_STORE.signalled"
  signal="${MOCK_PODMAN_SIGNAL:-INT}"
  kill -"$signal" "$PPID" 2>/dev/null || true
  if [[ "$signal" == INT ]]; then
    exit 130
  fi
  # A TERM has no effect on this child, so it stays alive long enough for the
  # verifier to be sitting in its foreground wait when the signal lands.
  sleep 3
  exit 1
fi

case "$subcommand" in
version)
  printf 'Client: Podman Engine\nVersion: 5.0.0\n'
  exit "${MOCK_PODMAN_VERSION_EXIT:-0}"
  ;;
info)
  for arg in "$@"; do
    case "$arg" in
    *Rootless*)
      printf '%s\n' "${MOCK_PODMAN_ROOTLESS:-true}"
      exit 0
      ;;
    *NetworkBackend*)
      printf '%s\n' "${MOCK_PODMAN_NETWORK_BACKEND:-netavark}"
      exit 0
      ;;
    esac
  done
  exit 0
  ;;
image)
  operation="${1:-}"
  shift || true
  case "$operation" in
  exists)
    image_store_id "${@: -1}" >/dev/null
    exit $?
    ;;
  inspect)
    image_store_id "${@: -1}" || exit 1
    exit 0
    ;;
  esac
  exit 0
  ;;
pull)
  pull_exit="${MOCK_PODMAN_PULL_EXIT:-0}"
  if [[ "$pull_exit" == 0 ]]; then
    image_store_set "${@: -1}" \
      "${MOCK_PODMAN_PULLED_IMAGE_ID:-${MOCK_PODMAN_IMAGE_ID:-0000pulled}}"
  fi
  exit "$pull_exit"
  ;;
build)
  build_exit="${MOCK_PODMAN_BUILD_EXIT:-0}"
  if [[ "$build_exit" == 0 ]]; then
    for arg in "$@"; do
      [[ "$arg" == dotfiles-podman-smoke-build-* ]] &&
        image_store_set "$arg" 0000built
    done
  fi
  exit "$build_exit"
  ;;
rmi)
  rmi_exit="${MOCK_PODMAN_RMI_EXIT:-0}"
  [[ "$rmi_exit" == 0 ]] || exit "$rmi_exit"
  image_store_remove "${@: -1}"
  exit 0
  ;;
volume | network)
  # Tracked so a case can read back whether an interrupted or failed run left
  # a volume or a network on the machine, rather than only whether the verifier
  # said it removed them.
  case "${1:-}" in
  create) printf '%s\t%s\n' "$subcommand" "${@: -1}" >>"$PODMAN_RESOURCE_STORE" ;;
  rm) resource_store_remove "$subcommand" "${@: -1}" ;;
  esac
  exit 0
  ;;
stop | system)
  exit 0
  ;;
compose)
  compose_exit="${MOCK_PODMAN_COMPOSE_EXIT:-0}"
  case "${*: -1}" in
  -d) [[ "$compose_exit" == 0 ]] &&
    printf 'compose\t%s\n' "$2" >>"$PODMAN_RESOURCE_STORE" ;;
  -v) resource_store_remove compose "$2" ;;
  esac
  exit "$compose_exit"
  ;;
run)
  for arg in "$@"; do
    if [[ "$arg" == cat ]]; then
      printf '%s\n' "${MOCK_PODMAN_CAT_OUTPUT-dotfiles-podman-smoke}"
      exit "${MOCK_PODMAN_RUN_EXIT:-0}"
    fi
    if [[ "$arg" == wget ]]; then
      printf '%s' "${MOCK_PODMAN_WGET_OUTPUT-dotfiles-podman-smoke}"
      exit "${MOCK_PODMAN_RUN_EXIT:-0}"
    fi
  done
  exit "${MOCK_PODMAN_RUN_EXIT:-0}"
  ;;
*)
  exit 0
  ;;
esac
EOF

  chmod +x "$mock_bin"/* "$test_root/handlers"/*
  printf 'ID=fedora\n' >"$test_root/os-release"
}

base_environment() {
  local root="$1"
  test_env_args "$root"
  printf '%s\n' \
    "PATH=$root/bin:$PATH" \
    "COMMAND_LOG=$root/commands.log" \
    "OS_RELEASE_FILE=$root/os-release" \
    "SUBUID_FILE=$root/subuid" \
    "SUBGID_FILE=$root/subgid" \
    "USER_ENABLED_UNITS=$root/user-enabled-units" \
    "USER_ACTIVE_UNITS=$root/user-active-units" \
    "SYSTEM_ENABLED_UNITS=$root/system-enabled-units" \
    "SYSTEM_ACTIVE_UNITS=$root/system-active-units" \
    "PODMAN_IMAGE_STORE=$root/podman-images" \
    "PODMAN_RESOURCE_STORE=$root/podman-resources" \
    "TMPDIR=$root/tmp" \
    "USER=tester"
}

# The installer records api_socket= in the containers profile state; the
# verifier checks the observed socket against it. Tests that exercise the
# verifier directly therefore have to record a selection, exactly as an
# install would.
write_containers_state() {
  local root="$1"
  local api_socket="$2"

  mkdir -p "$root/config/dotfiles"
  cat >"$root/config/dotfiles/containers.conf" <<EOF
schema_version=2
profile=containers
status=installed
runtime=podman
mode=rootless
compose_provider=podman-compose
api_socket=$api_socket
user=tester
EOF
}

fail_with_context() {
  local message="$1"
  local file="${2:-}"
  printf '%s\n' "$message" >&2
  if [[ -n "$file" ]]; then
    printf -- '--- %s ---\n' "$file" >&2
    cat "$file" >&2 2>/dev/null || printf '(missing or unreadable)\n' >&2
  fi
  exit 1
}

# --- dry-run makes no changes -----------------------------------------------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

dry_run_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/install-containers.sh" --dry-run)"

assert_contains "$dry_run_output" 'podman'
assert_contains "$dry_run_output" 'podman-compose'
assert_contains "$dry_run_output" 'Buildah / Skopeo:      not installed'
assert_contains "$dry_run_output" 'Docker Engine/alias:   not installed'
assert_contains "$dry_run_output" 'Rootless API socket:   false'
assert_contains "$dry_run_output" \
  'allocate a fresh, non-overlapping subuid/subgid range for tester'
assert_contains "$dry_run_output" 'No changes were made.'

api_socket_dry_run_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/install-containers.sh" --dry-run --api-socket)"
assert_contains "$api_socket_dry_run_output" 'Rootless API socket:   true'
assert_contains "$api_socket_dry_run_output" 'podman.socket'

assert_file_empty "$test_root/commands.log"
assert_file_empty "$test_root/subuid"
assert_file_empty "$test_root/subgid"
printf 'PASS: dry-run reports the plan without mutating anything\n'

# --- fresh install allocates a subuid/subgid range, then reruns cleanly ----

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

run_install() {
  env "${test_environment[@]}" \
    "$repo_root/platforms/fedora/scripts/install-containers.sh" \
    >"$test_root/install-output.log" 2>&1
}

if ! run_install; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'install-containers.sh failed on a fresh user'
fi

assert_file_contains "$test_root/commands.log" 'sudo dnf install -y podman podman-compose'
test_stub_assert_called "$test_root" dnf install -y podman podman-compose
assert_file_contains "$test_root/commands.log" 'usermod --add-subuids 100000-165535 tester'
assert_file_contains "$test_root/commands.log" 'usermod --add-subgids 100000-165535 tester'
assert_file_contains "$test_root/commands.log" 'podman system migrate'
assert_file_line "$test_root/subuid" 'tester:100000:65536'
assert_file_line "$test_root/subgid" 'tester:100000:65536'

state_file="$test_root/config/dotfiles/containers.conf"
assert_path_exists "$state_file"
assert_file_line "$state_file" 'profile=containers'
assert_file_line "$state_file" 'runtime=podman'
assert_file_line "$state_file" 'mode=rootless'
assert_file_line "$state_file" 'compose_provider=podman-compose'
assert_file_line "$state_file" 'api_socket=disabled'
assert_file_line "$state_file" 'user=tester'

first_state="$(sha256sum "$state_file")"
first_subuid="$(sha256sum "$test_root/subuid")"
: >"$test_root/commands.log"

if ! run_install; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'rerun of install-containers.sh failed'
fi

second_state="$(sha256sum "$state_file")"
second_subuid="$(sha256sum "$test_root/subuid")"

assert_eq "$first_state" "$second_state" 'containers.conf changed on a no-op rerun'
assert_eq "$first_subuid" "$second_subuid" '/etc/subuid changed on a no-op rerun'
assert_file_not_contains "$test_root/commands.log" 'usermod --add-subuids'
assert_file_not_contains "$test_root/commands.log" 'podman system migrate'

printf 'PASS: fresh install allocates subuid/subgid once and reruns cleanly\n'

# --- an existing subuid/subgid range is left untouched and not reallocated -

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

printf 'other-user:100000:65536\n' >"$test_root/subuid"
printf 'other-user:100000:65536\n' >"$test_root/subgid"

if ! env "${test_environment[@]}" "$repo_root/platforms/fedora/scripts/install-containers.sh" \
  >"$test_root/install-output.log" 2>&1; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'install-containers.sh failed with an existing range'
fi

assert_file_line "$test_root/subuid" 'other-user:100000:65536'
assert_file_line "$test_root/subuid" 'tester:165536:65536'
assert_file_line "$test_root/subgid" 'tester:165536:65536'
printf 'PASS: a new user is allocated a non-overlapping subuid/subgid range\n'

# --- a user who already owns both ranges is never touched ------------------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

printf 'tester:200000:65536\n' >"$test_root/subuid"
printf 'tester:200000:65536\n' >"$test_root/subgid"

if ! env "${test_environment[@]}" "$repo_root/platforms/fedora/scripts/install-containers.sh" \
  >"$test_root/install-output.log" 2>&1; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'install-containers.sh failed for an already-provisioned user'
fi

assert_file_not_contains "$test_root/commands.log" 'usermod'
assert_file_line "$test_root/subuid" 'tester:200000:65536'
printf 'PASS: an already-provisioned user is left untouched\n'

# --- --api-socket enables the rootless, socket-activated user unit ---------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

if ! env "${test_environment[@]}" "$repo_root/platforms/fedora/scripts/install-containers.sh" \
  --api-socket >"$test_root/install-output.log" 2>&1; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'install-containers.sh --api-socket failed'
fi

assert_file_contains "$test_root/commands.log" \
  'systemctl --user enable --now podman.socket'
if grep -Eq 'sudo systemctl.*podman.socket' "$test_root/commands.log"; then
  fail_with_context \
    'The Podman API socket must be enabled in the user (--user) scope only' \
    "$test_root/commands.log"
fi
assert_file_line "$test_root/user-enabled-units" 'podman.socket'
assert_file_line "$test_root/config/dotfiles/containers.conf" 'api_socket=enabled'

run_capture env "${test_environment[@]}" systemctl enable --now podman.socket
assert_status 96
assert_contains "$TEST_OUTPUT" 'strict stub rejected unsupported argv: systemctl'

verify_socket_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test 2>&1)"
assert_contains "$verify_socket_output" \
  'podman.socket is enabled and active for the user'
assert_contains "$verify_socket_output" 'as recorded'
printf 'PASS: --api-socket enables the rootless user-scoped API socket\n'

# --- recorded api_socket intent is what verification is measured against ---
#
# Before this contract the verifier passed whether the socket was enabled or
# disabled, so a run that asked for --api-socket and silently failed to
# establish it still verified clean. Each case below records an intent and
# then observes a socket state, so only the matching pair may pass.

# requested enabled + healthy user socket -> pass
new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
write_containers_state "$test_root" enabled
printf 'podman.socket\n' >"$test_root/user-enabled-units"
printf 'podman.socket\n' >"$test_root/user-active-units"

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_success
assert_contains "$TEST_OUTPUT" 'podman.socket is enabled and active for the user'
printf 'PASS: recorded api_socket=enabled with a healthy user socket passes\n'

# requested enabled + socket never established -> fail
new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
write_containers_state "$test_root" enabled

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_failure
assert_contains "$TEST_OUTPUT" 'api_socket=enabled was recorded'
assert_contains "$TEST_OUTPUT" 'systemctl --user enable --now podman.socket'
printf 'PASS: recorded api_socket=enabled without the socket fails\n'

# requested enabled + enabled but not active (broken/unusable) -> fail
new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
write_containers_state "$test_root" enabled
printf 'podman.socket\n' >"$test_root/user-enabled-units"

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_failure
assert_contains "$TEST_OUTPUT" 'enabled but not active for the user'
printf 'PASS: an enabled-but-inactive user socket fails verification\n'

# a system-scoped socket cannot substitute for the user-scoped one
new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
write_containers_state "$test_root" enabled
printf 'podman.socket\n' >"$test_root/system-enabled-units"
printf 'podman.socket\n' >"$test_root/system-active-units"

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_failure
assert_contains "$TEST_OUTPUT" \
  'a system-scoped podman.socket is present and does not satisfy this rootless profile'
printf 'PASS: a system-scoped socket does not satisfy the user-scoped requirement\n'

# requested disabled + disabled -> pass
new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
write_containers_state "$test_root" disabled

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_success
assert_contains "$TEST_OUTPUT" 'podman.socket is not enabled, as recorded'
printf 'PASS: recorded api_socket=disabled with no socket passes\n'

# requested disabled + independently enabled -> warning, not failure
new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
write_containers_state "$test_root" disabled
printf 'podman.socket\n' >"$test_root/user-enabled-units"
printf 'podman.socket\n' >"$test_root/user-active-units"

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_success
assert_contains "$TEST_OUTPUT" 'api_socket=disabled was recorded, but'
assert_contains "$TEST_OUTPUT" 'passed with warnings'
printf 'PASS: an independently enabled socket is drift, reported as a warning\n'

# corrupt/unknown recorded state -> fail with a repair instruction
new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
mkdir -p "$test_root/config/dotfiles"
cat >"$test_root/config/dotfiles/containers.conf" <<'EOF'
schema_version=2
profile=containers
status=installed
runtime=podman
mode=rootless
EOF

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_failure
assert_contains "$TEST_OUTPUT" 'missing or invalid api_socket'
assert_contains "$TEST_OUTPUT" 'install-containers.sh'
printf 'PASS: corrupt recorded containers state fails with a repair instruction\n'

# selected in the install state but with no profile state at all -> fail
new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
mkdir -p "$test_root/state/dotfiles"
cat >"$test_root/state/dotfiles/install.conf" <<'EOF'
schema_version=2
profile=install
status=installed
platform=fedora
requested_capabilities=base,containers
observed_capabilities=base,containers
external_assurance=not-recorded
repository=local-checkout
revision=unknown
provenance=capability-manifest@unknown
EOF

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_failure
assert_contains "$TEST_OUTPUT" 'the containers profile is selected in'
assert_contains "$TEST_OUTPUT" 'is missing'
printf 'PASS: a selected containers profile with no recorded state fails\n'

# --- verify-containers.sh --skip-smoke-test never touches containers -------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"

verify_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test 2>&1)" ||
  fail_with_context "verify-containers.sh --skip-smoke-test failed:\n$verify_output"

assert_contains "$verify_output" 'podman version'
assert_contains "$verify_output" 'podman info reports rootless execution'
assert_contains "$verify_output" 'rootless network backend: netavark'
assert_contains "$verify_output" 'smoke test skipped'
# With nothing recorded there is no intent to measure against: that is
# reported as unobserved rather than silently passing the socket check.
assert_contains "$verify_output" 'no containers profile selection is recorded'
assert_contains "$verify_output" 'completed with unobserved checks'

if grep -Eq 'podman (pull|build|volume create|network create)' \
  "$test_root/commands.log"; then
  fail_with_context \
    '--skip-smoke-test still ran mutating container operations' \
    "$test_root/commands.log"
fi
printf 'PASS: --skip-smoke-test performs inspection only\n'

# --- a non-rootless podman is reported as a verification failure -----------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"

if env "${test_environment[@]}" MOCK_PODMAN_ROOTLESS=false \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test \
  >"$test_root/verify-output.log" 2>&1; then
  fail_with_context \
    'verify-containers.sh must fail when podman is not running rootless' \
    "$test_root/verify-output.log"
fi
assert_file_contains "$test_root/verify-output.log" 'does not report rootless execution'
printf 'PASS: verification fails when Podman is not rootless\n'

# --- missing subuid/subgid ranges are reported as verification failures ----

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

if env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test \
  >"$test_root/verify-output.log" 2>&1; then
  fail_with_context \
    'verify-containers.sh must fail without a subuid/subgid range' \
    "$test_root/verify-output.log"
fi
assert_file_contains "$test_root/verify-output.log" 'has no subuid range'
assert_file_contains "$test_root/verify-output.log" 'has no subgid range'
printf 'PASS: verification fails without a subuid/subgid range\n'

# --- full smoke test: happy path exercises pull/run/build/mounts/port/net/compose

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
write_containers_state "$test_root" disabled

smoke_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" 2>&1)" ||
  fail_with_context "full smoke test failed:\n$smoke_output"

assert_contains "$smoke_output" "pull: $smoke_image_ref"
assert_contains "$smoke_output" 'run: minimal container executes and exits cleanly'
assert_contains "$smoke_output" 'build: Containerfile builds and the built image runs'
assert_contains "$smoke_output" 'bind mount: SELinux-labeled (:Z) host directory is readable'
assert_contains "$smoke_output" 'named volume: data persists across containers'
assert_contains "$smoke_output" 'localhost port publishing:'
assert_contains "$smoke_output" 'container networking:'
assert_contains "$smoke_output" 'compose: multi-service project reachable'
assert_contains "$smoke_output" 'Containers verification passed.'

assert_file_contains "$test_root/commands.log" '-v '
assert_file_contains "$test_root/commands.log" ':Z'
assert_file_contains "$test_root/commands.log" '-p 127.0.0.1:'
assert_file_contains "$test_root/commands.log" '--network'
assert_file_contains "$test_root/commands.log" 'podman compose'

run_capture env "${test_environment[@]}" curl --head http://127.0.0.1:1/
assert_status 96
assert_contains "$TEST_OUTPUT" 'strict curl fixture rejected unsupported argv'

printf 'PASS: full smoke test exercises every rootless workflow and cleans up\n'

# --- a smoke-test failure is reported and still exits non-zero -------------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"

if env "${test_environment[@]}" MOCK_PODMAN_BUILD_EXIT=1 \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" \
  >"$test_root/smoke-failure.log" 2>&1; then
  fail_with_context \
    'verify-containers.sh must fail when podman build fails' \
    "$test_root/smoke-failure.log"
fi
assert_file_contains "$test_root/smoke-failure.log" 'build failed'
printf 'PASS: a smoke-test failure is reported and fails verification\n'


# --- the smoke test restores local image state on every exit path ----------
#
# Issue #372: the smoke test pulled a base image and never put image storage
# back, while docs/profiles/containers.md claimed repeated verification leaves
# nothing behind. The restore owed depends on what was there first, so each
# case below sets up one of the two starting states and reads the store after.

smoke_test_root() {
  new_test_root
  mapfile -t test_environment < <(base_environment "$test_root")
  printf 'tester:100000:65536\n' >"$test_root/subuid"
  printf 'tester:100000:65536\n' >"$test_root/subgid"
  write_containers_state "$test_root" disabled
}

# absent before the run -> pulled, then removed again
smoke_test_root

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh"
assert_success
assert_contains "$TEST_OUTPUT" "pull: $smoke_image_ref"
assert_contains "$TEST_OUTPUT" \
  'smoke image was introduced by this run and has been removed again'
assert_file_contains "$test_root/commands.log" "rmi -f $smoke_image_ref"
if smoke_image_in_store "$test_root"; then
  fail_with_context \
    'the smoke test left its pulled base image in local image storage' \
    "$test_root/podman-images"
fi
assert_no_temporary_files "$test_root"
assert_no_smoke_resources "$test_root"
printf 'PASS: a smoke image this run introduced is removed again\n'

# present before the run -> kept, and reported unchanged
smoke_test_root
printf '%s\t%s\n' "$smoke_image_ref" already-here >"$test_root/podman-images"

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh"
assert_success
assert_contains "$TEST_OUTPUT" 'is already in local image storage and is not'
assert_contains "$TEST_OUTPUT" \
  'smoke image was already present and is kept, unchanged at already-here'
assert_file_not_contains "$test_root/commands.log" "rmi -f $smoke_image_ref"
# Not re-fetching is how the reference keeps naming the image it named before,
# so the absence of a pull is part of the contract, not an optimisation.
assert_file_not_contains "$test_root/commands.log" 'podman pull'
if ! smoke_image_in_store "$test_root"; then
  fail_with_context \
    'the smoke test removed a base image that was already on the machine' \
    "$test_root/podman-images"
fi
assert_file_line "$test_root/podman-images" "$smoke_image_ref"$'\t'already-here
printf 'PASS: a smoke image that was already present is kept unchanged\n'

# an image the run did not introduce, gone by the end of it, is a failure --
# so the "kept, unchanged" pass line is not one that is incapable of failing.
# A restore that dropped its "did this run introduce it?" guard looks exactly
# like this from outside.
smoke_test_root
printf '%s\t%s\n' "$smoke_image_ref" before-the-run >"$test_root/podman-images"

run_capture env "${test_environment[@]}" MOCK_PODMAN_EVICT_ON=build \
  "MOCK_PODMAN_EVICT_IMAGE=$smoke_image_ref" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh"
assert_failure
assert_contains "$TEST_OUTPUT" 'was before-the-run before this run and is gone'
assert_contains "$TEST_OUTPUT" 'leave an image it did not introduce alone'
printf 'PASS: losing a base image the run did not introduce fails verification\n'

# a removal that fails is reported with the command to finish it by hand,
# rather than passed over on a machine that still has the image
smoke_test_root

run_capture env "${test_environment[@]}" MOCK_PODMAN_RMI_EXIT=1 \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh"
assert_success
assert_contains "$TEST_OUTPUT" \
  "verification pulled $smoke_image_ref and could not remove it again"
assert_contains "$TEST_OUTPUT" 'passed with warnings'
printf 'PASS: an image that could not be removed again is reported\n'

# a failing smoke test still restores
smoke_test_root

run_capture env "${test_environment[@]}" MOCK_PODMAN_BUILD_EXIT=1 \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh"
assert_failure
assert_contains "$TEST_OUTPUT" 'build failed'
if smoke_image_in_store "$test_root"; then
  fail_with_context \
    'a failed smoke test left its pulled base image behind' \
    "$test_root/podman-images"
fi
assert_no_temporary_files "$test_root"
assert_no_smoke_resources "$test_root"
printf 'PASS: a failing smoke test still restores local image state\n'

# a terminated smoke test still restores
#
# A TERM part-way through is the shortest path to "the run stopped before it
# reached the end", which is the shape #372 was reported in. The cleanup, not
# the exit status, is the subject here: the run must leave no pulled image and
# no temporary directory behind however early it stopped.
smoke_test_root

run_capture env "${test_environment[@]}" MOCK_PODMAN_SIGNAL_ON=network \
  MOCK_PODMAN_SIGNAL=TERM \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh"
assert_status 143
if smoke_image_in_store "$test_root"; then
  fail_with_context \
    'a terminated smoke test left its pulled base image behind' \
    "$test_root/podman-images"
fi
assert_file_contains "$test_root/commands.log" "rmi -f $smoke_image_ref"
assert_no_temporary_files "$test_root"
assert_no_smoke_resources "$test_root"
printf 'PASS: a terminated smoke test still restores local image state\n'

# a Ctrl-C is not swallowed: the run stops, cleans up, and exits signalled
#
# Without the INT trap this case does not stop at all. A Ctrl-C reaches the
# whole foreground process group, the podman it interrupted exits on its own,
# and bash then discards the interrupt and runs the remaining smoke-test steps
# to completion -- an interrupted verification that keeps pulling and building,
# and reports an ordinary status when it finishes.
smoke_test_root

run_capture env "${test_environment[@]}" MOCK_PODMAN_SIGNAL_ON=network \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh"
assert_status 130
if smoke_image_in_store "$test_root"; then
  fail_with_context \
    'an interrupted smoke test left its pulled base image behind' \
    "$test_root/podman-images"
fi
assert_file_contains "$test_root/commands.log" "rmi -f $smoke_image_ref"
assert_no_temporary_files "$test_root"
assert_no_smoke_resources "$test_root"
printf 'PASS: an interrupted smoke test exits signalled and still restores\n'

# --skip-smoke-test does not read or write local image storage at all
smoke_test_root
printf '%s\t%s\n' "$smoke_image_ref" already-here >"$test_root/podman-images"

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_success
assert_file_line "$test_root/podman-images" "$smoke_image_ref"$'\t'already-here
assert_file_not_contains "$test_root/commands.log" 'podman image'
assert_file_not_contains "$test_root/commands.log" 'podman rmi'
assert_no_temporary_files "$test_root"
assert_no_smoke_resources "$test_root"
printf 'PASS: --skip-smoke-test leaves local image storage untouched\n'

printf '\nContainers profile install, verification, and idempotency tests passed.\n'
