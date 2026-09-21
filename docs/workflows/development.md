# Language and project workflows

Per-language and per-project workflows: what is installed, which manager owns
it, and how the editor integration is expected to be used. Ownership rules
themselves are in
[package-ownership.md](../architecture/package-ownership.md).

## .NET development

The .NET setup separates language support, testing, and debugging.

```text
roslyn.nvim
    C# language intelligence

EasyDotnet
    solution/project awareness
    native MTP/xUnit test runner
    project-aware DAP registration and bundled netcoredbg

nvim-dap
    generic debugger framework and UI

Mason
    Roslyn and other editor-only tooling, but not the .NET debugger

mise
    .NET SDK/runtime and the pinned EasyDotnet companion tool
```

EasyDotnet's own LSP integration is disabled; `roslyn.nvim` owns LSP client
configuration and Mason owns the Roslyn binary. The mise-managed
`dotnet:EasyDotnet` global tool is the companion server required by the
`easy-dotnet.nvim` plugin. EasyDotnet 3.4.25 owns and selects the bundled
`netcoredbg` for the current runtime platform.

## Testing

The tested setup uses:

- xUnit v3
- Microsoft Testing Platform
- EasyDotnet native test runner

C# buffers preserve LazyVim's test semantics:

```text
<leader>tr    Run Nearest
<leader>tt    Run File
<leader>td    Debug Nearest
```

Open the EasyDotnet test explorer with:

```vim
:Dotnet testrunner
```

It is configured as a right-side vertical split.

## Debugging

EasyDotnet owns the project-aware DAP registration and launches its bundled
`netcoredbg` engine. On Apple Silicon the resolved path must be
`tools/netcoredbg/osx-arm64/netcoredbg`; it must not point at Mason's
Intel-only `netcoredbg` package. Mason's generic `NetCoreDbg: Launch`
configuration is suppressed so only EasyDotnet appears in the C# debug picker.
`nvim-dap` remains the generic debugger framework.

The repository does not install Rosetta as a workaround. Other than the
EasyDotnet bundle selected for the current runtime platform, macOS tools must
remain native arm64. The macOS verifier checks the EasyDotnet health output,
the resolved path, and the binary architecture. CI also runs a disposable
breakpoint/evaluate session against a native arm64 .NET process; a separate
probe records whether Mason's legacy x86_64 binary starts under the runner's
existing Rosetta installation and whether mixed-architecture debugging works.

Repository-specific `.vscode/launch.json` files are considered project configuration rather than workstation configuration.

## Formatting

C# formatting uses project-local CSharpier through Conform.

CSharpier is declared by the repository being edited, in its local tool
manifest (`.config/dotnet-tools.json`), and Conform invokes it through the .NET
SDK entry point:

```text
dotnet csharpier format --stdin-path <file>
```

Conform runs that command in the nearest directory above the edited file that
declares a tool manifest, so the project's pinned CSharpier is used regardless
of the directory Neovim was started in. Outside such a project the formatter is
simply unavailable: the editor never falls back to a `csharpier` executable it
finds on `PATH`, and neither mise, Mason, npm, nor the system package manager
installs a second copy.

Restore the tool once per clone:

```bash
dotnet tool restore
```

Until then, formatting reports `Run "dotnet tool restore" to make the
"csharpier" command available.`

---

## Angular / TypeScript development

The frontend setup uses:

```text
VTSLS
Angular Language Server
ESLint Language Server
Conform
project-local Prettier
project-local ESLint/angular-eslint
```

From a repository with a committed `package.json`, use its scripts rather than
globally installed framework commands:

```bash
npm install
npm run build
npm start
npm test
npm run lint
npx prettier --check .
```

Open Neovim from the repository root after installing dependencies. Use
`:checkhealth vim.lsp` to confirm that VTSLS, Angular Language Server, and ESLint
are attached when the repository has a supported ESLint configuration. VTSLS
uses the repository's TypeScript SDK.

Prettier remains project-local:

```bash
npm install --save-dev prettier
```

ESLint remains project-local.

The editor-side `eslint-lsp` is Mason-managed. Its formatter is disabled so
ESLint provides diagnostics and code actions while project-local Prettier is
the only JavaScript, TypeScript, and Angular-template formatter.

ESLint handles diagnostics/code actions; Prettier owns formatting.

