local ocaml_enabled = vim.fn.executable("opam") == 1

return {
  -- Keep the optional profile genuinely optional: the parser is only added
  -- when opam is present on this machine.
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      if ocaml_enabled and type(opts.ensure_installed) == "table" then
        if not vim.tbl_contains(opts.ensure_installed, "ocaml") then
          table.insert(opts.ensure_installed, "ocaml")
        end
      end
    end,
  },

  -- ocamllsp and ocamlformat must come from the active opam switch. In
  -- particular, Mason must not install its own version of the language server.
  {
    "neovim/nvim-lspconfig",
    optional = true,
    opts = function(_, opts)
      if not ocaml_enabled then
        return
      end

      opts.servers = opts.servers or {}
      opts.servers.ocamllsp = {
        mason = false,
        cmd = { "opam", "exec", "--", "ocamllsp" },
        filetypes = {
          "ocaml",
          "ocaml.interface",
          "ocaml.menhir",
          "ocaml.ocamllex",
          "reason",
          "dune",
        },
        root_markers = {
          "dune-project",
          "dune-workspace",
          ".git",
        },
      }
    end,
  },

  -- Earlybird is an opam-owned DAP adapter for OCaml bytecode programs.
  -- nvim-dap itself is supplied by LazyVim's DAP extra.
  {
    "mfussenegger/nvim-dap",
    optional = true,
    opts = function(_, opts)
      if not ocaml_enabled then
        return opts
      end

      local dap = require("dap")
      dap.adapters.ocamlearlybird = {
        type = "executable",
        command = "opam",
        args = { "exec", "--", "ocamlearlybird", "debug" },
      }

      local ocaml_dune = require("config.ocaml_dune")

      dap.configurations.ocaml = dap.configurations.ocaml or {}
      table.insert(dap.configurations.ocaml, {
        name = "OCaml: build and debug Dune executable",
        type = "ocamlearlybird",
        request = "launch",
        program = ocaml_dune.dune_program,
        cwd = function()
          return ocaml_dune.project_root(0) or vim.fn.getcwd()
        end,
      })
      table.insert(dap.configurations.ocaml, {
        name = "OCaml: debug bytecode executable (manual)",
        type = "ocamlearlybird",
        request = "launch",
        program = ocaml_dune.manual_program,
        cwd = function()
          return ocaml_dune.project_root(0) or vim.fn.getcwd()
        end,
      })

      return opts
    end,
  },
}
