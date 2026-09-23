#!/usr/bin/env bash

# A portable entry point, so it may be started under Apple's Bash 3.2: on macOS
# `env bash` resolves to /bin/bash whenever Homebrew is not ahead of it on PATH.
# Everything down to the modern-Bash guard therefore stays inside that dialect,
# and `set -uo pipefail` waits until after it, as bin/.local/bin/theme does.
# The runner itself, and the libraries it loads below, are written for the
# repository's documented Bash 4.4+ runtime.

script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/${BASH_SOURCE[0]##*/}"
repo_root="$(cd -- "$(dirname -- "$script_path")/.." && pwd)"

# shellcheck source=../common/lib/modern-bash.sh
. "$repo_root/common/lib/modern-bash.sh"
modern_bash_reexec ./scripts/test.sh "$script_path" "$@" || exit 2

set -uo pipefail
cd -- "$repo_root" || exit 1

usage() {
  cat <<'EOF_USAGE'
Usage: ./scripts/test.sh [--fail-fast] [test-script ...]

Normal mode runs every fast mocked/unit/contract suite, continues after
independent failures, and prints a final passed/failed/skipped summary.

Options:
  --fail-fast  Stop after the first failed suite; remaining suites are skipped.
  -h, --help   Show this help.

When test-script arguments are supplied, only those suites run. Targeted mode
relies on each selected suite to report its own missing dependencies, so it does
not require the full Linux aggregate toolchain. Set DOTFILES_TEST_REQUIRED_COMMANDS
explicitly when a targeted run needs runner-level dependency preflight.

A suite argument must resolve to a path inside this checkout's tests/ directory.
Anything else -- an absolute path, or a traversal out of tests/ -- is refused
before it is executed and counted as a failed suite.

Dependency policy:
  The default aggregate preflights the normal Linux validation toolchain.
  Commands in DOTFILES_TEST_REQUIRED_COMMANDS are always runner requirements.
  Missing runner requirements are an error before any suite runs; they are never
  silently treated as test success.

Environment:
  DOTFILES_TEST_SUITE_TIMEOUT  Seconds a single suite may run before it is
                               killed and counted as failed (default 900).
                               0 disables the per-suite timeout.
EOF_USAGE
}

fail_fast=false
selected_tests=()
while (($#)); do
  case "$1" in
  --fail-fast)
    fail_fast=true
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --)
    shift
    selected_tests+=("$@")
    break
    ;;
  -*)
    printf 'Unknown option: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
  *)
    selected_tests+=("$1")
    shift
    ;;
  esac
done

