# Repository conventions

Conventions for changing this repository itself, as opposed to operating a
machine it has installed.

## Repository hygiene

Do not vendor entire third-party plugin repositories inside Stow packages.

Catppuccin tmux, for example, lives in:

```text
~/.local/share/tmux/plugins/catppuccin
```

and is installed by a pinned installer script.

Do not commit:

- Git identities
- private keys
- tokens
- machine-local theme state
- runtime logs
- nested Git repositories
- recorded audio, transcription history, or downloaded speech models

Do not leave a package manager's lockfile at the repository root without the
project it belongs to. `./scripts/lint.sh` rejects a lone root lockfile: it
makes dependency and supply-chain tooling treat this repository as a project it
is not.

## Generated artifacts

Some tracked files are output, not source. Editing one by hand is wasted work:
the next `./scripts/lint.sh` fails because the file no longer matches what its
generator produces, and the next regeneration overwrites the edit. This is the
complete list — if a tracked file is generated and is not here, that is a bug in
this table.

| Artifact | Generated from | Generator |
|---|---|---|
| [`docs/reference/capability-matrix.md`](../reference/capability-matrix.md) | `config/capabilities.tsv` | `scripts/render-capability-matrix.py` |
| [`docs/reference/installer-options.md`](../reference/installer-options.md) | `config/install-options.tsv` | `scripts/render-installer-options.py` |
| [`docs/reference/verifiers.md`](../reference/verifiers.md) | `config/capabilities.tsv` | `scripts/render-verifier-reference.py` |
| [`docs/supply-chain-sources.md`](../supply-chain-sources.md) | `config/network-sources.tsv` | `scripts/render-supply-chain.py` |
| The action reference block in [`docs/reference/keybindings.md`](../reference/keybindings.md) | `config/actions.tsv` | `scripts/render-action-reference.py` |
| The inventory blocks in [`docs/architecture/package-ownership.md`](package-ownership.md) | `config/capabilities.tsv`, the tracked mise config, the Mason inventories | `scripts/render-package-ownership.py` |
| The flow block in [`docs/architecture/installation.md`](installation.md) | the `plan_add` calls in `platforms/*/install.sh` | `scripts/render-install-flows.py` |
| The Stow and state blocks in [`docs/architecture/file-ownership.md`](file-ownership.md) | the stow scripts and `config/capabilities.tsv` | `scripts/render-file-ownership.py` |
| `starship/.config/starship/catppuccin-*.toml` | `config/starship/` | `scripts/update-starship-themes.sh` |

Every one of those generators takes `--check`, and `./scripts/lint.sh` runs all
of them that way, so a manifest edit that is not reflected in its output fails
the build rather than quietly making a page wrong. Regenerate by running the
generator with no arguments.

The comparison each gate makes lives in one place, `scripts/lib/generated.py`,
and it is on bytes. Eight copies of the same five lines meant eight copies of
the same mistake: reading the committed file in text mode translated `\r\n` and
a lone `\r` to `\n`, so a file whose bytes differed from a fresh render was
reported as current and running the generator then changed it. `.gitattributes`
stores and checks out every text file with `\n` so the question does not arise
in the first place; the byte comparison is what notices if something gets past
that.

A whole-file artifact says so in its first lines; a partial one is delimited by
`<!-- BEGIN GENERATED … -->` and `<!-- END GENERATED … -->` markers, and the
prose outside those markers is hand-written and yours to edit.

The printable [cheat sheets](../cheatsheets/README.md) are the deliberate
exception: `docs/cheatsheets/generate.sh` renders them from tracked LaTeX
source, but the PDFs are not committed, so there is no output that can go
stale.

## What a check may conclude from

A gate exists to catch a class of mistake, so it has to be written so that the
mistake it names cannot get past it. Two rules, both learned from gates that
failed open on exactly what they existed to catch:

