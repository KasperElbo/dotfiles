local M = {}

function M.packages(path)
  path = path or (vim.fn.stdpath("config") .. "/mason-packages.txt")

  local packages = {}
  for _, line in ipairs(vim.fn.readfile(path)) do
    local package = vim.trim(line)
    if package ~= "" and not vim.startswith(package, "#") then
      table.insert(packages, package)
    end
  end

  if #packages == 0 then
    error("Mason package inventory is empty: " .. path)
  end

  return packages
end

return M
