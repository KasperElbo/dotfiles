#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
lazyvim_config="$repo_root/nvim-lazyvim/.config/nvim"

fail() {
  printf 'Markdown workflow test failed: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local value="$2"

  grep -Fq -- "$value" "$file" || fail "$file does not contain: $value"
}

assert_contains "$lazyvim_config/lazyvim.json" \
  'lazyvim.plugins.extras.lang.markdown'

markdown_config="$lazyvim_config/lua/plugins/markdown.lua"
assert_contains "$markdown_config" '"SCJangra/table-nvim"'
assert_contains "$markdown_config" 'insert_table = "<leader>mt"'
assert_contains "$markdown_config" 'next = "<M-l>"'
if grep -Fq 'next = "<Tab>"' "$markdown_config"; then
  fail "table navigation must not replace LazyVim's Tab completion mapping"
fi
assert_contains "$markdown_config" 'render_markdown = true'
assert_contains "$markdown_config" '["markdown-toc"] = true'
assert_contains "$markdown_config" '["markdownlint-cli2"] = true'
assert_contains "$markdown_config" 'opts.linters_by_ft.markdown = nil'

autocmds="$lazyvim_config/lua/config/autocmds.lua"
assert_contains "$autocmds" 'pattern = "markdown.mdx"'
assert_contains "$autocmds" 'vim.opt_local.wrap = true'
assert_contains "$autocmds" 'vim.opt_local.spell = true'

grep -Fxq marksman "$lazyvim_config/mason-packages.txt" ||
  fail "Mason package inventory is missing: marksman"
for project_tool in markdown-toc markdownlint-cli2; do
  if grep -Fxq "$project_tool" "$lazyvim_config/mason-packages.txt"; then
    fail "project-local Markdown tool is Mason-managed: $project_tool"
  fi
done

for package_file in \
  "$repo_root/platforms/fedora/scripts/install-system.sh" \
  "$repo_root/platforms/parrot-ctf/scripts/install-system.sh"; do
  assert_contains "$package_file" '  xdg-utils'
done

wsl_config="$repo_root/platforms/fedora-wsl/stow/nvim-wsl/.config/nvim/lua/plugins/wsl.lua"
assert_contains "$wsl_config" 'vim.ui.open = function(target)'
assert_contains "$wsl_config" '{ "wsl-open", target }'
assert_contains "$wsl_config" 'vim.g.mkdp_browserfunc = "DotfilesMarkdownPreviewOpen"'
assert_contains "$wsl_config" "jobstart(['wsl-open', a:url]"

printf 'Markdown workflow configuration checks passed.\n'
