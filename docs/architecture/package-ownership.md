# Package ownership

Avoid installing the same tool through multiple package managers.

Package ownership answers *which tool installs what*. The companion question
— *where does it come from, how strongly is it pinned, and what happens when
that download fails* — is answered by
[docs/supply-chain.md](../supply-chain.md) and the machine-readable
registry in [`config/network-sources.tsv`](../../config/network-sources.tsv). That
document is also where this repository states plainly what it does and does
not claim: configuration reproducibility plus declared exact/rolling source
tiers, not bit-for-bit machine reproduction. `./scripts/lint.sh` fails if a
new download, remote script, Git clone, or validation image appears without
a registry entry.

## macOS / Homebrew

The Apple Silicon profile uses Homebrew only at `/opt/homebrew` for native
machine tools, shell plugins, Ghostty, and AeroSpace. mise continues to own the
portable language runtimes and CLIs. OCaml remains split between a
Homebrew-owned `opam` binary/build prerequisites and an opam-owned compiler
switch. The exact inventory and duplicate-architecture policy are documented
in the [macOS package-ownership table](../platforms/macos.md#3-package-ownership).

## Fedora / DNF

Machine-level and OS-integrated tools:

```text
bat
curl
eza
fd
fzf
gh
git
git-delta
libicu
neovim
openssh-clients
ripgrep
ShellCheck
sqlite
sqlite-devel
stow
tmux
wl-clipboard
zoxide
zsh
zsh-autosuggestions
zsh-syntax-highlighting
```

The optional Sway session adds Sway, Waybar, Fuzzel, Mako, swaylock,
swayidle, swaybg, desktop portals, a polkit agent, clipboard and screenshot
utilities, hardware-key utilities, and the small GUI control tools used by the
bar. It includes Fedora's `sway-systemd` integration so the Sway session
activates the graphical-session lifecycle required by desktop portals. It also
runs standard XDG autostart entries through `dex-autostart`, so
application preferences such as 1Password's **Start at Login** work in Sway as
they do in KDE. Waybar provides the StatusNotifier tray required by background
applications, while GTK handles general desktop portals and the wlroots backend
handles screenshots and screen sharing. These packages remain Fedora/DNF-owned.

The optional OCaml profile adds the `opam` binary plus `bzip2`,`gcc`, `gcc-c++`, `make`,
`m4`, `patch`, `pkgconf-pkg-config`, `unzip`, and `bubblewrap`. These are native
package/build prerequisites only; DNF does not own the selected OCaml compiler
or the OCaml Platform tools.

The optional desktop-tools profile adds `gimp`, `pdfarranger`, `skanpage`, and
`xdg-utils`. It reuses the Fedora KDE baseline's Gwenview, Okular, and Ark
instead of installing alternatives, installing one only if it is genuinely
missing. See [Optional desktop-tools profile](../profiles/desktop-tools.md#optional-desktop-tools-profile).

The optional containers profile adds `podman` and `podman-compose`. It
deliberately does not add Buildah, Skopeo, Docker Engine, or a `docker`
alias. See [Optional Podman container development
profile](../profiles/containers.md#optional-podman-container-development-profile).

The optional Tailscale profile adds `tailscale` (the CLI and `tailscaled`)
from Tailscale's own DNF repository, not Fedora's. See [Optional Tailscale
networking profile](../profiles/tailscale.md#optional-tailscale-networking-profile) and "Tailscale
package repository" below.

## Terra RPM repository

The reference setup uses Terra packages for:

```text
ghostty
mise
starship
```

These remain RPM-owned. mise itself is **not** installed by mise.

Terra's own documentation bootstraps the repository with `--nogpgcheck`,
because the signing key ships inside the `terra-release` package it is about
to install. This repository does not do that. Terra also publishes the
per-release key at `https://repos.fyralabs.com/terra<releasever>/key.asc`, so
the installer fetches that key first, refuses to import it unless its
fingerprint matches the value pinned for that Fedora release in
[`config/terra-keys.tsv`](../../config/terra-keys.tsv), and only then installs
`terra-release` with GPG checking enabled.

A Fedora release newer than the pinned set is the one remaining trust
boundary: there is nothing to compare the key against, so the installer
prints the downloaded fingerprint and stops unless you acknowledge it
interactively or pass `TERRA_TRUST_KEY_FINGERPRINT=<fingerprint>`. Adding the
release to `config/terra-keys.tsv` is the permanent fix. See
[docs/supply-chain.md](../supply-chain.md).

## Tailscale package repository

The optional `--tailscale` profile enables Tailscale's own DNF repository
(`pkgs.tailscale.com/stable/fedora`), added via dnf5's `config-manager
addrepo`, and installs only `tailscale` from it. This is Tailscale's
currently supported Fedora installation path, the same one its own install
script uses, rather than a standalone downloaded binary. See [Optional
Tailscale networking profile](../profiles/tailscale.md#optional-tailscale-networking-profile).

## RPM Fusion repositories

The optional desktop-tools profile enables RPM Fusion's free and nonfree
repositories, reusing the same `ensure_rpm_fusion_repositories` helper the
ASUS hardware profile already uses for firmware packages, and installs `mpv`
from there. This is the standard Fedora community path to full multimedia
codec support and remains RPM/DNF-owned; no other profile depends on it.

## Parrot / APT

The `parrot-ctf` profile installs only shell/editor/Python prerequisites and
`qemu-guest-agent`/`spice-vdagent`. Parrot Security Edition's existing security
packages and repositories remain untouched and APT-owned. Debian's `batcat`
and `fdfind` command names are exposed as `bat` and `fd` through two small
Parrot-only wrappers. `x-copy` is a guest-only alias backed by APT-owned
`xclip`. Starship is APT-owned; the unused `AOSC` symbol is omitted so its
1.22.1 parser accepts the shared config. mise is installed in `~/.local/bin`
from its upstream installer and owns only `uv` plus pinned Neovim 0.12.5. The
Neovim exception exists because Parrot 7.3's 0.10.x package is below the
tracked LazyVim minimum; system Python and security tools remain APT-owned.

## mise

The tracked configuration is:

```text
~/.config/mise/config.toml
```

The current user-level developer toolset includes:

```text
dotnet
node
python
uv

lazygit
ast-grep
tree-sitter

dotnet:EasyDotnet
npm:@mermaid-js/mermaid-cli
npm:neovim
pipx:pynvim
```

`mise install` installs what is declared in the tracked config; the install script does not duplicate the tool list.

Every mise invocation the installers and verifiers make runs from an empty,
repository-owned context directory under
`$XDG_STATE_HOME/dotfiles/mise-context`, with `MISE_CEILING_PATHS` set to
that same directory. mise otherwise composes its configuration from the
global config *and* every `mise.toml`/`.mise.toml` between the working
directory and the filesystem root, so running `./install.sh` from inside an
unrelated project would otherwise install that project's tools during a
global bootstrap. The global config and its `conf.d` fragments still apply —
that is the manifest a global bootstrap is meant to install — and
`MISE_DATA_DIR`/shim behaviour is unchanged. `--dry-run` and verbose output
print which logical config is in play.

## AI agent tooling

Optional; installed only by `--ai` (see "AI-assisted development toolchain"
above for daily usage). Declared in a separate, **untracked**, machine-local
mise config file so the tracked `~/.config/mise/config.toml` above never
gains an AI-related dependency:

```text
~/.config/mise/conf.d/ai.toml
```

| Component | Owner |
|---|---|
| Claude Code | mise, `npm:@anthropic-ai/claude-code` |
| Codex CLI (optional) | mise, `npm:@openai/codex` |
| Herdr | mise, registry entry `herdr` |
| GNHF (optional, requires `--gnhf`) | mise, `npm:gnhf` |
| backpass, acpx (optional, requires `--backpass`) | mise, `npm:backpass`, `npm:acpx` |
| FirstMate (optional, requires `--firstmate`) | `git clone`/`git pull --ff-only`, no package manager upstream |
| Treehouse (optional, requires `--firstmate`) | own install script to `~/.local/bin/treehouse`, no mise registry entry or OS package |
| No Mistakes (optional, requires `--firstmate`) | own install script to `~/.local/bin/no-mistakes`, no mise registry entry or OS package |
| gh-axi, chrome-devtools-axi, tasks-axi, quota-axi (optional, require `--firstmate`) | mise, `npm:<name>` each |
| lavish-axi (optional, requires `--firstmate` and/or `--backpass`) | mise, `npm:lavish-axi` (declared once regardless of which flag(s) select it) |

Each tool is installed through exactly one mechanism above; this repository
does not additionally install any of them through Homebrew, a global `npm
install -g`, or a native/OS-package installer, so there is never a duplicate,
competing copy on `PATH`. `verify-ai.sh` checks this by confirming each
mise-managed command resolves to the same binary mise itself reports
managing, and that Treehouse resolves to the copy this profile installed.

## opam

The optional OCaml profile deliberately uses the ecosystem's switch model:

| Component | Owner |
|---|---|
| `opam` binary and native build prerequisites | Fedora/DNF |
| OCaml compiler and versioned switch | opam |
| `dune`, `utop`, `ocaml-lsp-server`, `ocamlformat`, `earlybird` | opam, in the same switch as the compiler |
| OCaml Treesitter parser | `nvim-treesitter`, only when opam is present |
| Project libraries and test dependencies | The project's opam switch and `.opam` files |

Neither mise nor Mason installs OCaml, dune, OCaml LSP, OCamlFormat, or utop.
Keeping the compiler and editor tools together avoids the version mismatch that
can occur when Mason installs `ocaml-lsp-server` independently of an opam
switch.

## Mason

Mason owns the editor-facing binaries below. This is the complete expected
inventory, derived from the tracked LazyVim extras and local plugin specs. The
canonical package names live in `nvim-lazyvim/.config/nvim/mason-packages.txt`:

| Mason package | Declared by | Responsibility |
|---|---|---|
| `angular-language-server` | LazyVim Angular extra | Angular template and framework language support |
| `debugpy` | LazyVim Python extra | Python debug adapter used by `nvim-dap-python` |
| `eslint-lsp` | LazyVim ESLint extra | Editor-to-project ESLint bridge |
| `js-debug-adapter` | LazyVim TypeScript extra when DAP is enabled | JavaScript and TypeScript debugging |
| `json-lsp` | LazyVim JSON extra | JSON language support |
| `lua-language-server` | LazyVim core | Lua language support for Neovim configuration |
| `marksman` | LazyVim Markdown extra | Markdown links, references and document navigation |
| `prettier` | LazyVim Prettier extra | Editor-owned formatter for JSON, JSONC, YAML, Markdown and the web filetypes |
| `pyright` | LazyVim Python extra | Python language server and type checking |
| `roslyn` | `lua/plugins/dotnet.lua` | C# language server used by `roslyn.nvim` |
| `ruff` | LazyVim Python extra | Editor diagnostics and formatting using project configuration |
| `shfmt` | LazyVim core | Editor formatting for shell files |
| `stylua` | LazyVim core | Editor formatting for Lua files |
| `texlab` | LazyVim TeX extra | TeX language support |
| `vtsls` | LazyVim TypeScript extra, imported by Angular | TypeScript language server using the workspace TypeScript SDK |
| `yaml-language-server` | LazyVim YAML extra | YAML language support |

The .NET debugger is deliberately not in this inventory. EasyDotnet 3.4.25
bundles the official `netcoredbg` builds for each supported runtime platform,
including native `osx-arm64`, and its project-aware DAP integration launches
that bundled binary. Keeping Mason's `netcoredbg` out prevents the registry's
Intel-only macOS asset from shadowing the native Apple Silicon provider.

The installer first restores the locked lazy.nvim plugin set and then runs a
blocking, time-limited `:MasonInstall` for any missing packages. This avoids
depending on language-specific plugins and filetypes loading during an
interactive first launch. Mason's normal `ensure_installed` configuration uses
the same inventory, so later interactive starts retain the expected behavior.
`platforms/fedora/scripts/verify.sh` fails when an intended package is missing and warns about
additional Mason packages so stale or manually installed tools can be reviewed
instead of silently acquiring a second owner.

### Pinned Mason versions

Packages normally track whatever version their registry advertises.
`common/mason-package-versions.txt` records the exceptions as
`<package> <version>` lines, and the installer requests those packages as
`package@version` instead. Pins that name a package outside the profile being
installed are ignored, so one file serves every Neovim profile.

`roslyn` is pinned. It is served by the third-party
`github:Crashdummyy/mason-registry`, whose daily release points at the matching
`roslynLanguageServer` release. That upstream release is created before its
per-platform archives are uploaded, so the registry can advertise a version
whose downloads return 404 on every platform and fail a real installation. Bump
the pin after confirming the newer release actually carries its platform
archives.

## Project-local tooling

Project formatters, linters, compilers, and repository-specific CLIs should remain project-owned.

Examples:

### .NET repository

```text
CSharpier
dotnet-ef
```

These belong in `.config/dotnet-tools.json`.

### Angular / TypeScript repository

```text
Prettier
ESLint
angular-eslint
typescript-eslint
TypeScript
Karma / other project test runner
```

These belong in `package.json`.

### Python repository

```text
pytest
Ruff
application and library dependencies
```

These belong in `pyproject.toml` and are resolved into a project-local `.venv`
with `uv`. Mason's Ruff installation is editor-only; CLI and CI execution uses
the project-declared version.

### OCaml repository

Application libraries and test dependencies belong in the project's `.opam`
files, with build structure in `dune-project` and `dune` files. opam resolves
them into the selected switch; the workstation profile supplies only the
compiler and common development tools.
