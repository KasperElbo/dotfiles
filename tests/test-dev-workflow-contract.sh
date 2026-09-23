#!/usr/bin/env bash
set -uo pipefail

# Orchestration contract for the installed-development workflow smoke tests.
#
# Everything here is offline and mocked: it proves that one canonical public
# name reaches the same script on every supported platform, that the deprecated
# spellings resolve to identical behavior, that each workflow decides
# independently between PASS/FAIL/SKIP, and that generated projects are removed
# even when a workflow fails part-way through. The workflows' real language
# ecosystems are exercised by ./scripts/test-dev-workflows.sh itself on an
# installed machine, not here.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

failures=0

report() {
  local outcome="$1"
  shift
  if [[ "$outcome" == pass ]]; then
    printf 'PASS: %s\n' "$*"
  else
    printf 'FAIL: %s\n' "$*" >&2
    failures=$((failures + 1))
  fi
}

check() {
  local description="$1"
  local failures_before="$TEST_FAILURES"
  shift
  # An assertion that failed inside a check fails it even if the check function
  # still returned 0, so a PASS line never hides a TEST FAILURE.
  if "$@" && ((TEST_FAILURES == failures_before)); then
    report pass "$description"
  else
    report fail "$description"
  fi
}

workflow_script="$repo_root/scripts/test-dev-workflows.sh"
manifest="$repo_root/config/capabilities.tsv"

test_install_cleanup_trap

# ---------------------------------------------------------------------------
# One canonical public name
# ---------------------------------------------------------------------------

canonical_flag_is_declared() {
  local platform flag
  for platform in fedora fedora-wsl macos; do
    flag="$(awk -F '\t' -v p="$platform" \
      '$1 == "dev-workflows" && $2 == p { print $4 }' "$manifest")"
    assert_eq "--dev-workflows" "$flag" "$platform capability flag" || return 1
  done

  flag="$(awk -F '\t' '$1 == "dev-workflows" && $2 == "parrot-ctf" { print $16 }' \
    "$manifest")"
  assert_eq "unsupported" "$flag" "parrot-ctf capability status"
}
check "the capability manifest declares one canonical flag" canonical_flag_is_declared

installers_expose_the_canonical_flag() {
  local installer
  for installer in \
    "$repo_root/platforms/fedora/install.sh" \
    "$repo_root/platforms/fedora-wsl/install.sh" \
    "$repo_root/platforms/macos/install.sh"; do
    assert_file_contains "$installer" '--dev-workflows)' || return 1
  done
  assert_file_contains "$repo_root/platforms/macos/lib/usage.sh" \
    '--dev-workflows/--no-dev-workflows' || return 1
  assert_file_contains "$repo_root/docs/workflows/development.md" \
    './install.sh --platform fedora --dev-workflows'
}
check "every supporting installer exposes the canonical flag" \
  installers_expose_the_canonical_flag

dry_runs_forward_to_one_script() {
  local output
  for output in \
    "$("$repo_root/install.sh" --dry-run --no-kde --no-latex --dev-workflows 2>/dev/null)" \
    "$("$repo_root/install.sh" --platform macos --dry-run --dev-workflows 2>/dev/null)"; do
    assert_contains "$output" 'scripts/test-dev-workflows.sh --all' || return 1
    assert_contains "$output" '[dev-workflows]' || return 1
  done
}
check "installer dry runs forward to the one workflow script" \
  dry_runs_forward_to_one_script

# ---------------------------------------------------------------------------
# Deprecated aliases warn and resolve identically
# ---------------------------------------------------------------------------