default_tests=(
  tests/test-verifier.sh
  tests/test-path-resolution.sh
  tests/test-test-support.sh
  tests/test-test-runner.sh
  tests/test-shell-reader.sh
  tests/test-registry-schema.sh
  tests/test-manifest-reader.sh
  tests/test-capabilities.sh
  tests/test-check-outcomes.sh
  tests/test-tool-floors.sh
  tests/test-install-option-parsers.sh
  tests/test-repository-hygiene.sh
  tests/test-lint-file-selection.sh
  tests/test-documentation.sh
  tests/test-acceptance-records.sh
  tests/test-compat-wrappers.sh
  tests/test-command-provider-closure.sh
  tests/test-supply-chain.sh
  tests/test-pin-freshness.sh
  tests/test-profile-state.sh
  tests/test-execution-plan.sh
  tests/test-cli-contract.sh
  tests/test-installer-preflight.sh
  tests/test-doctor.sh
  tests/test-install-lifecycle.sh
  tests/test-install-rerun.sh
  tests/test-secure-boot.sh
  tests/test-power-profiles.sh
  tests/test-installer-options.sh
  tests/test-installer-plan-commands.sh
  tests/test-platform-boundary.sh
  tests/test-local-state.sh
  tests/test-git-identity.sh
  tests/test-theme.sh
  tests/test-theme-hooks.sh
  tests/test-theme-precedence.sh
  tests/test-starship-themes.sh
  tests/test-kde-theme.sh
  tests/test-sway-config.sh
  tests/test-ghostty-config.sh
  tests/test-cheatsheet-bindings.sh
  tests/test-action-registry.sh
  tests/test-shell-startup.sh
  tests/test-neovim-tool-ownership.sh
  tests/test-csharpier-ownership.sh
  tests/test-json-workflow.sh
  tests/test-dev-workflow-contract.sh
  tests/test-dotnet-debugger-contract.sh
  tests/test-dap-smoke.py
  tests/test-neovim-bootstrap.sh
  tests/test-neovim-verify-readonly.sh
  tests/test-neovim-plugin-state.sh
  tests/test-markdown-workflow.sh
  tests/test-latex-profile.sh
  tests/test-ocaml-profile.sh
  tests/test-ocaml-verification.sh
  tests/test-idempotency.sh
  tests/test-asus-preflight.sh
  tests/test-asus-verification.sh
  tests/test-mocked-installs.sh
  tests/test-sftp-baseline.sh
  tests/test-ai-profile.sh
  tests/test-firstmate-backend.sh
  tests/test-ai-transitions.sh
  tests/test-mise-context.sh
  tests/test-optional-capability-dispatch.sh
  tests/test-vm-host.sh
  tests/test-vm-guest.sh
  tests/test-hardening.sh
  tests/test-desktop-tools.sh
  tests/test-dictation-fedora.sh
  tests/test-fedora-verification.sh
  tests/test-containers.sh
  tests/test-containers-wsl.sh
  tests/test-tailscale.sh
  tests/test-dictation-macos.sh
  tests/test-wsl-interop.sh
  tests/test-wsl-open.sh
  tests/test-fedora-wsl.sh
  tests/test-wsl-path-sanitizer.sh
  tests/test-parrot-ctf.sh
  tests/test-parrot-isolation.sh
  tests/test-parrot-terminal.sh
  tests/test-parrot-verification.sh
  tests/test-windows-bootstrap.sh
  tests/test-macos-bootstrap.sh
  tests/test-macos.sh
  tests/test-macos-verification.sh
  tests/test-macos-ai.sh
  tests/test-macos-login-shell.sh
  tests/test-macos-command-surface.sh
)

