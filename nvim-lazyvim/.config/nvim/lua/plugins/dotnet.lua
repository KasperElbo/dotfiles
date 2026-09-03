return {
  -- Mason owns editor-specific .NET tooling.
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

  -- Official Microsoft Roslyn language-server integration.
  {
    "seblyng/roslyn.nvim",
    opts = {},
  },

  -- C# Tree-sitter support.
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}

      if not vim.tbl_contains(opts.ensure_installed, "c_sharp") then
        table.insert(opts.ensure_installed, "c_sharp")
      end
    end,
  },

  -- .NET project, test and debugging integration.
  {
    "GustavEikaas/easy-dotnet.nvim",

    dependencies = {
      "nvim-lua/plenary.nvim",
      "folke/snacks.nvim",
      "mfussenegger/nvim-dap",
    },

    cmd = { "Dotnet" },
    ft = { "cs" },

    opts = {
      picker = "snacks",

      -- Roslyn is handled by roslyn.nvim above.
      lsp = {
        enabled = false,
      },

      -- EasyDotnet owns project-aware DAP registration and uses the
      -- Mason-owned netcoredbg binary instead of downloading another copy.
      debugger = {
        bin_path = LazyVim.get_pkg_path("netcoredbg", "/libexec/netcoredbg/netcoredbg"),
        auto_register_dap = true,
      },

      -- Don't add mappings when editing project files themselves.
      csproj_mappings = false,
      fsproj_mappings = false,

      test_runner = {
        -- Use EasyDotnet's native MTP-aware test runner.
        neotest_integration = false,

        -- Keep test discovery available in the background.
        auto_start_testrunner = true,

        -- Persistent test explorer.
        -- LazyVim already has splitright=true, so this opens on the right.
        viewmode = "vsplit",
        vsplit_width = 45,

        -- Preserve LazyVim's normal test semantics in C# buffers.
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
