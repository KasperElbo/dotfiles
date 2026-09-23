# Troubleshooting

## Start with `./doctor`

```bash
./doctor
```

`./doctor` is read-only, takes no options, and is the first thing to run when
something looks wrong. It reports what this checkout believes was installed,
whether the checkout still matches the installed revision, whether each
selected capability's machine-local state is intact and still owned by the
current selection, whether a configuration is available for `./install.sh
--rerun`, and which verifier proves each installed capability.

Its exit status is the contract: **failures exit `1`, warnings exit `0`**. A
warning is information (a revision that has moved on, residual state from a
capability no longer selected, legacy unversioned state); a failure means the
recorded state disagrees with what an installed machine should look like.

`./install.sh doctor` and `./install.sh --platform <name> doctor` run the same
report; `doctor` is a subcommand, not a platform option, and none of these
spellings installs anything. On macOS they work even when `bash` on your PATH
is Apple's 3.2: the report selects a supported Bash for itself, and says so
plainly if the machine has none (see
[the macOS compatibility boundary](platforms/macos.md#system-bash-compatibility-boundary)).

`./doctor` names the verifier to run next — see
[verification](workflows/verification.md) for what those verifiers prove, and
the entry below that matches the message you got.

### `doctor` is a Linux and macOS command

There is deliberately no Windows `doctor`, and adding one is not pending work.
`./doctor` reports the *lifecycle* state of an `./install.sh` run — the
installation record, the component state files, and the configuration
`./install.sh --rerun` would reapply. The Windows host has none of those: it is
installed by `platforms\windows\install.ps1`, which records one selection file
instead of a lifecycle, and that file is read by a verifier rather than by a
rerun. The equivalent on Windows is therefore the verifier itself, which is
read-only and reports the same way:

```powershell
.\verify.ps1
```

See the [Windows host guide](platforms/windows.md#verify) for what it proves.
Inside Fedora on WSL, `./doctor` is the Linux command it always was.

## The installer refuses to start

Preflight runs before anything is changed, and refuses rather than half-installing:

```text
Missing bootstrap-prerequisite command: xcode-select (provider: macos)
Missing bootstrap-prerequisite command: sudo (provider: sudo)
Missing supported-base command: awk (provider: gawk)
Path is not writable: /home/you/.config
XDG_CONFIG_HOME is /srv/config, but this repository deploys to /home/you/.config.
Not enough free disk space for /home/you/.local/share: 812 MiB available, 3072 MiB required
Cannot reach github.com, which this installation downloads from: Catppuccin tmux theme, Mason registry
Nothing has been changed. Restore network access, or rerun without the steps that need it.
```

An `XDG_CONFIG_HOME` or `XDG_DATA_HOME` refusal is a contract, not a missing
prerequisite: Stow deploys into `$HOME`, so a configuration root anywhere else
would leave every link where nothing later reads it (see
[the Stow layout](architecture/file-ownership.md#gnu-stow-layout)). Unset the
variable, or set it to the path the message names, and rerun. `XDG_STATE_HOME`
is not restricted.

Install the named command — the message names the package that provides it —
or fix the ownership of the named path, then rerun. `bootstrap-prerequisite`
is something the installer needs before it can install anything at all;
`supported-base` is a command the finished environment is defined to have.
Both come from `config/command-providers.tsv`. The installer making no
changes at all is the intended outcome here, not a failure to recover from.

The disk figures are floors for "certainly not enough" -- one package-manager
transaction, and the mise runtimes, Mason inventory and LazyVim plugins under
`XDG_DATA_HOME` -- not an estimate of a full installation. The message names
the path that was measured: the system figure is taken on the filesystem the
platform's package manager writes to (`/var/cache/dnf` on Fedora,
`/var/cache/apt` on Parrot, `/opt/homebrew` on macOS), so a machine with a
separate `/var` is checked where the transaction actually lands. Free space on
the named path, then rerun.

The reachability check is connect-level and covers the hosts the resolved plan
will actually download from, every one of them, named in a single refusal
rather than one per rerun. The set is derived rather than listed: each step
declares the repository scripts it runs, `config/network-sources.tsv` says
which sources each script downloads, and the preflight probes one host per
matching source. So a run is told in seconds what it cannot reach, instead of
failing partway through the first mutating step — including the
package-manager transaction, which is both the largest download and the first
thing to change the machine.

A step that is not in your plan contributes nothing, so a machine whose plan
needs nothing from the network still installs offline. The probe uses the same
proxy settings as the download itself, so a proxy that works for `curl` works
here.

`scripts/validate-plan-network.py` keeps the derivation honest: it fails the
build when a step's declaration does not match the scripts it runs, or when a
script can reach a source whose registry row does not name it. A step cannot
be added that downloads from a host nothing probes.

## Stow conflicts

```text
Stow conflict [zsh]: existing file or directory: /home/you/.zshrc
1 Stow conflict(s) found. Move or back up these paths; --adopt is never automatic.
```

Preflight found something already at a path this repository would link. The
variants name the cause: an existing real file or directory, a `dangling
link`, a `link to another package in this checkout`, a `link owned by another
checkout or source`, or a parent path that `is not a real directory`.

The check runs whichever entry point you used. A platform installer preflights
every package it plans to deploy, and `common/stow.sh` and each
`platforms/<platform>/scripts/stow.sh` check their own packages before linking
anything, adding `Refusing to stow; nothing in $HOME was changed.` A conflict
therefore never leaves a partly linked `$HOME` behind, whether you ran the
installer or a Stow script directly.

The remedy is always the same — move the named path aside (or delete it if you
are sure), then rerun:

```bash
mv ~/.zshrc ~/.zshrc.before-dotfiles
```

This repository never runs `stow --adopt` for you, automatically or behind a
flag: adopting would pull your existing file *into* the checkout and silently
overwrite the tracked one. Deciding what happens to a pre-existing file is
yours. See [file ownership](architecture/file-ownership.md) for what gets
linked where.

## The last installation is recorded as failed or interrupted

`./doctor` reports `Last installation is <status>` for anything other than a
completed run, and names the step it stopped at along with the completed and
pending ones. A failed run is never remembered, so `--rerun` cannot reapply
*it*; completed component changes are also not rolled back. Two ways forward:
reapply this machine's last successful configuration (preview it with
`./install.sh --rerun --dry-run`), or start a fresh `./install.sh` with the
options you want. See [rerun and the last-known-good model](workflows/rerun.md),
which also covers corrupt state, schema migration and the "predates `--rerun`
support" message.

## `./doctor` says a capability's state is for the wrong profile

```
✗ Enabled capability 'containers' has state for profile 'ocaml', not containers
```

Each optional capability keeps a machine-local record under
`~/.config/dotfiles/`, and every record declares the schema it is written in.
`./doctor` takes the schema it expects from the capability's own row in
`config/capabilities.tsv` — see [`state` and
`state_profile`](capabilities.md) — rather than from the file, so this says the
file under that name is not the record that capability writes. It is what a
restored backup, a hand-edited file or a copy made under the wrong name looks
like.

Nothing reads a mismatched record, so the fix is to reinstall the capability
and let its installer write the file: `./install.sh --rerun --dry-run` shows
what this machine last had, and `./install.sh --rerun` reapplies it. Moving the
file aside first keeps whatever was in it. `has corrupt state` is a different
finding on the same file: the schema is the right one and the record does not
satisfy it, and the same rerun is the answer.

## The first Neovim bootstrap is slow or times out

The installer drives Neovim headlessly to install LazyVim plugins and Mason
tooling. The first run on a new machine downloads everything and is expected to
take minutes. It fails with `... timed out after 20m` when it does not finish;
raise the budget for a slow link and rerun:

```bash
NEOVIM_BOOTSTRAP_TIMEOUT=40m ./scripts/install-neovim-tools.sh
```

The value is a plain `timeout` duration (`30m`, `3600s`). `Mason provisioning
incomplete; missing: ...` means the named Mason packages were still absent
after that phase — usually a network failure earlier in the same run, so rerun
the script. `LazyVim restore attempted a competing tree-sitter-cli
installation` is different: it means editor configuration changed who owns
`tree-sitter-cli`, and it is a repository bug rather than a machine problem.

## The prompt shows boxes, blanks or question marks

The Starship prompt is the Catppuccin Powerline preset and needs a Nerd Font.
This repository installs one only on the Parrot CTF guest; on Fedora, Fedora
WSL and macOS the font is yours to install and select in the terminal —
see [the terminal guide](workflows/terminal.md).

## mise installs an unrelated project's tools

Every `mise` call this repository makes runs from a neutral, repository-owned
directory with `MISE_CEILING_PATHS` set to it, precisely so a `mise.toml` in
whatever directory you launched the installer from cannot reach a global
bootstrap. If you see a project's tools appear anyway, the call was not one of
this repository's: running `mise install` by hand from inside a project applies
that project's configuration. Run it from your home directory, or let
`./install.sh --rerun` do it.

## `sudo`, `git`, or other `/usr/bin` commands suddenly disappear

In Zsh, `path` is a special array tied directly to `PATH`.

Do **not** use `path` as a casual variable:

```zsh
# Bad
path="$(command -v something)"
```

Use:

```zsh
cmd_path="$(command -v something)"
```

## Theme switching does not affect an existing shell

Run:

```bash
exec zsh
```

The `theme` Zsh wrapper normally does this automatically.

## Neovim does not update immediately after a theme switch

Refocus the Neovim window. The Catppuccin config checks the machine-local theme on `FocusGained`, and `tmux/.tmux.conf` sets `focus-events on` so the event reaches a pane.

## EasyDotnet warns that its Roslyn LSP is disabled

Expected. Roslyn is owned by `roslyn.nvim`.

## EasyDotnet warns about `dotnet ef`

A repository-local `dotnet-ef` tool is preferred when the project requires it.

## `mise` fails to install `dotnet:EasyDotnet` with a missing ICU error

```text
Couldn't find a valid ICU package installed on the system. Please install
libicu (or icu-libs) using your package manager and try again.
```

The .NET runtime needs ICU for globalization support, and `libicu` is part
of this repository's base Fedora/DNF package list precisely so this
doesn't happen — if you see this, the install ran before `libicu` was
added, or `libicu` failed to install for some other reason. Install it and
rerun:

```bash
sudo dnf install -y libicu
mise install
```

## Ghostty cannot find packaged themes on Fedora/Terra

The Terra Ghostty RPM may omit the upstream bundled theme collection.

This repository tracks the four required Catppuccin Ghostty theme files directly.

## Ghostty starts Bash after the installer configured Zsh

Confirm that the account entry changed:

```bash
getent passwd "$(id -un)" | cut -d: -f7
```

If this reports `/usr/bin/zsh` or `/bin/zsh` while `echo "$SHELL"` still reports
Bash, reboot the machine. The already-running Plasma, systemd user, and D-Bus
session can retain `SHELL=/bin/bash`, which Ghostty checks before the account
entry. `env -u SHELL ghostty --gtk-single-instance=false` is a useful diagnostic
because it makes an independent Ghostty process fall back to the passwd entry;
it is not required after rebooting.

## `pynvim` is not an executable

Expected. Verify the Python provider through Neovim health checks instead.

## `claude`/`codex`/`herdr` are not found after `--ai`

First run `./scripts/verify-ai.sh`. The installer and verifier explicitly add
the normal user-bin and mise shim directories, so a command should not be
reported missing merely because the calling Bash session predates the final
Zsh configuration. Confirm the AI profile's untracked mise config exists and
mise sees it, then reinstall:

```bash
cat ~/.config/mise/conf.d/ai.toml
mise install
```

If the file is missing, rerun `./scripts/install-ai.sh` with **the same
sub-flags the original install used** — any of `--codex`, `--firstmate`,
`--gnhf` and `--backpass`. Reinstalling with fewer than were recorded leaves
the state naming a component the untracked `ai.toml` no longer declares, which
`verify-ai.sh` reports as a failure. `./doctor` shows the recorded selection,
and rerunning is otherwise safe.

## `claude native binary not installed`

`command -v claude` is not a sufficient health check: the npm wrapper can
exist while Claude Code's platform-native optional dependency is absent. The
AI installer detects this with `claude --version`, reports the effective
`npm config get ignore-scripts` and `npm config get omit` values (plus the
corresponding `NPM_CONFIG_*` variables when set), and makes one Claude-only
repair attempt. Its per-tool mise arguments override those settings for this
installation without rewriting `~/.npmrc`.

If that bounded repair still fails, inspect the reported npm settings and run
the known manual recovery:

```bash
mise uninstall npm:@anthropic-ai/claude-code
mise install
```

## `<tool> resolves outside mise in a login that is not interactive`

A verifier started a fresh `zsh -lc` and it ran a copy of a mise-owned tool
that is not mise's. mise is activated in `.zshrc`, which such a login never
reads; what gives it mise's tools is `~/.config/zsh/.zprofile`, which puts
mise's shims directory behind `~/.local/bin`. The message ends with the repair
for what that login was missing:

- **no mise shims directory on that login's PATH** — the machine was stowed
  before `.zprofile` existed. Restow the `zsh` package by rerunning the
  installer; the platform verifier also reports the missing
  `~/.config/zsh/.zprofile` link.
- **it sits ahead of mise's shims directory** — the copy is in a directory in
  front of the shims, normally `~/.local/bin`. Remove or rename that copy.
- **mise has no shim for it** — run `mise reshim`.

## `verify-ai.sh` reports a possible duplicate install

It found the command on `PATH` at neither mise's shim path nor the executable
reported by `mise which` - typically a native installer, Homebrew, or a global
`npm install -g` of the same tool installed outside this profile. Remove the
other installation (see each tool's own uninstall instructions) so only the
mise-managed copy remains on `PATH`.

## `@anthropic-ai/claude-code` keeps coming back in the Node prefix

`verify-ai.sh` reports the package as also installed globally with npm under
`~/.local/share/mise/installs/node/<version>`, the suggested `npm uninstall -g
@anthropic-ai/claude-code && mise reshim` clears it, and running `claude` puts
it straight back.

That is Claude Code updating itself. It reads its own executable path to decide
how it was installed, sees `/node_modules/@anthropic-ai/` in the mise npm
backend's path, concludes it is an ordinary global npm install, and runs `npm
install -g` — which lands in the active Node's prefix, not the backend prefix
mise installed into, so a second copy appears beside the first.

Check `~/.claude/settings.json`. It must contain both keys:

```json
{ "env": { "DISABLE_UPDATES": "1", "DISABLE_AUTOUPDATER": "1" } }
```

Rerunning `./common/install-ai.sh` declares them, merging into whatever else is
already in that file. If the installer reports the file instead of writing it,
the file does not parse as JSON or its `env` is not an object; repair it and
rerun. `zsh/.zshenv` exports the same setting, but only for shells and their
children, so a Claude Code launched from an editor or from a session older than
the install never sees it. See [the AI profile](profiles/ai.md#claude-code-does-not-update-itself).

## Editing `common/assets/AGENTS.md` doesn't change what an agent sees

`common/verify-ai.sh` reports whether `~/.claude/CLAUDE.md`,
`~/.codex/AGENTS.md`, and `~/.config/opencode/AGENTS.md` are actually
symlinked to it. If one reports a plain file or a symlink pointing
elsewhere instead, that path already had its own file before `--ai` was
first run, and `install-ai.sh` left it alone rather than overwriting it —
move that file aside (or edit it directly) if you want it to follow the
shared instructions instead.

## `treehouse` commands fail or a worktree seems stuck

Treehouse is not documented in detail here — see its own
[README](https://github.com/kunchenguid/treehouse) and `treehouse --help` for
the current command set (`get`/`enter`/`status`/`return`/`prune`/`destroy`/
`lease`) rather than relying on this document, which does not duplicate
fast-moving upstream option lists.