The split is intentional:

- mise owns the Node runtime
- each repository owns TypeScript, ESLint, angular-eslint, Prettier, and its
  test runner through `package.json`
- Mason owns VTSLS, Angular Language Server, the ESLint editor bridge, and the
  JavaScript debug adapter
- VTSLS is configured to use the workspace TypeScript SDK

JSON and YAML language servers remain Mason-owned, and so does the Prettier
that formats them; see "JSON and JSONC" below for the ownership rule.

## Debugging

The LazyVim TypeScript extra registers the Mason-owned `js-debug-adapter` for
Node, Chrome, and Chromium-compatible workflows. Project-specific launch
details belong in `.vscode/launch.json`; the workstation does not guess the
application URL or browser process.

The Angular smoke fixture contains an attach configuration that proves source
mapping without requiring a global Angular CLI. Modern Angular development
uses the `application` builder, but its esbuild source maps currently have an
[open breakpoint-binding bug in `vscode-js-debug`](https://github.com/microsoft/vscode-js-debug/issues/2304).
The fixture therefore keeps its normal build and serve workflow on the modern
builder and provides a debug-only webpack target until that upstream bug is
resolved. To exercise it manually:

```bash
cp -R tests/fixtures/angular-smoke /tmp/angular-smoke
cd /tmp/angular-smoke
npm install
npm run start:debug
```

In another terminal, start Chrome or Chromium with a disposable debug profile:

```bash
chromium \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/angular-debug-profile \
  http://localhost:4200
```

Open `/tmp/angular-smoke` in Neovim, set a breakpoint on
`this.answer.set(answer)` in `src/app/app.ts`, press `<leader>dc`, select
`Angular: Attach Chrome/Chromium`, and click **Calculate** in the browser. The
breakpoint should resolve against the emitted source map and stop on the
TypeScript line. Replace `chromium` with the installed Chrome/Chromium command
when necessary.

---

## Python development

The Python setup uses mise for the interpreter and `uv` command, while every
project owns its environment and development dependencies:

```bash
uv init --package
uv add --dev pytest ruff
uv sync
uv run python -m your_package
uv run pytest
uv run ruff check .
uv run ruff format --check .
uv build
```

`uv sync` creates a project-local `.venv`; it does not modify the mise-managed
Python installation. In Neovim, the LazyVim Python extra provides Pyright,
Ruff, pytest discovery through Neotest, virtual-environment selection with
`<leader>cv`, and debugging through `nvim-dap-python` plus Mason's `debugpy`.
Use `:checkhealth vim.lsp` to confirm Pyright and Ruff are attached to a Python
buffer.

Formatting and lint ownership is split deliberately:

- the project declares Ruff and all rules in `pyproject.toml`, so shell and CI
  use `uv run ruff ...`
- Mason's Ruff binary is editor-only and Conform uses it for format-on-save
- Mason owns Pyright and debugpy because they are editor adapters
- pytest and all application dependencies remain in the project

Repository-specific debug targets belong in `.vscode/launch.json`. To verify
the included module-launch example:

```bash
cp -R tests/fixtures/python-smoke /tmp/python-smoke
cd /tmp/python-smoke
uv sync --all-groups
nvim .
```

Set a breakpoint on `answer = left * right` in
`src/dotfiles_smoke/calculator.py`, press `<leader>dc`, and choose
`Python: Module`.
The debugger should stop inside the project interpreter without adding debugpy
to the project's dependencies.

---

## OCaml development

Install the profile explicitly:

```bash
./install.sh --ocaml
```

Native build prerequisites differ per platform; `opam` itself always owns
every compiler switch and OCaml ecosystem package installed afterwards:

| Platform | Native provider | Packages |
| --- | --- | --- |
| Fedora | DNF | `bzip2`, `bubblewrap`, `gcc`, `gcc-c++`, `m4`, `make`, `opam`, `patch`, `pkgconf-pkg-config` |
| Fedora WSL | DNF, a smaller set (the WSL baseline already owns compiler/build prerequisites) | `bubblewrap`, `m4`, `opam`, `patch`, `pkgconf-pkg-config` |
| macOS | Homebrew | `opam`, `pkg-config`, `gmp` |

`common/verify-ocaml.sh` fails when `opam` resolves outside that platform's
native package prefix (`/usr` on Fedora/Fedora WSL, the Homebrew prefix on
macOS), since that is not the `opam` this profile installed.

The default profile creates the named switch `dotfiles-ocaml-5.5.0`, selects it
as the global opam switch, and installs dune, utop, `ocaml-lsp-server`,
OCamlFormat, and Earlybird into that switch. The selection is recorded in the machine-local
file `~/.config/dotfiles/ocaml.conf`; it is not tracked by Git. The tracked Zsh
configuration sources opam's generated environment hook when it exists, so a
new shell exposes the selected switch without allowing `opam init` to edit
`.zshrc`.

To intentionally bootstrap a different stable compiler release:

```bash
OCAML_COMPILER_VERSION=5.4.1 ./install.sh --ocaml
```

The version becomes a separate named opam switch. Existing switches are not
deleted or overwritten. The override round-trips: `ocaml.conf` records both the
switch and the exact compiler, and verification fails if the switch, the
recorded compiler, and the compiler actually inside the switch ever disagree.

### What OCaml verification proves

`common/verify-ocaml.sh` is the single OCaml verifier on every platform, and
every platform verifier runs it. It reads whether the profile was selected from
the install lifecycle state rather than from a forwarded flag, so it reaches
three distinct verdicts:

| Machine | Verdict |
| --- | --- |
| Profile not selected, opam absent | pass, reported as not applicable |
| Profile selected and healthy | pass |
| Profile selected and missing or broken | fail |

When the profile is selected it proves that opam lives inside the platform's
native package prefix rather than merely answering on `PATH`, that the recorded
switch exists and is the selected one, that the compiler inside it is exactly
the recorded version, that dune, `ocamlearlybird`, `ocamllsp`, OCamlFormat, and
utop are present, that opam's generated Zsh hook exists and parses, and that a
throwaway program compiles and runs. Every command runs through
`opam exec --switch`, so the result never depends on restarting a login shell
and is valid in the same process that just installed the profile.

## Project workflow

For a new project using the profile switch:

```bash
dune init proj hello
cd hello
opam install . --deps-only --with-test
dune build
dune exec hello
dune runtest
dune fmt
dune utop
nvim .
```

`dune init proj hello` is the easiest starting point for a new application: it
creates `dune-project` plus `bin`, `lib`, and `test` directories. To make its
executable debuggable with Earlybird, two changes are required.

First, ensure the executable stanza in `bin/dune` includes bytecode mode:

```lisp
(executable
 (name main)
 (modes byte exe))
```

Second, add `(map_workspace_root false)` to `dune-project`. Dune 3.0 and above
remaps build-tree paths in a way that prevents Earlybird from resolving
breakpoints back to source files; `dune init proj` does not add this line, so
it must be added by hand:

```lisp
(lang dune 3.14)

(map_workspace_root false)

(name hello)
```

Without this, breakpoints will silently never verify and the debug session
will run to completion without stopping, even though the build and launch
otherwise succeed. Note also that OCaml's bytecode debug info only attaches
to actual sub-expressions: a bare one-line `let () = print_endline "..."` (the
`dune init proj` default) has no breakpointable location on its single line.
Use a program with at least one real intermediate expression (for example a
`let` binding on its own line before the final call) if you want to test that
breakpoints are hit.

Use the executable name declared by the project's `dune` files with
`dune exec`. For an existing repository, begin with
`opam install . --deps-only --with-test`, then use its committed build, run,
and test aliases.

Projects that require a different compiler should create a local switch and
install the editor tools into that same switch:

```bash
opam switch create . 5.4.1
opam install . --deps-only --with-test
opam install dune utop ocaml-lsp-server ocamlformat
```

Because opam automatically selects a local switch from its directory, shell
commands and Neovim then use the project-specific compiler and packages.

## Neovim workflow

The LazyVim configuration becomes active only when the `opam` executable is
present. It adds the OCaml Treesitter parser and configures `ocamllsp` for
OCaml, interfaces, Dune files, Menhir, ocamllex, and Reason. The server starts
through `opam exec`, so it follows the switch selected for the project. Mason
is explicitly disabled for this server.

OCaml LSP provides diagnostics, completion, hover information, definitions,
references, rename, and code actions through the normal LazyVim mappings.
Formatting uses the OCamlFormat binary from the same switch through LSP; use
`<leader>cf` or the normal format-on-save behavior. Run Dune commands from a
LazyVim terminal (`<C-/>`) when an editor-adjacent build or test loop is useful.
Use `:checkhealth vim.lsp` in an OCaml buffer to confirm that `ocamllsp` is
attached.

## Debugging

The optional profile installs the opam-owned `earlybird` package. It provides
the `ocamlearlybird` Debug Adapter Protocol server, and the LazyVim DAP extra
is configured to launch it through the active opam switch. In an OCaml buffer:

1. Set a breakpoint with `<leader>db` (`:DapToggleBreakpoint`).
2. Press `<leader>dc` (`:DapContinue`) and choose
   `OCaml: build and debug Dune executable`.
3. Select the relevant `.bc` target when the project exposes more than one.
   The most recently selected target is offered first for reuse during the
   Neovim session.
4. LazyVim asks Dune to build that exact target and launches Earlybird only
   after the build succeeds.

Target discovery uses Dune's rule description rather than assuming an
`_build/default` layout, so alternate Dune build contexts resolve to the
artifact path reported by Dune. A failed build is shown as an editor error and
the DAP session is not started. Projects with generated or otherwise unusual
layouts can choose `OCaml: debug bytecode executable (manual)` and pick an
existing `.bc` artifact directly.

The adapter supports normal launch, breakpoints, stepping, stack inspection,
and variables through `nvim-dap`. It is restricted to bytecode executables;
native binaries are not supported. It is also a launch configuration, not a
general attach-to-an-already-running-native-process workflow. Earlybird has
known limitations around Dune's workspace-root handling (see
[Project workflow](#project-workflow) for the required `dune-project`
setting); `OCaml: build and debug Dune executable` checks for
`(map_workspace_root false)` before launching and aborts with an explicit
error if it is missing, rather than starting a session that can never stop at
a breakpoint. The repository's smoke fixture exercises the required bytecode
build shape; the interactive breakpoint itself must be checked in Neovim
because it depends on the editor session.

---

## Development workflow smoke tests

`./scripts/test-dev-workflows.sh` validates an **installed machine** by
exercising real project tooling in temporary directories. It is deliberately
separate from `./scripts/test.sh`, which runs the repository's own offline
unit, contract and mocked-installer suites and never touches the network or
the installed toolchain.

```bash
./scripts/test-dev-workflows.sh            # .NET, Angular, Python, JSON
./scripts/test-dev-workflows.sh --dotnet
./scripts/test-dev-workflows.sh --angular
./scripts/test-dev-workflows.sh --python
./scripts/test-dev-workflows.sh --json
./scripts/test-dev-workflows.sh --ocaml
./scripts/test-dev-workflows.sh --latex
```

Selectors combine, so `--python --json` runs exactly those two.

The installers forward to the same script through one canonical flag,
`--dev-workflows`:

```bash
./install.sh --platform fedora --dev-workflows
./install.sh --platform fedora-wsl --dev-workflows
./install.sh --platform macos --dev-workflows
```

The earlier platform-specific spellings still work and resolve to identical
behaviour, but they are deprecated and warn: `--smoke-test` on Fedora WSL and
`--workflows`/`--no-workflows` on macOS. (The unrelated VM-host
`--smoke-test`, which renders a guest definition without creating it, is a
different option and is unchanged.) The reduced Parrot CTF profile rejects
`--dev-workflows` explicitly: it has no workstation language runtimes, and
installing them only so the flag exists would defeat the point of the profile.

Each workflow reports independently as `PASS`, `FAIL`, or `SKIP` with a
reason, and the command exits non-zero only when a workflow actually failed. A
missing runtime is a skip rather than a failure, so the same command is
meaningful on machines with different optional profiles installed. Generated
projects live only below one temporary directory and are removed as soon as
each workflow finishes, including when it fails part-way through.

The .NET check creates a disposable console and xUnit project, then restores,
builds, tests, and runs them, and formats a fixture with the project-local
CSharpier.
The Angular check installs only fixture-local dependencies, formats, lints,
tests, exercises both the modern and debug builds with source maps, starts the
debug server, and probes it.
The Python check resolves an isolated environment, runs the package and tests,
lints, checks formatting, and builds both source and wheel distributions.
The JSON check opens disposable `.json` and `.jsonc` files in the installed
Neovim and verifies filetypes, Tree-sitter parsing, `jsonls` diagnostics,
SchemaStore schemas, and Conform formatting, including that a shadowing
`prettier` on `PATH` is not used and that JSONC comments survive.
The OCaml check resolves the fixture through opam and exercises Dune build,
run, test, format, and bytecode targets using the configured profile switch.
The LaTeX check formats and builds a multi-file document, resolves a BibLaTeX
citation through Biber, verifies its PDF, and checks a deliberate compile
error.

---

## JSON and JSONC

JSON and JSONC editing is part of the default shared LazyVim profile. Opening
a `.json` or `.jsonc` file gives Tree-sitter syntax support, `jsonls`
diagnostics and completion, SchemaStore-backed schemas for well-known files,
and deterministic formatting through Conform.

Ownership:

| Piece | Owner |
|---|---|
| Language support and schemas | `lazyvim.plugins.extras.lang.json` |
| Language server | Mason `json-lsp` |
| Formatter | Mason `prettier`, mapped by `lazyvim.plugins.extras.formatting.prettier` |

Formatting uses the normal LazyVim format action (`<leader>cf`) and the normal
repository-wide format-on-save policy. There is no JSON-specific save hook, so
the usual LazyVim toggle still governs it.

Prettier is the one editor-side exception to the project-only tooling rule,
and the exception is narrow. Conform resolves `prettier` from the project's
`node_modules` first, so a repository that declares its own Prettier still
formats with its own pinned version and its own `.prettierrc`. The Mason copy
exists only so that a standalone JSON, YAML or Markdown file is formattable on
a clean install, without depending on a globally installed npm Prettier that
the repository never declared. `vim.g.lazyvim_prettier_needs_config` is left
at `false` for that reason.

Because the installer provisions the tracked Mason inventory directly rather
than through Mason's asynchronous `ensure_installed` loop, `prettier` is
listed in `nvim-lazyvim/.config/nvim/mason-packages.txt`. That file is the
single list the bootstrap installs and the verifiers check, so enabling the
extra alone would not have been enough.

The reduced Parrot CTF profile deliberately excludes this workflow. It has no
JSON extra, no `json-lsp` and no `prettier`: that profile exists to stay small
around Python and Lua scripting, and a language server plus a Node-based
formatter is exactly the workstation weight it avoids. JSON files still open
and edit there with core Neovim; they simply have no language server or
Prettier.

Verify the installed behaviour with:

```bash
./scripts/test-dev-workflows.sh --json
```

---

## Markdown

Markdown authoring is part of the default shared LazyVim profile. LazyVim owns
the Markdown extra and its plugins; Mason owns the editor-facing Marksman
binary. A repository's Prettier, Markdown linter and table-of-contents tooling
remain project-local.

LazyVim core already provides the `markdown` and `markdown_inline` Tree-sitter
parsers, including injected highlighting for installed fenced-code languages,
plus wrapped, spellchecked Markdown buffers. The Markdown extra adds GFM-aware
rendering, link intelligence, link/document diagnostics and browser preview.
Catppuccin colours the in-editor rendered headings, code blocks, links and
tables.

The extra's global markdownlint-cli2 and markdown-toc integrations are
deliberately disabled. Their default style policy is too noisy for a common
profile and can overlap project formatting. Projects that require them should
declare and configure them locally; Conform already uses a project's local
Prettier when it is available.

Useful Markdown bindings:

```text
gd            follow an internal file or heading link through Marksman
Ctrl-o        return after following a link
gx            open the URL under the cursor
<leader>cp    toggle the live browser preview
<leader>um    toggle rendered Markdown inside Neovim

<leader>mt    insert a GFM table
Alt-l / Alt-h move to the next/previous table cell
<leader>mr    insert a table row below
<leader>mc    insert a table column to the right
```

The remaining row and column operations are discoverable under `<leader>m`
through WhichKey. Tables are real Markdown source and are aligned on leaving
insert mode; the browser preview remains the final check for GitHub rendering.

On Fedora and Parrot, the preview opens through the distro-owned `xdg-open`.
On Fedora WSL, the platform adapter routes both `gx` and preview URLs through
the existing `wsl-open` helper to the Windows browser even though Windows PATH
inheritance is disabled. macOS can use the preview plugin's native `open`
support without a common-config change.
