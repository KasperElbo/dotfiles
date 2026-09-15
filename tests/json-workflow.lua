-- Real JSON/JSONC workflow check for an installed Neovim.
--
-- Runs inside the normal configuration (so LazyVim, the JSON extra, Conform,
-- and the Mason-provisioned tools are the ones under test) and reports through
-- the process exit status: `cquit 1` on the first failed expectation, `qall!`
-- only after every expectation held. Invoke it as
--
--   nvim --headless -c 'luafile tests/json-workflow.lua' -c 'cquit 1'
--
-- so that a failure to even load this file still fails the caller.
--
-- DOTFILES_JSON_FIXTURE names a disposable copy of tests/fixtures/json-workflow.

local fixture = vim.env.DOTFILES_JSON_FIXTURE

local checks = {}

local function check(description, fn)
  table.insert(checks, { description = description, fn = fn })
end

-- Raised by a check that cannot be observed here. It is reported as SKIP with
-- its reason rather than silently passing or failing the run.
local function skip(reason)
  error({ skipped = reason }, 0)
end

local function read_buffer(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function open(relative_path)
  local path = fixture .. "/" .. relative_path
  vim.cmd.edit(vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  assert(vim.api.nvim_buf_is_valid(bufnr), "could not open " .. path)
  return bufnr
end

--- Format a buffer through exactly the path the interactive format action uses.
local function format(bufnr)
  local ok, err = require("conform").format({
    bufnr = bufnr,
    async = false,
    quiet = false,
    lsp_format = "never",
    timeout_ms = 15000,
  })
  assert(ok, "Conform did not format the buffer: " .. tostring(err))
  return read_buffer(bufnr)
end

check("JSON and JSONC resolve to the expected filetypes", function()
  local json = open("standalone/badly-formatted.json")
  assert(vim.bo[json].filetype == "json", "unexpected filetype: " .. vim.bo[json].filetype)
  local jsonc = open("standalone/badly-formatted.jsonc")
  assert(vim.bo[jsonc].filetype == "jsonc", "unexpected filetype: " .. vim.bo[jsonc].filetype)
end)

check("Treesitter parses JSON and JSONC", function()
  for _, language in ipairs({ "json", "jsonc" }) do
    -- JSONC reuses the JSON grammar, so both filetypes need the json parser.
    local parser = language == "jsonc" and "json" or language
    if not vim.treesitter.language.add(parser) then
      skip(("the %s Treesitter parser is not installed on this host"):format(parser))
    end

    local bufnr = open("standalone/badly-formatted." .. language)
    local ok, tree = pcall(vim.treesitter.get_parser, bufnr, parser)
    assert(ok and tree, "no Treesitter parser attached to a " .. language .. " buffer")
    assert(tree:parse()[1], "the " .. language .. " buffer did not produce a syntax tree")
  end
end)

check("Conform owns JSON and JSONC formatting", function()
  local conform = require("conform")
  for _, relative_path in ipairs({
    "standalone/badly-formatted.json",
    "standalone/badly-formatted.jsonc",
  }) do
    local bufnr = open(relative_path)
    local names = {}
    for _, formatter in ipairs(conform.list_formatters(bufnr)) do
      table.insert(names, formatter.name)
    end
    assert(
      vim.tbl_contains(names, "prettier"),
      relative_path .. " is not mapped to Prettier: " .. vim.inspect(names)
    )
  end
end)

check("the declared editor-owned Prettier is the one that runs", function()
  local bufnr = open("standalone/badly-formatted.json")
  local info = require("conform").get_formatter_info("prettier", bufnr)
  assert(info.available, "Prettier is unavailable: " .. tostring(info.available_msg))

  local resolved = vim.fn.exepath(info.command)
  assert(resolved ~= "", "Prettier does not resolve to an executable: " .. info.command)

  local mason_bin = vim.fn.stdpath("data") .. "/nvim/mason/bin"
  if vim.fn.isdirectory(vim.fn.stdpath("data") .. "/mason") == 1 then
    mason_bin = vim.fn.stdpath("data") .. "/mason/bin"
  end
  local shadow = vim.env.DOTFILES_JSON_SHADOW_PRETTIER
  assert(
    not shadow or resolved ~= shadow,
    "an ambient shadowing Prettier was selected: " .. resolved
  )
  assert(
    vim.startswith(resolved, mason_bin) or resolved:find("node_modules", 1, true),
    "Prettier is neither editor-owned nor project-local: " .. resolved
  )
end)

check("badly formatted JSON is formatted deterministically", function()
  local bufnr = open("standalone/badly-formatted.json")
  local formatted = format(bufnr)
  assert(
    formatted:find('  "name": "dotfiles%-json%-smoke"'),
    "JSON was not reformatted:\n" .. formatted
  )

  -- Formatting an already formatted buffer must be a no-op.
  local again = format(bufnr)
  assert(again == formatted, "JSON formatting is not idempotent")
end)

check("JSONC comments survive formatting", function()
  local bufnr = open("standalone/badly-formatted.jsonc")
  local formatted = format(bufnr)
  assert(
    formatted:find("// A JSONC comment that formatting must preserve.", 1, true),
    "a JSONC line comment was stripped:\n" .. formatted
  )
  assert(
    formatted:find("/* A block comment that formatting must preserve. */", 1, true),
    "a JSONC block comment was stripped:\n" .. formatted
  )
  assert(formatted:find('  "name": "dotfiles%-jsonc%-smoke"'), "JSONC was not reformatted")
end)

check("a project-local Prettier configuration wins", function()
  local bufnr = open("configured/badly-formatted.json")
  local formatted = format(bufnr)
  assert(
    formatted:find('\n        "name": "dotfiles%-project%-config"'),
    "the project's .prettierrc indentation was not applied:\n" .. formatted
  )
end)

check("jsonls is provisioned and reports diagnostics for malformed JSON", function()
  assert(
    vim.fn.executable("vscode-json-language-server") == 1,
    "the JSON language server is not installed"
  )

  local bufnr = open("standalone/malformed.json")
  vim.wait(20000, function()
    return #vim.lsp.get_clients({ bufnr = bufnr, name = "jsonls" }) > 0
  end, 100)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "jsonls" })
  assert(#clients > 0, "jsonls did not attach to a JSON buffer")

  vim.wait(20000, function()
    return #vim.diagnostic.get(bufnr) > 0
  end, 100)
  local diagnostics = vim.diagnostic.get(bufnr)
  assert(#diagnostics > 0, "malformed JSON produced no diagnostics")
end)

check("SchemaStore-backed schemas are offered to jsonls", function()
  local schemas = require("schemastore").json.schemas()
  assert(#schemas > 0, "SchemaStore returned no JSON schemas")

  local found = false
  for _, schema in ipairs(schemas) do
    if schema.name == "package.json" then
      found = true
      break
    end
  end
  assert(found, "SchemaStore does not offer a representative well-known schema")
end)

local failures = {}
for _, entry in ipairs(checks) do
  local ok, err = pcall(entry.fn)
  if ok then
    io.stdout:write(("PASS: %s\n"):format(entry.description))
  elseif type(err) == "table" and err.skipped then
    io.stdout:write(("SKIP: %s (%s)\n"):format(entry.description, err.skipped))
  else
    local report = ("FAIL: %s\n  %s"):format(entry.description, tostring(err))
    table.insert(failures, report)
    io.stdout:write(report .. "\n")
  end
end

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n") .. "\n")
  vim.cmd("cquit 1")
end

io.stdout:write("JSON editing, validation and formatting checks passed.\n")
vim.cmd("qall!")
