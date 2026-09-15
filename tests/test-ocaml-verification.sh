#!/usr/bin/env bash
set -euo pipefail

# Targeted contract tests for common/verify-ocaml.sh.
#
# The verifier must reach three different verdicts from the same code path:
# not applicable, healthy, and broken. Each case below fixes exactly one fact
# about the machine, so a passing suite says which property each check owns.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"
test_install_cleanup_trap

verifier="$repo_root/common/verify-ocaml.sh"
installer="$repo_root/common/install-ocaml.sh"

# ---------------------------------------------------------------------------
# One opam mock serving both the installer and the verifier, so an
# install-then-verify case exercises the same fake opam the install produced.
# ---------------------------------------------------------------------------

write_opam_mock() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<'MOCK'
#!/usr/bin/env bash
set -u

state="${MOCK_OPAM_STATE:?MOCK_OPAM_STATE is required}"
mkdir -p "$state"

case "${1:-}" in
var)
  [[ -f "$state/initialized" ]]
  exit $?
  ;;
init)
  : >"$state/initialized"
  exit 0
  ;;
update)
  exit 0
  ;;
switch)
  case "${2:-}" in
  list)
    [[ ! -f "$state/switches" ]] || cat "$state/switches"
    exit 0
    ;;
  show)
    [[ ! -f "$state/selected" ]] || cat "$state/selected"
    exit 0
    ;;
  create)
    printf '%s\n' "${3:-}" >>"$state/switches"
    printf '%s\n' "${3:-}" >"$state/selected"
    printf '%s\n' "${4:-}" >"$state/compiler"
    exit 0
    ;;
  set)
    printf '%s\n' "${2:+${3:-}}" >/dev/null
    printf '%s\n' "${3:-}" >"$state/selected"
    exit 0
    ;;
  *) exit 2 ;;
  esac
  ;;
install)
  exit 0
  ;;
exec)
  shift 3
  [[ "${1:-}" != -- ]] || shift
  if [[ "${1:-} ${2:-}" == 'ocamlc -version' ]]; then
    if [[ -n "${MOCK_OPAM_COMPILER:-}" ]]; then
      printf '%s\n' "$MOCK_OPAM_COMPILER"
    elif [[ -f "$state/compiler" ]]; then
      cat "$state/compiler"
    fi
    exit 0
  fi
  if [[ "${1:-} ${2:-}" == 'dune --version' ]]; then
    printf '3.20.0\n'
    exit 0
  fi
  if [[ "${1:-}" == sh && "${2:-}" == -c ]]; then
    tool="${5:-}"
    case ",${MOCK_OPAM_MISSING_TOOLS:-}," in
    *",$tool,"*) exit 1 ;;
    esac
    exit 0
  fi
  if [[ "${1:-}" == ocamlc && "${2:-}" == -o ]]; then
    [[ "${MOCK_OPAM_COMPILE:-ok}" == ok ]] || exit 1
    printf '#!/bin/sh\nprintf dotfiles-ocaml-ok\n' >"${3:-probe}"
    chmod +x "${3:-probe}"
    exit 0
  fi
  exit 2
  ;;
*) exit 2 ;;
esac
MOCK
  chmod +x "$path"
}

# ---------------------------------------------------------------------------
# Fixture machine
# ---------------------------------------------------------------------------

# new_machine [selected-capabilities] [install-status] [observed]
new_machine() {
  local capabilities="${1:-base,dotnet-debug,ocaml}"
  local status="${2:-installed}"
  local observed="${3:-$capabilities}"

  test_new_root
  MACHINE="$TEST_ROOT"
  BREW_PREFIX="$MACHINE/brew"
  OPAM_MOCK="$BREW_PREFIX/bin/opam"
  OPAM_STATE="$MACHINE/opam-state"
  write_opam_mock "$OPAM_MOCK"

  mkdir -p "$MACHINE/state/dotfiles" "$MACHINE/config/dotfiles"
  cat >"$MACHINE/state/dotfiles/install.conf" <<EOF
schema_version=2
profile=install
status=$status
platform=macos
requested_capabilities=$capabilities
observed_capabilities=$observed
external_assurance=not-recorded
repository=local-checkout
revision=0123456789abcdef
provenance=capability-manifest@0123456789abcdef
EOF

  mkdir -p "$MACHINE/home/.opam/opam-init"
  # shellcheck disable=SC2016 # Literal hook content; $HOME belongs to the hook.
  printf 'test -r "$HOME/.opam/opam-init/variables.sh" && true\n' \
    >"$MACHINE/home/.opam/opam-init/init.zsh"
}