if ((${#selected_tests[@]} > 0)); then
  tests=("${selected_tests[@]}")
else
  tests=("${default_tests[@]}")
fi

required_commands=()
if [[ -n "${DOTFILES_TEST_REQUIRED_COMMANDS:-}" ]]; then
  read -r -a required_commands <<<"$DOTFILES_TEST_REQUIRED_COMMANDS"
elif ((${#selected_tests[@]} == 0)); then
  # Every host command the default suites reach for, not only the obvious
  # ones. A command missing from here does not go unnoticed: it surfaces as a
  # suite failure somewhere in the middle of the run, naming the tool but not
  # the policy, which is the opposite of the promise above. scp, sftp and ssh
  # belong to the idempotency, SFTP-baseline and verifier suites, getent and
  # unlink to the isolated-PATH ones, and curl and sha256sum to every suite
  # that mocks a download.
  required_commands=(
    awk bash curl find getent git grep jq mktemp nvim python3 rg scp sed
    sftp sha256sum ssh stow timeout unlink zsh
  )
fi

missing_commands=()
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
done

if ((${#missing_commands[@]} > 0)); then
  printf 'ERROR: missing required test dependencies: %s\n' "${missing_commands[*]}" >&2
  printf 'Policy: runner dependencies are required; no suites were run or credited as skipped.\n' >&2
  exit 2
fi

# Presence is not enough. A tool below its documented floor fails later, inside
# whichever suite first uses the feature it lacks, with a diagnostic that names
# neither the tool nor a version. The floors come from config/tool-floors.tsv,
# and which tools have one is the table's business, not a list repeated here.
# shellcheck source=../common/lib/tool-floors.sh
source "$repo_root/common/lib/tool-floors.sh"

unsatisfied_floor=()
if ((${#required_commands[@]} > 0)); then
  # A checked substitution, not < <(...): a manifest that cannot be read, or
  # whose header lost the tool column, must stop the runner rather than leave
  # every floor silently unenforced while the suites report success.
  floor_tools="$(manifest_values "$TOOL_FLOOR_MANIFEST" tool)" || {
    printf 'ERROR: could not read the version floors from %s\n' "$TOOL_FLOOR_MANIFEST" >&2
    printf 'Policy: runner dependencies must meet config/tool-floors.tsv; no suites were run or credited as skipped.\n' >&2
    exit 2
  }
  while IFS= read -r floor_tool; do
    [[ -n "$floor_tool" ]] || continue
    for command_name in "${required_commands[@]}"; do
      [[ "$command_name" == "$floor_tool" ]] || continue
      tool_floor_check "$floor_tool" || unsatisfied_floor+=("$floor_tool")
    done
  done <<<"$floor_tools"
fi

# The reason is tool_floor_check's to state -- below the floor, unparseable, or
# no probe at all -- so this names the tools without asserting which it was.
if ((${#unsatisfied_floor[@]} > 0)); then
  printf 'ERROR: test dependencies did not satisfy their documented floor: %s\n' "${unsatisfied_floor[*]}" >&2
  printf 'Policy: runner dependencies must meet config/tool-floors.tsv; no suites were run or credited as skipped.\n' >&2
  exit 2
fi

# A runner requirement that is not a command, and the reason the preflight
# above grew a second half. That machinery only understands names on PATH, so
# the lazy.nvim checkout tests/test-neovim-tool-ownership.sh hard-requires
# bypassed it entirely: on a machine satisfying every documented tool, one
# suite failed partway through a long run, naming lazy.nvim but not the policy
# -- exactly what the comment above says the command list exists to prevent.
# CI clones it and exports DOTFILES_LAZY_NVIM, so only a contributor running
# the documented command locally ever met it.
#
# Aggregate only, matching the policy the command list follows: a targeted run
# is each suite's own business, and the suite's hard failure stays the backstop.
# A verifier's checks are proven able to fail by what the suites drove them to,
# which only the aggregate run sees: a targeted run reaches a fraction of the
# call sites and would report every other one as uncovered. So the trace is
# armed here and read once the suites are done.
if ((${#selected_tests[@]} == 0)); then
  if [[ -n "${DOTFILES_VERIFY_TRACE:-}" ]]; then
    # A caller that chose the file wants to keep it: recording the starting
    # counts needs the trace after the run, and so does the suite that proves
    # this gate can fail.
    check_outcome_trace="$DOTFILES_VERIFY_TRACE"
    : >"$check_outcome_trace"
  else
    check_outcome_trace="$(mktemp -t dotfiles-verify-trace.XXXXXX)"
    export DOTFILES_VERIFY_TRACE="$check_outcome_trace"
    trap 'rm -f "$check_outcome_trace"' EXIT
  fi
fi

if ((${#selected_tests[@]} == 0)); then
  # shellcheck source=../tests/lib/lazy-nvim.sh
  source "$repo_root/tests/lib/lazy-nvim.sh"
  lazy_nvim_path="$(lazy_nvim_checkout)"
  if ! lazy_nvim_is_ready "$lazy_nvim_path"; then
    printf 'ERROR: no lazy.nvim checkout at %s\n' "$lazy_nvim_path" >&2
    printf 'Policy: runner dependencies are required; no suites were run or credited as skipped.\n' >&2
    printf 'Clone folke/lazy.nvim at the revision nvim-lazyvim/.config/nvim/lazy-lock.json pins, or point DOTFILES_LAZY_NVIM at a checkout.\n' >&2
    exit 2
  fi
fi

passed=()
failed=()
skipped=()

# The aggregate preflight requires `timeout`, and this is what it requires it
# for: a suite that hangs -- waiting on a prompt, a lock, or a socket that will
# never answer -- otherwise stalls the whole run until the job's own limit
# kills it, with no summary and no failing suite named. A killed suite is a
# failed suite, counted and reported like any other. Targeted mode does not
# preflight the toolchain, so it runs without a limit when `timeout` is absent
# rather than refusing to run at all.
suite_timeout="${DOTFILES_TEST_SUITE_TIMEOUT:-900}"

# The runner executes the path it is handed, and this repository ships an
# auto-approve rule for `./scripts/test.sh tests/...` in .claude/settings.json.
# An agent matcher reads that rule as a prefix, so `tests/../../../evil.sh`
# satisfied it and ran an arbitrary file on the machine with no prompt, counted
# as a passing suite. A suite is therefore a path inside this checkout's tests/
# directory, decided before anything is executed.
#
# Both sides are resolved with `pwd -P` so the comparison is physical on both:
# a checkout reached through a symlink resolves its suites the same way it
# resolves this root, rather than refusing every suite it was asked to run.
suite_root="$(cd -- "$repo_root/tests" 2>/dev/null && pwd -P)"
if [[ -z "$suite_root" ]]; then
  printf 'ERROR: no tests directory under %s\n' "$repo_root" >&2
  exit 2
fi

# The canonical path of $1, or the empty string when its directory does not
# exist -- in which case containment cannot be established and the caller must
# refuse rather than fall through to the missing-file path.
# Split in the shell rather than through dirname and basename: targeted mode
# deliberately runs without the aggregate toolchain, and a suite the runner
# could not classify because a coreutil was absent would land in the
# missing-suite path instead of being refused or run.
canonical_suite_path() {
  local candidate="$1" directory base
  base="${candidate##*/}"
  directory="${candidate%/*}"
  [[ -n "$directory" ]] || directory=/
  directory="$(cd -- "$directory" 2>/dev/null && pwd -P)" || return 0
  [[ -n "$directory" ]] || return 0
  printf '%s/%s\n' "${directory%/}" "$base"
}

run_suite() {
  local test_script="$1"
  local test_path="$test_script"
  [[ "$test_path" == /* ]] || test_path="$repo_root/$test_path"

  local canonical
  canonical="$(canonical_suite_path "$test_path")"
  if [[ -z "$canonical" || "$canonical" != "$suite_root"/* ]]; then
    printf 'Refusing to run a suite outside tests/: %s\n' "$test_script" >&2
    printf 'Policy: the runner executes suites under %s, and nothing else.\n' \
      "$suite_root" >&2
    return 2
  fi
  test_path="$canonical"

  if [[ ! -f "$test_path" ]]; then
    printf 'Missing test suite: %s\n' "$test_script" >&2
    return 127
  fi

  local -a limit=()
  if ((suite_timeout > 0)) && command -v timeout >/dev/null 2>&1; then
    # --kill-after gives a suite that traps TERM a moment to remove its
    # temporary directories before SIGKILL ends the argument.
    limit=(timeout --signal=TERM --kill-after=30 "$suite_timeout")
  fi

  if [[ -x "$test_path" ]]; then
    "${limit[@]}" "$test_path"
  else
    "${limit[@]}" bash "$test_path"
  fi
}

# Read off the array rather than stated anywhere, so the number cannot be
# quoted from memory: the count in circulation was 89 while the runner ran 82,
# which matters whenever it is used as a coverage claim.
suite_noun=suites
((${#tests[@]} == 1)) && suite_noun=suite
printf 'Running %d %s\n' "${#tests[@]}" "$suite_noun"

for ((index = 0; index < ${#tests[@]}; index++)); do
  test_script="${tests[index]}"
  printf '\n==> %s\n' "$test_script"

  if run_suite "$test_script"; then
    passed+=("$test_script")
  else
    status=$?
    if ((status == 124)); then
      failed+=("$test_script (timed out after ${suite_timeout}s)")
    else
      failed+=("$test_script (exit $status)")
    fi
    if [[ "$fail_fast" == true ]]; then
      for ((remaining = index + 1; remaining < ${#tests[@]}; remaining++)); do
        skipped+=("${tests[remaining]} (fail-fast)")
      done
      break
    fi
  fi
done

printf '\nTest summary — mocked/unit/contract evidence\n'
printf '  passed:  %d\n' "${#passed[@]}"
printf '  failed:  %d\n' "${#failed[@]}"
printf '  skipped: %d\n' "${#skipped[@]}"

if ((${#failed[@]} > 0)); then
  printf '\nFailed suites:\n' >&2
  printf '  - %s\n' "${failed[@]}" >&2
fi
if ((${#skipped[@]} > 0)); then
  printf '\nSkipped suites:\n'
  printf '  - %s\n' "${skipped[@]}"
fi

if ((${#failed[@]} > 0)); then
  exit 1
fi

if [[ -n "${check_outcome_trace:-}" ]]; then
  printf '\n==> check-outcome coverage\n'
  if ! python3 "$repo_root/scripts/validate-check-outcomes.py" "$check_outcome_trace"; then
    exit 1
  fi
fi

printf '\nAll required fast suites passed.\n'
