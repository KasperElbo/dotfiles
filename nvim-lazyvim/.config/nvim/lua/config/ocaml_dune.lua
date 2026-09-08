local M = {}

local last_target_by_root = {}

local function run_command(args, options)
  return vim.system(args, {
    cwd = options.cwd,
    text = true,
  }):wait()
end

local function command_error(prefix, result)
  local detail = vim.trim(result.stderr or "")
  if detail == "" then
    detail = vim.trim(result.stdout or "")
  end

  if detail == "" then
    return string.format("%s (exit status %s)", prefix, result.code or "unknown")
  end

  return prefix .. ":\n" .. detail
end

local function abort(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "OCaml debugger" })
  return require("dap").ABORT
end

function M.project_root(bufnr, finder)
  local buffer_name = vim.api.nvim_buf_get_name(bufnr or 0)
  local start = buffer_name ~= "" and buffer_name or vim.fn.getcwd()
  if vim.fn.isdirectory(start) == 0 then
    start = vim.fs.dirname(start)
  end

  local find = finder or vim.fs.find
  local marker = find({ "dune-workspace", "dune-project" }, {
    path = start,
    upward = true,
  })[1]

  return marker and vim.fs.dirname(marker) or nil
end

function M.parse_rule_targets(output)
  local targets = {}
  local seen = {}

  for files_blob in output:gmatch("%(targets%s*%(%(files%s*%((.-)%)") do
    for target in files_blob:gmatch("%S+") do
      if target:match("%.bc$") and not seen[target] then
        seen[target] = true
        table.insert(targets, target)
      end
    end
  end

  table.sort(targets)
  return targets
end

function M.check_workspace_root(dune_project_content)
  local lang_major = dune_project_content:match("%(lang%s+dune%s+(%d+)%.")
  if not lang_major or tonumber(lang_major) < 3 then
    return nil
  end

  if dune_project_content:match("%(map_workspace_root%s+false%)") then
    return nil
  end

  return "Add (map_workspace_root false) to dune-project: Earlybird cannot resolve "
    .. "breakpoints under Dune 3.0+ without it."
end

function M.check_dune_project(root, read_file)
  local read = read_file or vim.fn.readfile
  local ok, lines = pcall(read, root .. "/dune-project")
  if not ok or not lines then
    return nil
  end

  return M.check_workspace_root(table.concat(lines, "\n"))
end

function M.discover_targets(root, runner)
  local run = runner or run_command
  local result = run({
    "opam",
    "exec",
    "--",
    "dune",
    "describe",
    "rules",
  }, { cwd = root })

  if result.code ~= 0 then
    return nil, command_error("Could not discover Dune bytecode targets", result)
  end

  local targets = M.parse_rule_targets(result.stdout or "")
  if #targets == 0 then
    return nil, "Dune did not report any .bc targets. Add (modes byte exe) to the executable stanza."
  end

  return targets
end

local function display_target(target)
  return (target:gsub("^_build/[^/]+/", ""))
end

local function target_is_known(targets, expected)
  for _, target in ipairs(targets) do
    if target == expected then
      return true
    end
  end
  return false
end

function M.select_target(root, targets)
  if #targets == 1 then
    last_target_by_root[root] = targets[1]
    return targets[1]
  end

  local last_target = last_target_by_root[root]
  if last_target and target_is_known(targets, last_target) then
    local action = vim.fn.confirm(
      "Reuse the last OCaml debug target?\n" .. display_target(last_target),
      "&Reuse\n&Choose another\n&Cancel",
      1
    )
    if action == 1 then
      return last_target
    elseif action == 3 or action == 0 then
      return nil
    end
  end

  local choices = { "Select Dune bytecode target:" }
  for index, target in ipairs(targets) do
    choices[index + 1] = string.format("%d. %s", index, display_target(target))
  end

  local selection = vim.fn.inputlist(choices)
  if selection < 1 or selection > #targets then
    return nil
  end

  last_target_by_root[root] = targets[selection]
  return targets[selection]
end

function M.artifact_path(root, target)
  if target:sub(1, 1) == "/" then
    return vim.fs.normalize(target)
  end
  return vim.fs.normalize(root .. "/" .. target)
end

function M.build_target(root, target, runner, stat)
  local run = runner or run_command
  local result = run({ "opam", "exec", "--", "dune", "build", target }, {
    cwd = root,
  })

  if result.code ~= 0 then
    return nil, command_error("Dune failed to build " .. display_target(target), result)
  end

  local artifact = M.artifact_path(root, target)
  local fs_stat = stat or vim.uv.fs_stat
  if not fs_stat(artifact) then
    return nil, "Dune completed successfully but did not produce " .. artifact
  end

  return artifact
end

function M.dune_program()
  local root = M.project_root(0)
  if not root then
    return abort("No dune-project or dune-workspace was found above the current OCaml file")
  end

  local workspace_root_error = M.check_dune_project(root)
  if workspace_root_error then
    return abort(workspace_root_error)
  end

  local targets, discovery_error = M.discover_targets(root)
  if not targets then
    return abort(discovery_error)
  end

  local target = M.select_target(root, targets)
  if not target then
    return abort("OCaml debug target selection was cancelled")
  end

  local artifact, build_error = M.build_target(root, target)
  if not artifact then
    return abort(build_error)
  end

  return artifact
end

function M.manual_program()
  local root = M.project_root(0) or vim.fn.getcwd()
  local program = vim.fn.input("OCaml bytecode executable: ", root .. "/", "file")
  if program == "" then
    return abort("OCaml bytecode executable selection was cancelled")
  end

  program = vim.fs.normalize(vim.fn.fnamemodify(program, ":p"))
  if not program:match("%.bc$") then
    return abort("Earlybird requires a .bc bytecode executable: " .. program)
  end
  if not vim.uv.fs_stat(program) then
    return abort("OCaml bytecode executable does not exist: " .. program)
  end

  return program
end

return M