record_ocaml_state() {
  local compiler="${1:-5.5.0}"
  local switch_name="${2:-dotfiles-ocaml-$compiler}"
  cat >"$MACHINE/config/dotfiles/ocaml.conf" <<EOF
schema_version=2
profile=ocaml
status=installed
switch=$switch_name
compiler=$compiler
EOF
  mkdir -p "$OPAM_STATE"
  printf '%s\n' "$switch_name" >"$OPAM_STATE/switches"
  printf '%s\n' "$switch_name" >"$OPAM_STATE/selected"
  printf '%s\n' "$compiler" >"$OPAM_STATE/compiler"
}

# run_verifier [extra VAR=VALUE ...]
run_verifier() {
  local -a environment=(
    env
    "HOME=$MACHINE/home"
    "XDG_CONFIG_HOME=$MACHINE/config"
    "XDG_DATA_HOME=$MACHINE/data"
    "XDG_STATE_HOME=$MACHINE/state"
    "XDG_CACHE_HOME=$MACHINE/cache"
    "HOMEBREW_PREFIX=$BREW_PREFIX"
    "MOCK_OPAM_STATE=$OPAM_STATE"
    "PATH=${VERIFIER_PATH:-$BREW_PREFIX/bin:$PATH}"
    "$@"
  )
  run_capture "${environment[@]}" "$verifier"
}

# ---------------------------------------------------------------------------

new_machine
record_ocaml_state
run_verifier
assert_success
assert_contains "$TEST_OUTPUT" "OCaml profile verification passed."
assert_contains "$TEST_OUTPUT" "opam is owned by the platform's native provider"
assert_contains "$TEST_OUTPUT" "A throwaway OCaml program compiles and runs"
assert_contains "$TEST_OUTPUT" "Generated opam shell hook parses as Zsh"
printf 'PASS: a healthy selected OCaml profile verifies\n'

new_machine base,dotnet-debug
VERIFIER_PATH="$MACHINE/empty-bin:/usr/bin:/bin" run_verifier
assert_success
assert_contains "$TEST_OUTPUT" "not selected and not installed (not applicable)"
assert_contains "$TEST_OUTPUT" "opam is absent, as expected"
printf 'PASS: an unselected profile does not fail because opam is absent\n'

new_machine base,dotnet-debug,ocaml
run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" "profile state is missing"
printf 'PASS: a selected profile with no recorded state fails\n'

new_machine
record_ocaml_state
VERIFIER_PATH="$MACHINE/empty-bin:/usr/bin:/bin" run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" "opam is not available"
printf 'PASS: an installed profile without opam fails\n'

new_machine
record_ocaml_state
: >"$OPAM_STATE/switches"
run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" "Configured opam switch not found"
printf 'PASS: a missing opam switch fails\n'

new_machine
record_ocaml_state
printf 'some-other-switch\n' >"$OPAM_STATE/selected"
run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" "Selected opam switch is some-other-switch"
printf 'PASS: a switch that is not the selected one fails\n'

new_machine
record_ocaml_state
run_verifier MOCK_OPAM_COMPILER=5.1.1
assert_failure
assert_contains "$TEST_OUTPUT" "OCaml compiler mismatch"
printf 'PASS: the wrong compiler in the switch fails\n'

new_machine
record_ocaml_state
run_verifier MOCK_OPAM_MISSING_TOOLS=ocamlearlybird
assert_failure
assert_contains "$TEST_OUTPUT" "opam-managed command missing"
assert_contains "$TEST_OUTPUT" "ocamlearlybird"
printf 'PASS: a missing opam-managed tool fails\n'

new_machine
record_ocaml_state
run_verifier MOCK_OPAM_COMPILE=fail
assert_failure
assert_contains "$TEST_OUTPUT" "did not compile and run"
printf 'PASS: a switch that cannot compile fails\n'

new_machine
record_ocaml_state
rm -f "$MACHINE/home/.opam/opam-init/init.zsh"
run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" "Generated opam shell hook is missing"
printf 'PASS: a missing generated shell hook fails\n'

