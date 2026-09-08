local repo_root = assert(vim.env.DOTFILES_TEST_ROOT)
package.path = repo_root .. "/nvim-lazyvim/.config/nvim/lua/?.lua;" .. package.path

local dune = require("config.ocaml_dune")

local original_executable = vim.fn.executable
vim.fn.executable = function()
  return 0
end
local specs = dofile(repo_root .. "/nvim-lazyvim/.config/nvim/lua/plugins/ocaml.lua")
vim.fn.executable = original_executable
for _, spec in ipairs(specs) do
  if spec[1] == "mfussenegger/nvim-dap" then
    local opts = {}
    assert(spec.opts(nil, opts) == opts, "DAP configuration must remain inert without opam")
  end
end

local root = dune.project_root(0, function(markers, options)
  assert(vim.deep_equal(markers, { "dune-workspace", "dune-project" }))
  assert(type(options.path) == "string")
  assert(options.upward)
  return { "/tmp/example/dune-project" }
end)
assert(root == "/tmp/example", "Dune root should be the marker's directory")

local targets = dune.parse_rule_targets(table.concat({
  "((deps ())",
  " (targets ((files (_build/default/bin/main.bc)) (directories ())))",
  " (context default)",
  " (action (chdir _build/default (run ocamlc.opt -o bin/main.bc ...))))",
  "",
  "((deps ())",
  " (targets ((files (_build/default/bin/main.exe)) (directories ())))",
  " (context default)",
  " (action (chdir _build/default (run ocamlopt.opt -o bin/main.exe ...))))",
  "",
  "((deps ())",
  " (targets ((files (_build/default/web/main.bc.js)) (directories ())))",
  " (context default)",
  " (action (run js_of_ocaml main.bc)))",
  "",
  "((deps ())",
  " (targets ((files (_build/dev/tools/admin.bc)) (directories ())))",
  " (context dev)",
  " (action (run ocamlc.opt -o admin.bc ...)))",
  "",
  "((deps ())",
  " (targets ((files (_build/default/bin/main.bc)) (directories ())))",
  " (context default)",
  " (action (copy bin/main.bc _build/default/bin/main.bc)))",
}, "\n"))
assert(vim.deep_equal(targets, {
  "_build/default/bin/main.bc",
  "_build/dev/tools/admin.bc",
}), "only unique Earlybird-compatible .bc targets should be discovered, ignoring .exe/.bc.js and action arguments")

assert(dune.check_workspace_root("(lang dune 2.9)\n(name hello)\n") == nil,
  "pre-3.0 dune-project files do not need map_workspace_root")
assert(dune.check_workspace_root("(lang dune 3.14)\n(map_workspace_root false)\n(name hello)\n") == nil,
  "map_workspace_root false satisfies the check")
local missing_root_error = dune.check_workspace_root("(lang dune 3.14)\n(name hello)\n")
assert(missing_root_error and missing_root_error:match("map_workspace_root false"),
  "dune lang 3.0+ without map_workspace_root false should be flagged")

assert(dune.check_dune_project("/tmp/example", function()
  error("dune-project not found")
end) == nil, "a missing dune-project must not block debugging")
assert(dune.check_dune_project("/tmp/example", function(path)
  assert(path == "/tmp/example/dune-project")
  return { "(lang dune 3.14)", "(name hello)" }
end):match("map_workspace_root false"))

local discovered = assert(dune.discover_targets("/tmp/example", function(args, options)
  assert(vim.deep_equal(args, {
    "opam",
    "exec",
    "--",
    "dune",
    "describe",
    "rules",
  }))
  assert(options.cwd == "/tmp/example")
  return {
    code = 0,
    stdout = "((deps ()) (targets ((files (_build/default/bin/main.bc)) (directories ()))) (context default) (action (progn)))",
    stderr = "",
  }
end))
assert(discovered[1] == "_build/default/bin/main.bc")

local no_targets, no_targets_error = dune.discover_targets("/tmp/example", function()
  return {
    code = 0,
    stdout = "((deps ()) (targets ((files (_build/default/bin/main.exe)) (directories ()))) (context default) (action (progn)))",
    stderr = "",
  }
end)
assert(no_targets == nil and no_targets_error:match("%(modes byte exe%)"))

local artifact = assert(dune.build_target(
  "/tmp/example",
  "_build/custom/bin/main.bc",
  function(args, options)
    assert(vim.deep_equal(args, {
      "opam",
      "exec",
      "--",
      "dune",
      "build",
      "_build/custom/bin/main.bc",
    }))
    assert(options.cwd == "/tmp/example")
    return { code = 0, stdout = "", stderr = "" }
  end,
  function(path)
    return path == "/tmp/example/_build/custom/bin/main.bc" and {}
  end
))
assert(artifact == "/tmp/example/_build/custom/bin/main.bc")

local failed_artifact, build_error = dune.build_target(
  "/tmp/example",
  "_build/default/bin/main.bc",
  function()
    return { code = 1, stdout = "", stderr = "File bin/main.ml, line 1: build failed" }
  end,
  function()
    error("a failed build must not inspect or launch a stale artifact")
  end
)
assert(failed_artifact == nil)
assert(build_error:match("Dune failed to build bin/main.bc"))
assert(build_error:match("build failed"))

local missing_artifact, missing_error = dune.build_target(
  "/tmp/example",
  "_build/default/bin/main.bc",
  function()
    return { code = 0, stdout = "", stderr = "" }
  end,
  function()
    return nil
  end
)
assert(missing_artifact == nil and missing_error:match("did not produce"))

local abort_token = {}
package.loaded.dap = { ABORT = abort_token }
local original_project_root = dune.project_root
local original_notify = vim.notify
local notification
dune.project_root = function()
  return nil
end
vim.notify = function(message, level, options)
  notification = { message = message, level = level, options = options }
end
assert(dune.dune_program() == abort_token, "missing Dune roots should abort DAP cleanly")
assert(notification.message:match("No dune%-project or dune%-workspace"))
assert(notification.level == vim.log.levels.ERROR)
dune.project_root = original_project_root
vim.notify = original_notify

local original_check_dune_project = dune.check_dune_project
dune.project_root = function()
  return "/tmp/example"
end
dune.check_dune_project = function()
  return "Add (map_workspace_root false) to dune-project: Earlybird cannot resolve "
    .. "breakpoints under Dune 3.0+ without it."
end
vim.notify = function(message, level, options)
  notification = { message = message, level = level, options = options }
end
assert(dune.dune_program() == abort_token, "a missing map_workspace_root setting should abort DAP cleanly")
assert(notification.message:match("map_workspace_root false"))
assert(notification.level == vim.log.levels.ERROR)
dune.project_root = original_project_root
dune.check_dune_project = original_check_dune_project
vim.notify = original_notify

print("OCaml Dune DAP checks passed.")