**A check over shell must read shell.** A regex over a file's raw text proves
nothing about behaviour. `# ripgrep` still contains the word `ripgrep`, so a
package commented out of an installer array still satisfies a text search; a
commented-out `bindsym` line still contains its key, so the registry and the
printed cheat sheet keep advertising a key that does nothing. Drop the comment
lines before matching (`code_text()` in `scripts/validate-capabilities.py` and
in `scripts/validate-actions.py`), parse the construct, or run the shell and
observe what it did. The same holds for the other configuration languages: a
mise pin and an AeroSpace binding are parsed as TOML, a Waybar click as JSON.

Where several checks read shell, they read it through one module,
[`scripts/lib/shell.py`](../../scripts/lib/shell.py), rather than each carrying
its own regex. The copies it replaced had drifted into two defects that are
easy to write again: the keyword opening a statement was captured as the
command the statement runs, so `if helper; then` reported `if` and `then` and
the helper was never seen; and a definition counted only with its brace on the
same line, so the same function moved between "code that runs" and "a function
nothing calls" depending on where the brace sat. A reserved word is therefore
never a callee, and the three spellings of a definition -- brace on the line,
brace below it, whole function on one line -- are one definition.

**A check that cannot parse its input must error.** Skipping the line it cannot
read turns a gate into a suggestion, and that line is the one most likely to be
wrong. `scripts/validate-plan-network.py` names the file and the line and fails
the build when a `plan_add` call does not tokenise, rather than dropping the
step from a check that runs in both directions. No validator may `continue`
past input it was written to check.

## Entry points, and what `scripts/` actually is

A file living under `scripts/` is not automatically a public, cross-platform
command. This repository groups its executables and sourced files into a
handful of illustrative kinds below, but the table is a reading aid, not the
inventory: **`config/shell-file-roles.tsv` is the exhaustive, authoritative
list of roles.** Every tracked shell file (and every tracked file under a
stowed `bin` directory, plus the PowerShell/Python files `scripts/validate-shell-file-roles.py`
also governs) matches exactly one row there, which fixes both its role and its
required file mode; `./scripts/lint.sh` enforces the match.

