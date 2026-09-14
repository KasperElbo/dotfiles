#!/usr/bin/env bash
set -euo pipefail

# JSON/JSONC is a declared Neovim capability, which means three things have to
# agree: the profile that enables the language support, the tracked Mason
# inventory the installer provisions directly, and the verifier that checks the
# installed result. This suite asserts that agreement without needing a
# provisioned editor.
#
# The behavioural counterpart runs against a real installation:
#   ./scripts/test-dev-workflows.sh --json

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
lazyvim_config="$repo_root/nvim-lazyvim/.config/nvim"
lua_output="$(mktemp)"
trap 'rm -f -- "$lua_output"' EXIT

fail() {
  printf 'JSON workflow test failed: %s\n' "$*" >&2
  exit 1
}

command -v nvim >/dev/null 2>&1 || fail "nvim is required for the JSON contract test"

if ! nvim --headless -u NONE -i NONE -l tests/test-json-workflow.lua \
  >"$lua_output" 2>&1; then
  sed 's/^/  /' "$lua_output" >&2
  fail "the declared JSON workflow contract is not satisfied"
fi
printf 'PASS: profile, Mason inventory and Conform mappings agree on JSON\n'

# The installer provisions the tracked inventory directly and the verifiers
# check that same file, so a formatter or server named anywhere else would be
# invisible to one of them.
inventory="$lazyvim_config/mason-packages.txt"
for package in json-lsp prettier; do
  grep -Fxq "$package" "$inventory" ||
    fail "$package is not in the tracked Mason inventory"
done

for verifier in \
  "$repo_root/platforms/fedora/scripts/verify.sh" \
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh"; do
  grep -Fq 'nvim-lazyvim/.config/nvim/mason-packages.txt' "$verifier" ||
    fail "verifier does not check the tracked Mason inventory: $verifier"
done
grep -Fq 'nvim-lazyvim/.config/nvim/mason-packages.txt' \
  "$repo_root/common/install-neovim-tools.sh" ||
  fail "bootstrap does not install the tracked Mason inventory"
printf 'PASS: bootstrap and verifiers own the same JSON formatter and server\n'

# Prettier is the editor-owned fallback, not a globally installed npm package
# and not a second declaration of a project's own formatter.
if grep -Fiq prettier "$repo_root/mise/.config/mise/config.toml"; then
  fail "Prettier must not also be declared through mise"
fi
if grep -Fiq prettier "$lazyvim_config/profiles/parrot-ctf/mason-packages.txt"; then
  fail "Prettier must not be installed into the reduced Parrot profile"
fi
printf 'PASS: Prettier has exactly one declared editor-side owner\n'

# Format-on-save policy stays repository-wide; a JSON-only save hook would be a
# second policy that could not be turned off with the normal LazyVim toggle.
options="$lazyvim_config/lua/config/options.lua"
grep -Fq 'vim.g.lazyvim_prettier_needs_config = false' "$options" ||
  fail "the standalone-file formatting policy is not stated explicitly"
if grep -rn 'BufWritePre' "$lazyvim_config/lua" | grep -Eq 'json'; then
  fail "a JSON-specific format-on-save hook diverges from the repository policy"
fi
printf 'PASS: JSON follows the repository-wide format-on-save policy\n'

# The disposable fixture the behavioural test consumes must stay complete.
fixture="$repo_root/tests/fixtures/json-workflow"
for required in \
  standalone/badly-formatted.json \
  standalone/badly-formatted.jsonc \
  standalone/malformed.json \
  configured/.prettierrc \
  configured/badly-formatted.json; do
  [[ -f "$fixture/$required" ]] || fail "JSON fixture is missing $required"
done
grep -Fq '//' "$fixture/standalone/badly-formatted.jsonc" ||
  fail "the JSONC fixture has no comment for formatting to preserve"
printf 'PASS: the disposable JSON fixture covers editing, validation and formatting\n'

printf 'JSON editing, validation and formatting contract checks passed.\n'
