return {
  -- Mason: official Roslyn language server + netcoredbg.
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.registries = opts.registries or {
        "github:mason-org/mason-registry",
      }

      if not vim.tbl_contains(opts.registries, "github:Crashdummyy/mason-registry") then
        table.insert(opts.registries, "github:Crashdummyy/mason-registry")
      end

      opts.ensure_installed = opts.ensure_installed or {}

      for _, package in ipairs({
        "roslyn",
        "netcoredbg",
      }) do
        if not vim.tbl_contains(opts.ensure_installed, package) then
          table.insert(opts.ensure_installed, package)
        end
      end
    end,
  },

  -- Official Microsoft Roslyn integration.
  {
    "seblyng/roslyn.nvim",
    opts = {},
  },

  -- C# Tree-sitter parser.
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}

      if not vim.tbl_contains(opts.ensure_installed, "c_sharp") then
        table.insert(opts.ensure_installed, "c_sharp")
      end
    end,
  },

  -- .NET debugging through LazyVim's generic nvim-dap infrastructure.
  {
    "mfussenegger/nvim-dap",
    optional = true,
    opts = function()
      local dap = require("dap")

      dap.adapters.netcoredbg = {
        type = "executable",
        command = vim.fn.exepath("netcoredbg"),
        args = { "--interpreter=vscode" },
        options = {
          detached = false,
        },
      }

      dap.configurations.cs = {
        {
          type = "netcoredbg",
          name = "Launch .NET DLL",
          request = "launch",
          program = function()
            return vim.fn.input("Path to dll: ", vim.fn.getcwd() .. "/", "file")
          end,
          cwd = "${workspaceFolder}",
        },
      }
    end,
  },

  -- .NET project and test tooling.
  {
    "GustavEikaas/easy-dotnet.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "folke/snacks.nvim",
    },

    cmd = { "Dotnet" },
    ft = { "cs" },

    opts = {
      picker = "snacks",

      -- Roslyn is handled by roslyn.nvim.
      lsp = {
        enabled = false,
      },

      -- DAP is configured separately above.
      debugger = {
        auto_register_dap = false,
      },

      -- Don't add EasyDotnet mappings to project files.
      csproj_mappings = false,
      fsproj_mappings = false,

      test_runner = {
        -- Use EasyDotnet's native MTP-aware test integration.
        neotest_integration = false,
        auto_start_testrunner = true,

        -- Persistent test explorer when explicitly opened.
        -- LazyVim's splitright setting puts this on the right.
        viewmode = "vsplit",
        vsplit_width = 45,

        -- C# buffer mappings preserve LazyVim's existing test semantics.
        mappings = {
          run_test_from_buffer = {
            lhs = "<leader>tr",
            desc = "Run Nearest",
          },

          run_all_tests_from_buffer = {
            lhs = "<leader>tt",
            desc = "Run File",
          },

          debug_test_from_buffer = {
            lhs = "<leader>td",
            desc = "Debug Nearest",
          },
        },
      },
    },
  },
}
