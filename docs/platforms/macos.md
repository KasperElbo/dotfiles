# Apple Silicon macOS workstation

This is the clean-machine path for the 16-inch MacBook Pro with M5 Pro. It
targets native `arm64`, the current macOS release, and the same keyboard-first
working model as the Fedora/Sway setup. It does not install Rosetta, disable
SIP, replace Gatekeeper, or commit machine-local identity and authentication.

The guide was checked against macOS Tahoe 26.6.2, Apple's current release on
2026-09-08. Check [Apple's release list](https://support.apple.com/en-us/100100)
and finish Software Update before a fresh installation.

Status labels in this guide mean:

- **Automated** — performed by the installer and safe to repeat.
- **Manual required** — GUI-, permission-, security-, or identity-dependent.
- **Optional** — installed only through an explicit flag or choice.

## 1. Fresh macOS and command-line prerequisites

1. **Manual required:** Complete Setup Assistant, install all macOS updates,
   and log in as the normal workstation user.
2. **Manual required:** Open Terminal and install Apple's Command Line Tools:

   ```bash
   xcode-select --install
   ```

   Finish the GUI installer before continuing. Homebrew requires the Command
   Line Tools. The dotfiles installer will stop if they are absent.
3. Clone the repository. The initial `git` command can also prompt for the
   Command Line Tools on a completely fresh Mac:

   ```bash
   mkdir -p ~/src
   git clone https://github.com/KasperElbo/dotfiles.git ~/src/dotfiles
   cd ~/src/dotfiles
   ```

## 2. Inspect and run the bootstrap

### System-Bash compatibility boundary

`install.sh` is deliberately a small Bash 3.2-compatible entry point. It reads
only `--platform` and `--rerun` (and, for a `--rerun` that names no platform,
the recorded platform from `install.conf`) while retaining the original
`"$@"` vector. For the macOS
profile it explicitly asks native Homebrew for the installed `bash` formula
prefix, then re-executes `scripts/install-main.sh` with Bash 4.4 or newer and
the original arguments. The real dispatcher keeps that interpreter when it
starts `platforms/macos/install.sh`; all capability, preflight, execution
plan, lifecycle-state, apply, and verification behavior remains on the modern
side of this boundary.

If native Homebrew or its Bash formula is absent, an applying run uses
Homebrew's supported installer and installs the `bash` formula before the
normal lifecycle can begin. This small, explicitly reported bootstrap mutation
cannot be represented as an ordinary execution-plan step because the plan
requires modern Bash. A bootstrap failure therefore writes no misleading
lifecycle success state. `--help` and `--dry-run` never perform this bootstrap
mutation; without modern Bash, dry-run reports the prerequisite bootstrap plan
and explains that rerunning it after the interpreter exists will show the full
resolved plan.

Apple's Bash 3.2 is supported only for `install.sh` and
`scripts/bootstrap-macos.sh`. The real installer and direct platform entry
point continue to require Bash 4.4 or newer.

**Automated:** Preview the exact plan without changing the machine:

```bash
./install.sh --platform macos --dry-run
```

Install the default profile:

```bash
./install.sh --platform macos
```

The installer:

1. refuses non-macOS, non-`arm64`, and Rosetta-translated shells;
2. installs native Homebrew at `/opt/homebrew` if needed;
3. installs the Homebrew-owned tools in `platforms/macos/Brewfile`, Ghostty,
   and AeroSpace;
4. reuses the common Zsh, Starship, Git, Ghostty, Neovim/LazyVim, tmux, fzf,
   bat, eza, ripgrep, fd, zoxide, mise, and Catppuccin packages through Stow;
5. installs the existing mise-owned .NET, Node/JS, Python, and portable CLI
   inventory;
6. sets a registered Zsh as the account login shell when the account does not
   already use one;
7. applies the small reversible defaults set below; and
8. launches AeroSpace and runs architecture/configuration verification.

Any Zsh listed in `/etc/shells` is supported, so Apple's `/bin/zsh` and a
deliberately selected Homebrew Zsh are both left alone. The shell is changed
only when the current one is not a registered Zsh, using `chsh` through `sudo`,
and the change is verified afterwards. Root invocations refuse to touch it. Open
a new terminal session after a change before expecting Zsh.

Homebrew's path is placed before Apple's system paths. The GNU coreutils
`gnubin` path is also added because the shared LazyVim bootstrap uses GNU
`timeout`. macOS's native `open`, `pbcopy`, and `pbpaste` remain the integration
surface; the profile adds no Linux-shaped wrappers.

For an unattended run after reviewing the plan:

```bash
./install.sh --platform macos --non-interactive
```

Use `--no-defaults` to deploy tools and configuration without changing macOS
preferences. Use `--dev-workflows` to also run the network-dependent
disposable .NET, Angular, Python and JSON workflows described below.
`--workflows`/`--no-workflows` are deprecated spellings that still resolve to
identical behaviour and warn.

## 3. Package ownership

Do not install a second copy through another manager.

| Owner | Responsibility |
|---|---|
| Apple / macOS | `/bin/zsh`, `open`, `pbcopy`, `pbpaste`, Keychain, SDK and compiler from Command Line Tools |
| Homebrew `/opt/homebrew` | Machine tools, Git/GitHub CLI, Neovim, tmux, mise, Starship, shell plugins, Ghostty, AeroSpace |
| mise | .NET 10, Node 24, Python 3.14, uv, Lazygit, EasyDotnet 3.4.25 and the existing portable developer CLIs |
| Mason / LazyVim | Editor-facing LSP, formatter, linter, test, and non-.NET debug adapters from the shared inventory; Roslyn remains Mason-owned |
| opam (optional) | OCaml compiler switch, Dune, OCaml LSP, formatter, utop, and Earlybird |
| Project | Project-specific npm/NuGet/Python dependencies and formatters |

`/usr/local/bin/brew` is treated as an accidental Intel Homebrew install and
fails verification. Do not install Rosetta to make an x86-only package work.
EasyDotnet's pinned companion tool bundles the native `osx-arm64`
`netcoredbg` that the C# DAP configuration launches. The macOS verifier
rejects a Mason-owned or `osx-x64` debugger path, while the CI probe records
legacy Intel behavior without installing Rosetta.

## 4. Development workflows

**Automated, optional validation:** Run all default workflow fixtures during
bootstrap:

```bash
./install.sh --platform macos --dev-workflows
```

Or run them separately:

```bash
./scripts/test-dev-workflows.sh --dotnet
./scripts/test-dev-workflows.sh --angular
./scripts/test-dev-workflows.sh --python
./scripts/test-dev-workflows.sh --json
```

`--latex` is deliberately absent from that list: this installer provisions no
TeX distribution on macOS. See "LaTeX is externally managed on macOS" below
before running it.

- .NET creates a console and xUnit project, then restores, builds, tests, and
  runs them. LazyVim uses Mason-owned Roslyn and EasyDotnet 3.4.25's bundled
  native `netcoredbg` setup; Mason's Intel-only `netcoredbg` package is not
  installed.
- Angular installs fixture-local npm dependencies, formats, lints, tests,
  builds development/debug bundles, checks source maps, serves, and probes the
  app. TypeScript/Angular editor and debugging configuration stays shared.
- Python resolves an isolated uv environment, runs, tests with pytest, lints,
  formats, and builds a wheel. LazyVim's shared Pyright/Ruff/debugpy setup is
  used; Python packages are not installed globally.

Interactive breakpoints and editor navigation still require a real Neovim UI:
open each fixture or a normal project, run `:checkhealth`, use definition and
references, and place one breakpoint. The automated fixture verifies the
underlying build/debug shapes but cannot assert a human editor interaction.

### LaTeX is externally managed on macOS

This installer does not own a TeX distribution on macOS, and `--latex` is not a
macOS installer flag — passing it fails with that message rather than silently
doing nothing. macOS bootstrap is not "LaTeX-complete": nothing here installs
`latexmk`, `pdflatex`, `biber`, or `latexindent`.

The editor configuration is kept anyway, as dormant compatibility
configuration. It does nothing until you install TeX yourself, and then the
same VimTeX/TexLab workflow documented in
[the LaTeX guide](../workflows/latex.md) works unchanged.

| Component | Owner on macOS | Provisioned by `install.sh`? |
| --- | --- | --- |
| TeX distribution, `latexmk`, `pdflatex`, `biber`, `latexindent` | You — MacTeX or BasicTeX, installed and updated outside this repository | No |
| `texlab` (LSP) | Mason, from the shared `nvim-lazyvim/.config/nvim/mason-packages.txt` inventory | Yes, as part of the base capability |
| VimTeX editor plugin | LazyVim, from the shared TeX extra | Yes, as part of the base capability |
| PDF viewer | macOS itself, through `open` | No — `platforms/macos/stow/nvim-macos` only points VimTeX at it |

`platforms/macos/stow/nvim-macos` exists because the shared VimTeX fallback
reaches only Okular or `xdg-open`, neither of which exists on macOS. It
overrides `vimtex_view_general_viewer` to `open` before that fallback runs, the
same pattern `platforms/fedora-wsl/stow/nvim-wsl` uses for `wsl-open`. `open`
has no SyncTeX forward-search support of its own, matching the trade-off
already accepted for Fedora WSL.

`config/capabilities.tsv` records this as `latex`/`macos` with the provider
`user-managed`, so the generated support matrix shows the absence and its owner
rather than implying parity with Fedora.

If you do install TeX yourself, the disposable smoke test works:

```bash
./scripts/test-dev-workflows.sh --latex
```

Without a TeX installation it reports `SKIP` and names the missing tools and
who owns them. It never reports a repository defect for a prerequisite this
platform was never asked to install.

### Optional OCaml

```bash
./install.sh --platform macos --ocaml
./scripts/test-dev-workflows.sh --ocaml
```

Homebrew owns only `opam` and native build prerequisites. The shared opam
installer creates the same pinned switch and editor workflow used on Fedora;
there is no second macOS OCaml environment.

The macOS verifier runs the same shared `common/verify-ocaml.sh` as every other
platform; there is no macOS-only OCaml check. It reads whether the profile was
selected from the install lifecycle state, so it does not need a forwarded flag
and reaches the same verdict whether it runs inside the installer or on its own
later:

- profile not selected and opam absent — pass, reported as not applicable;
- profile selected and healthy — pass;
- profile selected but missing or broken — fail.

On a selected profile it proves that `opam` resolves inside the Homebrew prefix
rather than merely answering on `PATH`, that the recorded switch exists and is
the selected one, that the compiler inside it matches
`~/.config/dotfiles/ocaml.conf` exactly (including an `OCAML_COMPILER_VERSION`
override), that dune, `ocamlearlybird`, `ocamllsp`, OCamlFormat, and utop are
installed in the switch, that opam's generated Zsh hook exists and parses, and
that a throwaway program compiles and runs. Every command runs through
`opam exec --switch`, so nothing here depends on restarting your login shell.

### Optional containers

```bash
./install.sh --platform macos --containers
```

macOS cannot run Linux containers directly, so this profile installs Podman
and `podman-compose`, creates the normal rootless Podman machine VM, and checks
an ARM64 Alpine container. It deliberately does not run Fedora's systemd,
SELinux, or subuid scripts and does not install Docker Desktop or a `docker`
alias. Podman's upstream macOS documentation prefers its signed installer over
Homebrew for supportability; this profile deliberately accepts the Homebrew
formula to keep machine-package ownership declarative. If that trade-off
causes a real stability issue, remove the formula and use the upstream
installer rather than keeping two copies.

Rollback:

```bash
podman machine stop
podman machine rm
brew uninstall podman-compose podman
rm ~/.config/dotfiles/macos-containers.conf
```

`podman machine rm` deletes that VM and its container/image/volume storage, so
export anything needed before running it.

### AI-assisted development toolchain

```bash
./install.sh --platform macos --ai
./install.sh --platform macos --ai --codex --firstmate
./install.sh --platform macos --ai --gnhf --backpass
```

macOS uses the shared `common/install-ai.sh` and `common/verify-ai.sh`. There
is no macOS-specific AI installer, and nothing here is installed through
Homebrew or a global npm prefix: the AI step runs after the mise environment is
active, and mise owns every command. The step is planned after `mise` for
exactly that reason.

`--ai` installs Claude Code and Herdr. The subcomponents are additive and
behave identically to every other platform: omitting `--codex` leaves an
already-installed Codex alone, and only `--no-codex` removes it, after a
confirmation and only when recorded provenance still proves this repository
installed it. See [the AI profile guide](../profiles/ai.md) for what
each component is and which ones need manual, deliberate setup afterwards.

| Component | Flag | Provider | Apple Silicon support |
| --- | --- | --- | --- |
| Claude Code | `--ai` | mise (npm backend) | supported |
| Herdr | `--ai` | mise (registry backend) | supported |
| Codex | `--codex` | mise (npm backend) | supported |
| FirstMate | `--firstmate` | git clone to `~/.local/share/firstmate` | supported |
| Treehouse | `--firstmate` | staged upstream install script | supported |
| No Mistakes | `--firstmate` | staged upstream install script | supported |
| gh-axi, chrome-devtools-axi, tasks-axi, quota-axi | `--firstmate` | mise (npm backend) | supported |
| lavish-axi | `--firstmate` or `--backpass` | mise (npm backend) | supported |
| GNHF | `--gnhf` | mise (npm backend) | supported |
| backpass, acpx | `--backpass` | mise (npm backend) | supported |

Support here means the component was installed and executed on a real Apple
Silicon runner by the `macos` job in `.github/workflows/real-install.yml`, not
that a mocked test passed. `config/capabilities.tsv` is the authority: if a
component is demoted to `unsupported` there, the macOS installer rejects that
one sub-flag with an actionable message and leaves the rest of the profile
installable. Losing one optional component never disables `--ai`.

macOS verification adds two checks the shared verifier cannot make: every
advertised command must be arm64-native or a script running under the arm64
Node runtime — an Intel-only binary that would need Rosetta fails — and none of
them may resolve to a Homebrew path or appear in a global npm prefix.

Where a component's binary ends up is the upstream installer's choice, and on
darwin/arm64 the two staged installers disagree: Treehouse writes its binary
to `~/.local/bin/treehouse`, while No Mistakes installs
`~/.no-mistakes/bin/no-mistakes` and leaves a launcher symlink at
`~/.local/bin/no-mistakes`. Both are accepted. What the installer requires is
that the command path resolves to a regular file you own, that executes; the
file it resolves to is what gets recorded with its digest, and what a later
`--no-firstmate` deletes, together with the launcher and the directory the
upstream created for it.

### Optional Tailscale

```bash
./install.sh --platform macos --tailscale
```

macOS installs Tailscale as the **Standalone**
macOS app (`brew install --cask tailscale-app`), the sandboxed
Network-Extension-based variant Tailscale documents for a normal Mac with a
display, not the headless `brew install tailscale` daemon formula this repo
does not use. There is no `launchd`/systemd-style service this profile
manages directly: the app's own Network Extension process is what
`tailscaled` is on Fedora, and macOS's sandboxing keeps it running once
approved. This deliberately does not reuse any Fedora `tailscaled`/systemd
assumption.

The installer opens the app once (so macOS can prompt for the Network
Extension permission) and then stops: authentication is interactive by
design, matching the cross-platform profile's boundary and this repository's existing
"no automated login" stance for every other identity/authentication step
(Git, SSH, `gh auth login`). Nothing here scripts the permission grant or
runs `tailscale up`/signs you in.

The Tailscale CLI is optional on macOS and is not installed by this
profile. Enable it yourself from the app's Settings (CLI section, "Install
Now"; asks for your admin password once) to get a plain `tailscale` command
at `/usr/local/bin/tailscale`, or use the app bundle path directly:

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale status
/Applications/Tailscale.app/Contents/MacOS/Tailscale version
```

Rollback:

```bash
tailscale logout   # or use the app's menu; only if you signed in
brew uninstall --cask tailscale-app
rm ~/.config/dotfiles/macos-tailscale.conf
```

See [the Tailscale profile guide](../profiles/tailscale.md) for package
ownership, the full list of what is intentionally never automated (ACLs,
exit nodes, subnet routes, Tailscale SSH, `--accept-routes`/`--accept-dns`),
and normal day-to-day commands. None of that is Fedora-specific; it applies
here unchanged.

## 5. AeroSpace decision record

The mandatory comparison was completed before implementation, and AeroSpace
was explicitly selected to minimize relearning between Sway and macOS.

| Concern | AeroSpace (selected) | yabai |
|---|---|---|
| Model | i3-like normalized tree; tiles and accordion | BSP tree around native windows |
| Workspaces | Fast emulated workspaces, independent of native Spaces | Normally drives native Spaces |
| Sway similarity | High: modes, directional tree navigation, named workspaces | Moderate: directional commands, but Space/BSP behavior differs |
| SIP | No SIP change | Basic features work with SIP; several advanced Space/window operations require a scripting addition and partially disabled SIP |
| Permissions | Accessibility | Accessibility; Screen Recording may be relevant for some integrations |
| Updates/maintenance | Public beta; simple TOML v2, active project | Mature and powerful, but private macOS APIs and scripting addition increase OS-update sensitivity |
| Rollback | Quit/uninstall; AeroSpace returns hidden windows on normal exit | Stop services, remove yabai/skhd and any scripting-addition/security changes |

AeroSpace gains deterministic i3-style workspaces, binding modes, and a close
match to Sway without weakening SIP. It gives up true native Spaces: Mission
Control represents hidden windows imperfectly, native full-screen creates a
separate Space, and a badly terminated process can leave a one-pixel edge of a
hidden window until it is recovered. It is also still explicitly a public
beta. yabai would gain deeper native Space control and mature BSP automation,
but the most capable configuration carries more security and macOS-update
coupling than this workstation accepts.

The Homebrew AeroSpace cask is the upstream-preferred install path, but the app
is not notarized; the cask removes its quarantine attribute. Review the
[AeroSpace repository](https://github.com/nikitabobko/AeroSpace) and release
before upgrades. SIP and Gatekeeper remain enabled system-wide.

## 6. AeroSpace permissions and keyboard model

**Manual required:** On first launch, open **System Settings → Privacy &
Security → Accessibility** and enable AeroSpace. Do not grant Full Disk Access
or Screen Recording; this profile does not need them. AeroSpace starts at login
from its own tracked setting.

The Mac modifier is `Control+Option`. This preserves normal Command shortcuts
and plain Option symbol/Danish character entry while still feeling like one
dedicated Sway modifier.

| Sway concept | macOS binding | Action |
|---|---|---|
| `Super+Enter` | `Control+Option+Enter` | Open a new Ghostty window |
| launcher | `Command+Space` | Open native Spotlight |
| `Super+1…9` | `Control+Option+1…9` | Switch AeroSpace workspace |
| `Super+Shift+1…9` | `Control+Option+Shift+1…9` | Move window to workspace |
| `Super+h/j/k/l` | `Control+Option+h/j/k/l` | Focus directionally, including adjacent display |
| `Super+Shift+h/j/k/l` | `Control+Option+Shift+h/j/k/l` | Reorder/move directionally, including adjacent display |
| 3×3 workspace grid | `Control+Option+Command+h/j/k/l` | Move through 1–9 with wrapped grid navigation |
| `Super+b/v` | `Control+Option+b/v` | Horizontal/vertical tiles |
| `Super+s/w` | `Control+Option+s/w` | Vertical/horizontal accordion (stacked/tabbed analogue) |
| `Super+Shift+Space` | `Control+Option+Shift+Space` | Toggle floating/tiling |
| `Super+f` | `Control+Option+f` | AeroSpace full-screen within the current macOS Space |
| `Super+Shift+c` | `Control+Option+Shift+c` | Close window |
| `Super+r` | `Control+Option+r`, then `h/j/k/l` | Enter resize mode; Enter/Escape exits |
| display focus | `Control+Option+Tab` | Focus next display |
| move window | `Control+Option+Shift+Tab` | Move window to next display |
| move workspace | `Control+Option+Command+Tab` | Move workspace to next display |

This table is the canonical macOS input for the cross-platform keybinding
documentation.

The configuration intentionally has no hardcoded monitor serial, name, or
workspace assignment. Workspaces form one pool; each has an assigned display,
and different displays show different workspaces. Moving an empty workspace to
a display once establishes its normal ownership until topology changes.

### Multi-monitor and Mission Control

**Manual required:** In **System Settings → Displays → Arrange**, arrange
displays so each one has a free lower-left or lower-right corner. AeroSpace
hides inactive workspace windows just beyond those corners; an overlapping
arrangement can expose slivers on another display.

**Recommended manual choice:** In **System Settings → Desktop & Dock → Mission
Control**, disable **Displays have separate Spaces**, then log out and back in.
This is AeroSpace upstream's more stable focus/performance path. The trade-off
is that macOS native full-screen on one display blacks out the other display;
use AeroSpace `Control+Option+f` instead. If independent native full-screen is
more important, leave the setting enabled and accept possible cross-display
focus issues.

Keep one native macOS Space per display and use AeroSpace workspaces 1–9.
Attach/detach monitors, then use the three display bindings above to place
windows/workspaces; the config does not assume a desk topology. Mission Control
can render hidden AeroSpace windows too small. Optionally enable **Group windows
by application** in Desktop & Dock if that is useful; it is deliberately not
scripted.

## 7. Deliberate macOS defaults

**Automated:** The default install applies only these stable settings:

| Setting | Managed value and purpose | Rollback |
|---|---|---|
| Dock | bottom, 40 px, auto-hide, no recent-app section | Delete managed Dock keys |
| Workspace ordering | disable automatic recent-use reordering | Delete `mru-spaces` |
| Finder | extensions and hidden files visible; path/status bars shown | Delete managed Finder/global keys |
| Screenshots | PNG in `~/Pictures/Screenshots` | Delete screenshot keys |
| Keyboard | repeat `2`, initial delay `15` | Delete repeat keys |

Run the complete rollback, which deletes only keys owned by the script and
allows macOS defaults to take over again:

```bash
platforms/macos/scripts/apply-defaults.sh --restore
```

Preview either operation with `--dry-run`. The rollback does not reconstruct a
custom value that predated this repository; it returns the key to system
default ownership.

**Manual required:** Review these subjective or GUI-sensitive settings without
automation:

- Desktop & Dock: menu-bar contents, desktop icons, hot corners, Dock animation,
  Stage Manager, and **Group windows by application**.
- Keyboard: function keys versus media keys and keyboard navigation/focus.
- Trackpad: natural scrolling, gestures, tracking speed, tap-to-click.
- Displays: scaling, refresh rate, HDR, main display, and physical arrangement.
- Privacy & Security: FileVault, Touch ID for password/sudo approval as desired,
  application permissions, and software-update policy.

No undocumented preference key is used for these choices.

## 8. Identity, authentication, and native integration

**Manual required:** Keep values and credentials outside Git:

```bash
$EDITOR ~/.config/git/local
$EDITOR ~/.config/git/drdk  # only for a separate work identity
gh auth login
```

Configure an OpenSSH or 1Password SSH agent and Git signing only on the machine.
Do not commit keys, agent sockets, tokens, cookies, or AI sessions.

Validate native integration interactively:

```bash
printf 'clipboard-check' | pbcopy
pbpaste
open https://github.com
open README.md
gh auth status
gh repo view --web
```

The first two should round-trip text, the two `open` commands should use the
default browser/application, and `gh repo view --web` should use the browser
after authentication. These actions are manual because an installer should not
overwrite the clipboard or launch arbitrary UI during verification.

### SFTP client

Command-line SFTP needs no Homebrew package: `ssh`, `scp`, and `sftp` are part
of Apple's own OpenSSH build under `/usr/bin`, present on every clean macOS
install.

```bash
sftp user@host
```

Common interactive commands (`ls`, `cd`, `lcd`, `pwd`, `lpwd`, `get`, `put`,
`mget`, `mput`, `mkdir`, `rm`, `exit`) and non-interactive `scp` transfers work
exactly as documented in
[the first-run SFTP section](../workflows/first-run.md#6-sftp-client). Authentication reuses `~/.ssh/config`,
SSH keys, ssh-agent (including a 1Password-backed agent), and password
authentication when a server requires it.

Finder has no built-in `sftp://` location support (unlike Dolphin/KIO on the
Fedora KDE profile), but no dedicated GUI SFTP client is installed here
either: the CLI `sftp`/`scp` workflow above is the supported path, and adding
a GUI client such as FileZilla for this alone was not judged a large enough
gap to justify a second application.