# An alias must not become a second, slowly diverging option: its resolved plan
# has to match the canonical flag's plan exactly, and it has to say it is
# deprecated so the spelling can eventually be retired.
alias_matches_canonical() {
  local deprecated="$1"
  shift
  local canonical_plan deprecated_plan warning

  canonical_plan="$("$@" --dry-run --dev-workflows 2>/dev/null)"
  deprecated_plan="$("$@" --dry-run "$deprecated" 2>/dev/null)"
  warning="$("$@" --dry-run "$deprecated" 2>&1 >/dev/null)"

  assert_eq "$canonical_plan" "$deprecated_plan" "$deprecated resolved plan" || return 1
  assert_contains "$warning" "$deprecated is deprecated"
}
check "macOS --workflows warns and resolves to --dev-workflows" \
  alias_matches_canonical --workflows "$repo_root/install.sh" --platform macos
check "Fedora WSL --smoke-test warns and resolves to --dev-workflows" \
  alias_matches_canonical --smoke-test "$repo_root/platforms/fedora-wsl/install.sh"

wsl_verifier_accepts_both_spellings() {
  local verifier="$repo_root/platforms/fedora-wsl/scripts/verify.sh"
  assert_file_contains "$verifier" '--dev-workflows)' || return 1
  assert_file_contains "$verifier" '--smoke-test is deprecated'
}
check "the Fedora WSL verifier accepts both spellings" \
  wsl_verifier_accepts_both_spellings

# The unrelated VM-host --smoke-test renders a guest definition; it is a
# different option on a different script and must keep its own meaning.
vm_host_flag_is_untouched() {
  assert_file_contains "$repo_root/platforms/fedora/scripts/install-vm-host.sh" \
    '--smoke-test       Render a representative guest definition without creating it'
}
check "the VM-host --smoke-test keeps its unrelated meaning" \
  vm_host_flag_is_untouched

# ---------------------------------------------------------------------------
# Reduced profiles reject the capability rather than faking parity
# ---------------------------------------------------------------------------

parrot_rejects_the_capability() {
  local spelling
  for spelling in --dev-workflows --smoke-test --workflows; do
    run_capture "$repo_root/platforms/parrot-ctf/install.sh" "$spelling"
    assert_failure || return 1
    assert_contains "$TEST_OUTPUT" 'not supported on parrot-ctf' || return 1
  done

  # Rejecting the flag is only honest if the profile really has no workstation
  # runtime to exercise, so it must not have quietly acquired one.
  assert_file_not_contains "$repo_root/platforms/parrot-ctf/install.sh" \
    'test-dev-workflows.sh'
}
check "the reduced Parrot profile rejects the capability explicitly" \
  parrot_rejects_the_capability

# ---------------------------------------------------------------------------
# Independent per-workflow results
# ---------------------------------------------------------------------------

# Isolated XDG roots, so the selected workflows' prerequisites are provably
# absent whatever this host happens to have installed. Workflows that would run
# a real toolchain are deliberately not selected: the repository suite stays
# offline.
run_workflows_without_tools() {
  local root="$1"
  shift
  env -i \
    "PATH=/usr/local/bin:/usr/bin:/bin" \
    "HOME=$root/home" \
    "XDG_CONFIG_HOME=$root/config" \
    "XDG_DATA_HOME=$root/data" \
    "TMPDIR=$root/tmp" \
    bash "$workflow_script" "$@"
}

missing_tools_skip_rather_than_fail() {
  test_new_root
  mkdir -p "$TEST_ROOT/tmp"

  run_capture run_workflows_without_tools "$TEST_ROOT" --json --ocaml
  assert_success || return 1
  assert_contains "$TEST_OUTPUT" 'SKIP json: LazyVim is not installed' || return 1
  assert_contains "$TEST_OUTPUT" 'SKIP ocaml: ' || return 1
  assert_contains "$TEST_OUTPUT" 'skipped: 2' || return 1
  assert_contains "$TEST_OUTPUT" 'failed:  0'
}
check "an absent runtime is reported as SKIP with a reason, not a failure" \
  missing_tools_skip_rather_than_fail

