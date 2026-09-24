# Zsh

The startup model is deliberately simple.

## `~/.zshenv`

Only early environment configuration belongs here:

```zsh
export ZDOTDIR="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"

typeset -gU path PATH
path=("$HOME/.local/bin" $path)
export PATH
```

## `~/.config/zsh/.zprofile`

Read by every Zsh **login**, interactive or not, and by nothing else. It puts
mise's shims directory on `PATH`, behind `~/.local/bin` and ahead of the
system directories:

```zsh
path=("$HOME/.local/bin" "$mise_shims" $path)
```

`$mise_shims` is resolved the way mise resolves it (`$MISE_DATA_DIR/shims`,
else `${XDG_DATA_HOME:-~/.local/share}/mise/shims`), and nothing is added
when that directory does not exist.

mise itself is activated in `.zshrc`, which only an interactive shell reads.
Without this file a login that is not interactive — `zsh -lc …`, and anything
started through one — ran whatever the system had under a mise-owned name:
dnf's `python`, `node` and `tree-sitter` on Fedora, Homebrew's on macOS. The
shims are mise's documented answer for exactly that shell.

It is `.zprofile` rather than `.zshenv` because a login reads the system's
`/etc/zprofile` in between, and on macOS that runs `path_helper`, which moves
the system directories in front of everything `.zshenv` added. `.zprofile` is
read after it, so what it puts in front stays there. Being login-only also
leaves a plain `zsh -c` script with the `PATH` it was given.

An interactive login goes on to read `.zshrc`, and `mise activate` there puts
the install directories of the active versions ahead of both `~/.local/bin`
and the shims, so an interactive shell resolves exactly what it did before.

A machine stowed before this file existed does not have it: restow the `zsh`
package (rerun the installer). The platform verifiers check the link, and
their mise ownership check reports a runtime that such a login would run from
outside mise, naming that repair.

## PATH policy

Zsh ties the `path` array to `PATH`, and `typeset -gU` marks that pair unique.
Every later prepend or append — in `.zshenv`, in a platform file, in `mise` or
`opam` activation — is therefore idempotent: sourcing `.zshenv` or `.zshrc`
again, running `exec zsh`, or nesting a shell cannot grow `PATH`.

Zsh keeps the **first** occurrence of a duplicated entry, so this deduplicates
without reordering. Nothing sorts `PATH`, and deliberate precedence survives:

- `~/.local/bin` stays in front of the inherited environment;
- mise-managed tools keep the precedence mise's own activation gives them in
  an interactive shell, and in a login that is not interactive mise's shims
  directory follows `~/.local/bin`, ahead of the system directories;
- on macOS, Homebrew's coreutils `gnubin` stays **last**, so it supplies the
  GNU tools macOS does not ship (`timeout`, used by the shared Neovim
  bootstrap) without shadowing Apple's `ls`, `date` or `cp` — the trade-off
  this repository settles deliberately;
- on Fedora WSL, the platform hook still removes inherited `/mnt/<drive>/…`
  entries before any tool runs;
- on Parrot, the distro's `/usr/local/sbin:/usr/sbin:/sbin` search order is
  still appended, and `/snap/bin` still only when Snap is actually installed.

`tests/test-shell-startup.sh` proves this by sourcing the tracked startup
files three times in a row — bare, and under the Parrot and macOS platform
files — and requiring a byte-identical, duplicate-free `PATH` each time. It
also starts real `zsh -l` logins in a sandboxed home to prove the shims
precedence above.

## `~/.config/zsh/.zshrc`

Contains:

- history configuration
- interactive comments (`#`), completion menu, line-editing keys
- local Catppuccin flavor selection
- Lazygit/Bat/fzf/Starship theme selection
- zoxide
- fzf integration
- aliases and the `tar`/`untar` archive helpers
- mise activation
- Starship

The configuration intentionally avoids Oh My Zsh or another shell framework.

`.zshrc` sources the platform-owned file
`${XDG_CONFIG_HOME:-$HOME/.config}/zsh/platform.zsh` last, deliberately after
Starship, so that autosuggestions and syntax highlighting initialize in the
correct order. **Autosuggestions and syntax highlighting themselves are not
in `.zshrc`** — each platform's own `platform.zsh`
(`platforms/*/stow/zsh-platform/.config/zsh/platform.zsh`) sources its
packaged `zsh-autosuggestions`/`zsh-syntax-highlighting` plugin files from
that platform's package path. Every platform guards that source
(`[[ -r ... ]] ||`), so a machine whose packages are missing or mid-install
still starts cleanly — the same rule the optional integrations below follow.

## Optional tooling degrades, it does not break the shell

zoxide, fzf, mise and Starship are each initialized only when the command
exists. A machine missing one loses that feature and nothing else — the shell
still starts, and startup prints nothing, because a warning on every prompt is
noise rather than information. Ask for the summary when you want it:

```text
$ shell-integrations
This shell is running with reduced functionality:
  zoxide — z and zi directory jumping are unavailable
```

It exits non-zero when anything is missing, so a script can check it too.

Startup also deliberately ends with a clean exit status: otherwise the first
prompt of every shell would report a failure no command of yours caused — and
the Starship prompt now displays that number.

Measure startup with:

```bash
./scripts/benchmark-shell-startup.sh --runs 25
```

It reports interactive login (`.zshenv` + `.zprofile` + `.zshrc`, what a new
terminal window pays, since a terminal starts a login shell), interactive
(`.zshenv` + `.zshrc`) and non-interactive (`.zshenv` only) medians, and can
enforce a budget with `--interactive-login-ms`, `--interactive-ms` /
`--non-interactive-ms`. It is a manual tool rather than part of
`./scripts/test.sh`, because wall-clock timing is machine- and load-dependent.
The interactive ergonomics cost about 1–2 ms of interactive startup on
the reference measurement (≈50 ms median before and after, with all four
integrations present) and nothing measurable non-interactively (≈4–5 ms), so
no startup optimization was warranted.

Useful navigation:

```text
Up/Down   history entries matching what is already typed
Ctrl-R    fuzzy history search
Ctrl-T    fuzzy file insertion
Alt-C     fuzzy cd

Home/End  beginning/end of line
Delete    delete the character under the cursor
Ctrl+←/→  move one word backward/forward

z foo     zoxide ranked directory jump
zi        interactive zoxide selection
```

On macOS, `Alt` is **Left Option**: Ghostty is configured to send it to the
shell as Alt/Meta, while Right Option keeps typing symbols. See
[the macOS platform guide](../platforms/macos.md#left-option-is-alt).

Every editing key is bound to its `terminfo` sequence *and* to the documented
xterm, application-cursor and vt220/rxvt fallbacks, so the same keys work in
Ghostty, Noctty/WSL, KDE Konsole, a VM text console, SSH and tmux. See
[`docs/reference/keybindings.md`](../reference/keybindings.md) for the exact table.

## Archive helpers

```text
tar archive.tar.gz path...   create an archive (compression from the suffix)
untar archive.tar.gz         extract an archive
```

`tar` is a shell *function*, not an alias, so the native CLI is untouched:
`tar -tf`, `tar -xf`, `tar --help` and `command tar …` all behave exactly as
they always did. The shorthand applies only when the first argument is not an
option and carries a known archive suffix.