Verify with:

```bash
command -v sftp
command -v scp
ssh -V
```

### Reapplying this machine's configuration

```bash
./install.sh --rerun --dry-run
./install.sh --rerun
```

`--rerun` reapplies the configuration of this machine's last *successful*
install, reconstructed from the lifecycle state by the shared persistent
selection model — including the theme, `--defaults`, the optional profiles,
and the AI subcomponents, whose additive semantics survive the round trip: a
sub-flag you omitted stays omitted rather than becoming an install or a
removal. See [the rerun guide](../workflows/rerun.md) for
the full contract. A run that *fails* has no remembered configuration to
reapply, so it prints the literal command that reproduces the selection it was
attempting.

## 9. Verification and rollback

```bash
platforms/macos/scripts/verify.sh --defaults
./scripts/lint.sh
./scripts/test.sh
git diff --check
```

Add `--containers` and/or `--tailscale` to verification when those optional
profiles are installed. The verifier checks arm64, `/opt/homebrew`, the
absence of Intel Homebrew, SIP, Gatekeeper, shared/macOS Stow links,
tools/runtimes, apps, defaults, the Podman machine, and Tailscale (app
presence, CLI version, and connection state via `tailscale status --json`)
when selected. An ungranted AeroSpace Accessibility permission and a
not-yet-installed Tailscale CLI are both reported as warnings with their
manual remedy, not hard failures, since both are optional interactive steps.