# The Python workflow is the simplest real orchestration path: one command
# drives it end to end, so a stubbed `uv` exercises selection, execution,
# result reporting and cleanup without a language ecosystem.
install_uv_stub() {
  local root="$1"
  local behavior="$2"
  mkdir -p "$root/bin"
  cat >"$root/bin/uv" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$root/uv.log"
if [[ "$behavior" == fail && "\$1" == sync ]]; then
  printf 'deliberate uv failure\n' >&2
  exit 3
fi
case "\$1" in
run)
  # 'uv run python -m dotfiles_smoke' is the only command whose output is read.
  [[ "\$2" != python ]] || printf '42\n'
  ;;
build)
  mkdir -p dist && : >dist/dotfiles_python_smoke-1.0.0-py3-none-any.whl
  ;;
esac
exit 0
EOF
  chmod +x "$root/bin/uv"
}

run_python_workflow() {
  local root="$1"
  env -i \
    "PATH=$root/bin:/usr/bin:/bin" \
    "HOME=$root/home" \
    "XDG_CONFIG_HOME=$root/config" \
    "XDG_DATA_HOME=$root/data" \
    "TMPDIR=$root/tmp" \
    bash "$workflow_script" --python
}

a_satisfied_workflow_passes() {
  test_new_root
  mkdir -p "$TEST_ROOT/tmp"
  install_uv_stub "$TEST_ROOT" succeed

  run_capture run_python_workflow "$TEST_ROOT"
  assert_success || return 1
  assert_contains "$TEST_OUTPUT" 'passed:  1' || return 1
  assert_contains "$TEST_OUTPUT" 'failed:  0' || return 1

  # The workflow must actually drive the toolchain, not merely report success.
  assert_file_contains "$TEST_ROOT/uv.log" 'sync --all-groups' || return 1
  assert_file_contains "$TEST_ROOT/uv.log" 'run pytest' || return 1
  assert_file_contains "$TEST_ROOT/uv.log" 'build'
}
check "a workflow whose prerequisites are met runs and passes" \
  a_satisfied_workflow_passes

an_injected_failure_fails_and_cleans_up() {
  test_new_root
  mkdir -p "$TEST_ROOT/tmp"
  install_uv_stub "$TEST_ROOT" fail

  run_capture run_python_workflow "$TEST_ROOT"
  assert_failure || return 1
  assert_contains "$TEST_OUTPUT" 'failed:  1' || return 1
  assert_contains "$TEST_OUTPUT" 'Failed workflows:' || return 1

  # Nothing generated may survive an injected failure.
  local leftovers
  leftovers="$(find "$TEST_ROOT/tmp" -mindepth 1 -maxdepth 1 -print)"
  assert_eq "" "$leftovers" "temporary projects left behind after a failure"
}
check "an injected failure fails the run and still removes generated projects" \
  an_injected_failure_fails_and_cleans_up

selectors_combine_without_duplication() {
  test_new_root
  mkdir -p "$TEST_ROOT/tmp"
  install_uv_stub "$TEST_ROOT" succeed

  run_capture env -i \
    "PATH=$TEST_ROOT/bin:/usr/bin:/bin" \
    "HOME=$TEST_ROOT/home" \
    "XDG_CONFIG_HOME=$TEST_ROOT/config" \
    "XDG_DATA_HOME=$TEST_ROOT/data" \
    "TMPDIR=$TEST_ROOT/tmp" \
    bash "$workflow_script" --python --python --json
  assert_success || return 1
  assert_contains "$TEST_OUTPUT" 'passed:  1' || return 1
  assert_contains "$TEST_OUTPUT" 'skipped: 1'
}
check "repeated selectors run each workflow exactly once" \
  selectors_combine_without_duplication

unknown_selectors_are_rejected() {
  run_capture bash "$workflow_script" --not-a-workflow
  assert_status 2 || return 1
  assert_contains "$TEST_OUTPUT" 'Unknown option'
}
check "an unknown workflow selector is rejected" unknown_selectors_are_rejected

# ---------------------------------------------------------------------------

if ((failures > 0)); then
  printf '\nDevelopment workflow contract checks failed: %d\n' "$failures" >&2
  exit 1
fi

printf 'Development workflow orchestration contract checks passed.\n'
