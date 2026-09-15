# LaTeX

LaTeX support is optional, and `--latex` is a Fedora and Fedora WSL flag only:

```bash
# Native Fedora
./install.sh --latex

# Fedora WSL
./install.sh --platform fedora-wsl --latex
```

or:

```bash
./platforms/fedora/scripts/install-latex.sh
```

Fedora owns the TeX distribution and Biber.

Mason owns `texlab`.

LazyVim owns the VimTeX editor plugin. TeX project build configuration remains
in the project.

On macOS the TeX distribution is externally managed: this repository installs
no TeX, `--latex` is rejected by the macOS installer rather than silently
ignored, and `config/capabilities.tsv` records the `latex`/`macos` provider as
`user-managed`. Mason still owns `texlab` there, and
`platforms/macos/stow/nvim-macos` still points VimTeX at macOS's `open`, so the
editor workflow below becomes live as soon as you install MacTeX or BasicTeX
yourself. See [docs/platforms/macos.md](../platforms/macos.md#latex-is-externally-managed-on-macos)
for the full ownership table. The Parrot CTF profile has no LaTeX support at
all.

The optional component explicitly installs `latexmk`, `latexindent`, BibLaTeX,
and Biber alongside the medium TeX Live scheme. It does not install any LaTeX
binaries when `--latex` is omitted.

## LaTeX editing workflow

Open either the main file or an included `.tex` file in LazyVim. VimTeX owns
project discovery, compilation, PDF viewing, and parsed build errors; TexLab
owns completion, navigation, document symbols, diagnostics, and formatting.
TexLab's build-on-save and ChkTeX integrations are disabled so they do not
duplicate VimTeX's build log or introduce a second diagnostic stream.

The high-value bindings below use LazyVim's local leader, `\`. They are also
shown by which-key after pressing `\l`.

| Binding | Command | Purpose |
| --- | --- | --- |
| `\ll` | `:VimtexCompile` | Start or stop continuous `latexmk` compilation |
| `\lv` | `:VimtexView` | Open the PDF and forward-search to the cursor |
| `\le` | `:VimtexErrors` | Toggle parsed LaTeX/Biber errors in quickfix |
| `\lo` | `:VimtexCompileOutput` | Inspect raw compiler output |
| `\lt` | `:VimtexTocOpen` | Open navigable document structure |
| `\li` | `:VimtexInfo` | Show the detected main file, compiler, and viewer |
| `<leader>cf` | LazyVim format | Format through TexLab and Fedora's `latexindent` |

`\ll` starts VimTeX's default continuous `latexmk` mode. Save any related
source or bibliography file to rebuild; press `\ll` again to stop it.
Warnings remain available through `\le`, but only errors open quickfix
automatically. Use `]q` and `[q` to move between quickfix entries without
leaving Neovim.

TexLab supplies completion and go-to-definition for commands, labels,
references, and citations. LazyVim's normal LSP bindings apply, including
`gd`, `gr`, and `<leader>ss` for document symbols. Its formatter calls the
DNF-owned `latexindent`; a repository's `.latexindent.yaml` is discovered by
`latexindent --local` and remains project-owned. LazyVim's format-on-save
setting applies, with `<leader>cf` available for an explicit format.

`latexmk` detects BibLaTeX and runs Biber as required. A normal bibliography
setup therefore only needs project-local configuration such as:

```tex
\usepackage[backend=biber]{biblatex}
\addbibresource{references.bib}
```

VimTeX usually finds a multi-file document's main file by following
`\input`/`\include`. For an unambiguous project, add this near the top of
each included file:

```tex
% !TeX root = ../main.tex
```

An empty `main.tex.latexmain` marker or a project `.latexmkrc` containing
`@default_files = ('main.tex');` are supported alternatives. Run `\li` to
confirm which root VimTeX selected after opening a file.

On the Fedora KDE baseline, `\lv` uses the already-installed Okular and
supports forward SyncTeX. For inverse SyncTeX, set **Settings > Configure
Okular > Editor > Custom Text Editor** to:

```text
nvim --headless -c "VimtexInverseSearch %l '%f'"
```

Then Shift-click the PDF in Okular's browse mode. VimTeX is deliberately
loaded at startup so this callback can locate the correct running Neovim
instance. If Okular is unavailable (for example, on a non-KDE installation),
`\lv` uses `xdg-open`; PDF viewing still works through the desktop default,
but viewer-specific forward/inverse SyncTeX is not promised. The LaTeX option
does not install another PDF application for that fallback case.

On Fedora WSL, `--latex` installs the same DNF-owned toolchain but does not add
a Linux desktop PDF application. Its platform-specific Neovim adapter
overrides VimTeX's viewer with `wsl-open`, so `\lv` opens the generated PDF in
its Windows handler without putting Windows launch logic in the shared editor
configuration. That Windows-handler fallback does not currently provide
forward or inverse SyncTeX. Verify the optional WSL toolchain separately with
`platforms/fedora-wsl/scripts/verify.sh --latex`; combining `--latex` with the
installer's `--dev-workflows` also runs the disposable multi-file build below.

On macOS, `platforms/macos/stow/nvim-macos` overrides the viewer with macOS's
own `open` for the same reason, and `open` likewise provides no SyncTeX of its
own. Because no TeX is installed there by this repository, `--dev-workflows`
never runs the LaTeX build on macOS; run it explicitly once you have installed
a TeX distribution.

The LazyVim TeX extra installs the LaTeX and BibTeX Tree-sitter parsers. It
intentionally leaves LaTeX highlighting to VimTeX's more complete syntax
engine, while BibTeX uses Tree-sitter. Both use the active Catppuccin palette,
as do LazyVim diagnostics, completion, symbols, and quickfix UI.

For discovery and troubleshooting, use `\li`, `:checkhealth vimtex`,
`:LspInfo`, `:ConformInfo`, or `:Mason`. The repeatable machine-level smoke
test is:

```bash
./scripts/test-dev-workflows.sh --latex
```

On native Fedora, `platforms/fedora/scripts/verify.sh` also checks the toolchain
itself: when the recorded installation selected `latex` it requires `biber`,
`latex`, `latexindent`, `latexmk`, `lualatex`, `pdflatex`, and `xelatex`, and
when it did not it reports the toolchain as not applicable and warns if
`latexmk` is installed anyway.

Where a platform's installer owns TeX and the `latex` capability is recorded as
installed, a missing `latexmk`, `pdflatex`, `biber`, or `latexindent` is a
broken installation and the workflow FAILs. Where TeX is externally managed, as
on macOS, the same absence is expected: the workflow SKIPs and names both the
missing tools and who owns them.

It formats and builds a disposable multi-file document, resolves a BibLaTeX
citation through Biber, verifies the PDF, then introduces a deliberate compile
error and checks that the log contains a quickfix-compatible file and line.

Mermaid CLI (`mmdc`) is installed through mise/npm.

Perl and Ruby are not separately managed through mise merely because TeX utilities use them.