To remove only the Mac desktop layer while leaving common dotfiles intact:

```bash
pkill AeroSpace || true
brew uninstall --cask nikitabobko/tap/aerospace ghostty
stow --dir=platforms/macos/stow --target="$HOME" --delete aerospace zsh-platform nvim-macos
platforms/macos/scripts/apply-defaults.sh --restore
```

To remove all Homebrew packages declared here, inspect before executing:

```bash
brew bundle cleanup --file=platforms/macos/Brewfile
```

That cleanup can remove packages used outside this repository; do not run it
without reviewing Homebrew's proposed changes. Removing Stow links never
removes local Git identity/authentication files.

## Upstream references

- [Homebrew installation](https://docs.brew.sh/Installation)
- [Ghostty macOS installation](https://ghostty.org/docs/install/binary)
- [AeroSpace guide](https://nikitabobko.github.io/AeroSpace/guide)
- [AeroSpace commands](https://nikitabobko.github.io/AeroSpace/commands)
- [Podman macOS installation](https://podman.io/docs/installation)
- [Podman machine](https://docs.podman.io/en/latest/markdown/podman-machine-init.1.html)
- [Tailscale on macOS: the three variants](https://tailscale.com/docs/concepts/macos-variants)
- [Tailscale CLI reference](https://tailscale.com/docs/reference/tailscale-cli)