new_machine
record_ocaml_state
printf 'if then fi done\n' >"$MACHINE/home/.opam/opam-init/init.zsh"
run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" "not valid Zsh"
printf 'PASS: an unparsable generated shell hook fails\n'

# Ownership: an opam outside the platform's declared provider prefix is not
# accepted merely because it answers on PATH.
new_machine
record_ocaml_state
mkdir -p "$MACHINE/elsewhere/bin"
write_opam_mock "$MACHINE/elsewhere/bin/opam"
VERIFIER_PATH="$MACHINE/elsewhere/bin:$PATH" run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" "outside the native package prefix"
printf 'PASS: an opam outside the declared provider prefix is rejected\n'

# An explicit compiler override must round-trip: switch name, recorded
# compiler and the compiler inside the switch all agree.
new_machine
record_ocaml_state 5.4.1
run_verifier
assert_success
assert_contains "$TEST_OUTPUT" "dotfiles-ocaml-5.4.1"
assert_contains "$TEST_OUTPUT" "OCaml compiler in dotfiles-ocaml-5.4.1 is 5.4.1"
printf 'PASS: an explicit compiler override round-trips through verification\n'

new_machine
record_ocaml_state 5.4.1 dotfiles-ocaml-5.5.0
run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" "does not match compiler"
printf 'PASS: a switch and compiler that disagree fail\n'

# The check must hold in the same installer process: install state is still
# "applying" with observed capabilities pending, and no login shell has been
# restarted.
new_machine base,dotnet-debug,ocaml applying pending
run_capture env \
  "HOME=$MACHINE/home" \
  "XDG_CONFIG_HOME=$MACHINE/config" \
  "XDG_DATA_HOME=$MACHINE/data" \
  "XDG_STATE_HOME=$MACHINE/state" \
  "XDG_CACHE_HOME=$MACHINE/cache" \
  "HOMEBREW_PREFIX=$BREW_PREFIX" \
  "MOCK_OPAM_STATE=$OPAM_STATE" \
  "PATH=$BREW_PREFIX/bin:$PATH" \
  "$installer"
assert_success
run_verifier
assert_success
assert_contains "$TEST_OUTPUT" "OCaml profile verification passed."
printf 'PASS: an install verifies in the same process, before a new login shell\n'

new_machine base,dotnet-debug,ocaml applying pending
run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" "profile state is missing"
printf 'PASS: a mid-install run still fails a selected profile that never installed\n'

# A compiler chosen once must survive a plain rerun, or the override would not
# round-trip at all: the installer would rebuild the default switch and rewrite
# the state, leaving verification nothing to catch.
new_machine base,dotnet-debug,ocaml
run_capture env \
  "HOME=$MACHINE/home" \
  "XDG_CONFIG_HOME=$MACHINE/config" \
  "XDG_DATA_HOME=$MACHINE/data" \
  "XDG_STATE_HOME=$MACHINE/state" \
  "XDG_CACHE_HOME=$MACHINE/cache" \
  "MOCK_OPAM_STATE=$OPAM_STATE" \
  "PATH=$BREW_PREFIX/bin:$PATH" \
  OCAML_COMPILER_VERSION=5.4.1 \
  "$installer"
assert_success
assert_file_line "$MACHINE/config/dotfiles/ocaml.conf" compiler=5.4.1
run_capture env \
  "HOME=$MACHINE/home" \
  "XDG_CONFIG_HOME=$MACHINE/config" \
  "XDG_DATA_HOME=$MACHINE/data" \
  "XDG_STATE_HOME=$MACHINE/state" \
  "XDG_CACHE_HOME=$MACHINE/cache" \
  "MOCK_OPAM_STATE=$OPAM_STATE" \
  "PATH=$BREW_PREFIX/bin:$PATH" \
  "$installer"
assert_success
assert_file_line "$MACHINE/config/dotfiles/ocaml.conf" compiler=5.4.1
assert_file_line "$MACHINE/config/dotfiles/ocaml.conf" switch=dotfiles-ocaml-5.4.1
run_verifier
assert_success
printf 'PASS: a compiler override survives a rerun that does not repeat it\n'

printf 'OCaml profile verification contract tests passed.\n'
