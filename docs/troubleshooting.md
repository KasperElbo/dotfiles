# Troubleshooting

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

Refocus the Neovim window. The Catppuccin config checks the machine-local theme on `FocusGained`.

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

If the file is missing, rerun `./scripts/install-ai.sh` (add `--codex`
and/or `--firstmate` as needed) — it is safe to rerun.

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

## `verify-ai.sh` reports a possible duplicate install

It found the command on `PATH` at neither mise's shim path nor the executable
reported by `mise which` - typically a native installer, Homebrew, or a global
`npm install -g` of the same tool installed outside this profile. Remove the
other installation (see each tool's own uninstall instructions) so only the
mise-managed copy remains on `PATH`.

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