A program's extension does not decide whether it is governed, because a command
on `PATH` has none: a `platforms/*/assets/*` file carrying a shell shebang is
claimed too, which is how the Wayland session command came to have a role. The
same shebang rule decides what the lint gate syntax-checks and ShellChecks —
see [what the shell lint gate checks](../testing.md#what-the-shell-lint-gate-checks).

| Kind | Where (examples) | What it means |
|---|---|---|
| **Portable entry point** (`public-entrypoint`) | `./install.sh`, `./doctor`, `./scripts/lint.sh`, `./scripts/test.sh` | Works on every supported platform. These are the documented way in. |
| **Platform entry point** (`platform-entrypoint`) | `platforms/<platform>/install.sh` | Belongs to exactly one platform and is the documented way to install just that platform. |
| **Platform command** (`platform-command`) | `platforms/<platform>/scripts/*.sh` | Belongs to exactly one platform and says so in its path. Safe to run directly when you want one component. |
| **Portable wrapper** (`portable-wrapper`) | `scripts/install-ai.sh`, `scripts/install-mise.sh`, `scripts/install-neovim-tools.sh`, `scripts/install-tmux-theme.sh`, `scripts/verify-ai.sh` | A supported alias for the matching `common/` script. Not deprecated: the target really is portable. |
| **Deprecated compatibility wrapper** (`deprecated-wrapper`) | every other `scripts/*.sh` | A Fedora-only path from before the platform layout existed. Still forwards; see below. The catch-all is enforced by a body check, not by the pattern alone: a `scripts/*.sh` file that never calls `deprecated_wrapper` fails lint until it is given its own exact row. |
| **Internal implementation** (`internal-executable`) | `common/*.sh`, `scripts/install-main.sh`, `scripts/bootstrap-macos.sh`, `scripts/doctor.sh` | Called by a documented entry point. Individually rerunnable, but not the documented interface — `scripts/doctor.sh` is the implementation `./doctor` execs into, not something to run directly. |
| **Sourced library** (`sourced-library`) | `common/lib/*.sh`, `platforms/*/lib/*.sh`, `scripts/lib/*.sh`, `tests/lib/*.sh` | Meant to be sourced, never executed. Never carries the executable bit. |
| **Stowed command** (`stowed-command`) | `bin/.local/bin/*`, `platforms/*/stow/*/.local/bin/*` | Lands on `PATH` once stowed; a real command a user runs by name. |
| **Stowed config / data** (`stowed-config`, `stowed-data`) | `zsh/.config/zsh/*`, `fzf/.config/fzf/themes/*.sh` | Sourced by an interactive shell or another tool once stowed; never executed directly. |
| **Test entry point** (`test-entrypoint`) | `tests/test-*.sh`, `tests/integration/*.sh` | A test suite, run by `./scripts/test.sh` or directly. |
| **Installed system command** (`installed-system-command`) | `platforms/fedora/assets/dotfiles-sway` | Installed onto the machine outside `$HOME` by a platform script, which sets the executable bit; the tracked copy stays 644. |

See `config/shell-file-roles.tsv` for the full set of patterns, including the
Windows (`.ps1`) and Python entry points and libraries it also governs.

### Deprecated wrappers

`scripts/install-sway.sh` and its siblings look cross-platform and are not:
they forward to `platforms/fedora/`. Repository search cannot prove nobody
outside this repository invokes them, so they are not being removed on that
evidence.

Each one now prints a single notice to stderr — never stdout, so a caller
parsing output is unaffected — naming the supported replacement, the platform
script it forwards to, and the date before which it will not be removed. The
forwarding itself is unchanged. `DOTFILES_SUPPRESS_DEPRECATION=1` silences the
notice for scripted use.

```text
DEPRECATED: scripts/install-sway.sh is a compatibility wrapper.
            Use ./install.sh --platform fedora --sway instead.
            For this component alone, run platforms/fedora/scripts/install-sway.sh.
            It keeps working, and is removed no earlier than 2027-03-15.
```

The removal date lives in one place, `common/lib/deprecation.sh`, so the window
is one decision rather than a date copied into thirty files. **Removal is a
separate, later change**, not part of the deprecation: nothing here removes a
wrapper, and nothing should until that date has passed.

### File modes

The executable bit is a contract: it says "this is an entry point you may run".
`config/shell-file-roles.tsv` gives every tracked shell file exactly one role
and one mode — `0755` for anything meant to be executed, `0644` for anything
meant to be sourced — and `./scripts/lint.sh` enforces it. A file matching no
role fails too: classifying a new script is part of adding it.

### Names say what a file does

Three unrelated files were once called `theme-state.sh`. They are now named for
their responsibility:

| File | Responsibility |
|---|---|
| `common/lib/theme-shared-state.sh` | Writes the derived state files every platform reads |
| `platforms/fedora/lib/theme-desktop.sh` | Generates and applies the Fedora desktop half: Sway, Waybar, Fuzzel, Mako, swaylock, wallpaper, cursor |
| `scripts/lib/theme-state.sh` | Deprecated shim that forwards to the first |

## Licensing

This repository's own scripts, configuration and documentation are **MIT
licensed**; the text is at [`LICENSE`](../../LICENSE) and the decision, with
what was considered alongside it, is recorded in
[`docs/reference/licensing.md`](../reference/licensing.md).

Third-party material vendored or fetched here keeps its own upstream licence,
which that choice does not change. What is incorporated, at which upstream
revision, and under which licence is indexed in
[`docs/reference/third-party-notices.md`](../reference/third-party-notices.md).
Retained upstream licence texts live in [`LICENSES/`](../../LICENSES) and beside the
material they cover.

Adding vendored material therefore means adding a row to those notices. A new
file written here needs no per-file licence header: the root `LICENSE` covers
the whole of this repository's own material.
