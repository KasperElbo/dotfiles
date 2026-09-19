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
scratch="$(mktemp -d)"
trap 'rm -f -- "$lua_output"; rm -rf -- "$scratch"' EXIT

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
# Three constructs would put a second save-time policy beside LazyVim's, each
# outside the `vim.g.autoformat` toggle that turns the first one off: an
# autocommand on a write event, Conform's own `format_on_save` /
# `format_after_save`, and an `autoformat` override for some buffers only. The
# configuration is read as Lua, so a comment or a string naming one of them is
# not one -- the distinction #273 was caught by.
reader="$repo_root/tests/support/check-nvim-save-policy.py"
save_policy="$(python3 "$reader" "$lazyvim_config/lua")" ||
  fail "the Neovim configuration could not be read as Lua"

# What the reader found, before anything is concluded from what it did not.
# The assertion below is about a set the reader has demonstrably seen: this
# configuration registers autocommands, and the reader reports them.
scanned="$(awk -F'\t' '$1 == "scanned" { print $2 }' <<<"$save_policy")"
[[ "$scanned" =~ ^[0-9]+$ ]] && ((scanned > 0)) ||
  fail "the save-policy reader scanned no Lua files"
autocmds="$(awk -F'\t' '$1 == "autocmd" { print $2 ":" $3 " " $4 }' <<<"$save_policy")"
[[ -n "$autocmds" ]] ||
  fail "the save-policy reader found no autocommands at all, so it cannot show that none of them is a save hook"

# `dynamic` is an event list the reader could not resolve from the source. It
# fails here rather than passing, because nothing has shown it is not a write.
write_hooks="$(awk -F'\t' '
  $1 == "autocmd" && ($4 ~ /BufWrite/ || $4 == "dynamic") { print $2 ":" $3 " " $4 }
' <<<"$save_policy")"
[[ -z "$write_hooks" ]] ||
  fail "a save-time autocommand runs outside LazyVim's autoformat toggle: $write_hooks"
conform_hooks="$(awk -F'\t' '$1 == "conform-save" { print $2 ":" $3 " " $4 }' <<<"$save_policy")"
[[ -z "$conform_hooks" ]] ||
  fail "Conform installs its own save hook, which the autoformat toggle does not reach: $conform_hooks"
overrides="$(awk -F'\t' '$1 == "autoformat" { print $2 ":" $3 }' <<<"$save_policy")"
[[ -z "$overrides" ]] ||
  fail "an autoformat override makes the format-on-save policy per-buffer: $overrides"

# The negative control. Two of the three assertions above are about constructs
# this configuration has none of, so without a planted copy they would be
# reporting the absence of something nothing had shown the reader could find.
control="$scratch/lua"
mkdir -p "$control"
cat >"$control/planted.lua" <<'LUA'
-- A comment naming BufWritePre, format_on_save and autoformat is not code,
-- and neither is this string: "format_after_save".
vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = { "*.json", "*.jsonc" },
  callback = function()
    vim.b.autoformat = true
    require("conform").format()
  end,
})
return {
  { "stevearc/conform.nvim", opts = { format_on_save = { timeout_ms = 500 } } },
}
LUA
control_report="$(python3 "$reader" "$control")" ||
  fail "the save-policy reader could not read its own negative control"
for kind in autocmd conform-save autoformat; do
  found="$(awk -F'\t' -v kind="$kind" '$1 == kind' <<<"$control_report")"
  [[ -n "$found" ]] ||
    fail "the save-policy reader reports no $kind record, so its absence above proves nothing"
done
control_events="$(awk -F'\t' '$1 == "autocmd" { print $4 }' <<<"$control_report")"
[[ "$control_events" == *BufWrite* ]] ||
  fail "the save-policy reader did not report the planted write event"

# A file it cannot lex is an error, not a file that quietly contributes no
# findings -- the fail-open shape this repository keeps having to remove.
printf 'local unterminated = "\n' >"$control/broken.lua"
if python3 "$reader" "$control" >/dev/null 2>&1; then
  fail "the save-policy reader accepted a file it could not read as Lua"
fi
rm -f -- "$control/broken.lua"
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
