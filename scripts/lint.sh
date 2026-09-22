#!/usr/bin/env bash

# A portable entry point, so it may be started under Apple's Bash 3.2: on macOS
# `env bash` resolves to /bin/bash whenever Homebrew is not ahead of it on PATH.
# Everything down to the modern-Bash guard therefore stays inside that dialect,
# and `set -euo pipefail` waits until after it, as bin/.local/bin/theme does.
# The `mapfile` below and common/lib/tool-floors.sh further down both need the
# repository's documented Bash 4.4+ runtime.

script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/${BASH_SOURCE[0]##*/}"
repo_root="$(cd -- "$(dirname -- "$script_path")/.." && pwd)"

# shellcheck source=../common/lib/modern-bash.sh
. "$repo_root/common/lib/modern-bash.sh"
modern_bash_reexec ./scripts/lint.sh "$script_path" "$@" || exit 2

set -euo pipefail
cd "$repo_root"

# Python decides the shell lint file set (below) as well as running every
# validator further down, so the interpreter is checked against its floor in
# config/tool-floors.tsv here: an old or absent interpreter is named once,
# rather than failing inside whichever consumer first uses newer syntax.
if ! command -v python3 >/dev/null 2>&1; then
  printf 'python3 is required but was not found in PATH.\n' >&2
  exit 1
fi

# shellcheck source=../common/lib/tool-floors.sh
source "$repo_root/common/lib/tool-floors.sh"
tool_floor_check python3 || exit 1

# The file set comes from scripts/list-shell-files.py rather than from a glob
# here, because `*.sh` decides scope by extension and a command installed onto
# PATH does not carry one. Fourteen tracked programs -- bin/.local/bin/theme,
# doctor, the stowed Sway and WSL interop commands, and the Wayland session
# command the display manager runs -- sat outside both checks below until that
# changed. The reader enforces its own floor: every file the old glob matched
# must still be in the set it returns.
#
# The list goes through a file rather than a process substitution so that a
# failing reader fails the run: `mapfile < <(cmd)` reports mapfile's status,
# not the command's, and would leave a short list looking like a clean one.
shell_file_list="$(mktemp)"
trap 'rm -f "$shell_file_list"' EXIT
./scripts/list-shell-files.py --print0 >"$shell_file_list"
mapfile -d '' shell_files <"$shell_file_list"

if ((${#shell_files[@]} == 0)); then
  printf 'No tracked shell files found.\n' >&2
  exit 1
fi

printf 'Checking Bash syntax in %d tracked files...\n' "${#shell_files[@]}"

for file in "${shell_files[@]}"; do
  bash -n "$file"
done

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'ShellCheck is required but was not found in PATH.\n' >&2
  exit 1
fi

printf 'Running ShellCheck...\n'
# -S warning: fail only on warning-and-above findings, so info-level notes
# that ShellCheck adds or removes between versions do not fail CI on version
# drift alone (see docs/testing.md's "Contributor toolchain" section).
shellcheck -x -P SCRIPTDIR -s bash -S warning "${shell_files[@]}"

printf 'Checking generated Starship configurations...\n'
./scripts/update-starship-themes.sh --check

printf 'Checking repository hygiene...\n'
python3 ./scripts/validate-repository-hygiene.py
python3 ./scripts/validate-shell-file-roles.py
python3 ./scripts/validate-neovim-plugin-specs.py
python3 ./scripts/validate-library-guards.py
python3 ./scripts/validate-symlink-checks.py

printf 'Checking generated and cross-referenced documentation...\n'
python3 ./scripts/render-capability-matrix.py --check
python3 ./scripts/render-installer-options.py --check
python3 ./scripts/render-verifier-reference.py --check
python3 ./scripts/render-action-reference.py --check
python3 ./scripts/render-package-ownership.py --check
python3 ./scripts/render-install-flows.py --check
python3 ./scripts/render-file-ownership.py --check
python3 ./scripts/validate-actions.py
python3 ./scripts/validate-docs.py

printf 'Validating network-source provenance...\n'
python3 ./scripts/validate-capabilities.py
python3 ./scripts/validate-install-options.py
python3 ./scripts/validate-command-provider-closure.py
python3 ./scripts/validate-tool-floors.py
python3 ./scripts/validate-network-sources.py
python3 ./scripts/validate-pin-freshness.py
python3 ./scripts/validate-plan-network.py
python3 ./scripts/render-supply-chain.py --check

printf 'Shell validation passed.\n'
