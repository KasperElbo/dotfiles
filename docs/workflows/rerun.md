# Reapplying the last successful configuration

```bash
./install.sh --rerun
./install.sh --rerun --dry-run
```

`--rerun` reapplies the configuration of this machine's last *successful*
installation, so the options do not have to be remembered or reconstructed by
hand. It means "apply the remembered configuration with the installer in this
checkout", not "run the old command again": the selection is remembered, the
implementation is always the current one. If a provider or a component script
changes on `main`, a rerun uses the new one for the same remembered choice.

What is remembered is the *resolved persistent configuration*: platform, theme,
every positive and explicit negative capability choice, value-bearing options
such as `--hardware`/`--charge-limit`, the AI subcomponent choices, and the
platform's own options. An auto-detected or interactively answered option (KDE
detection, the LaTeX prompt) is recorded as what it resolved to. Transient
execution controls are deliberately not remembered and never replayed:
`--dry-run`, `--non-interactive`, `-h/--help`, confirmation answers, and the
`--dev-workflows` smoke tests all belong to a single invocation.

Only `--dry-run` and `--non-interactive` may accompany `--rerun`, and they
affect that run alone. `--platform` is accepted when it matches the remembered
platform. Every other option is rejected with a focused message rather than
silently merged with the remembered selection:

```text
$ ./install.sh --rerun --theme mocha
ERROR: --rerun cannot be combined with --theme
```

A rerun goes through the ordinary preflight, execution plan,
[confirmation](install.md#the-confirmation-prompt) and verification path. `./install.sh --rerun --dry-run` prints where the selection
came from, when it was recorded, the reconstructed options and the resolved
execution plan, and changes nothing.

### What the machine remembers

The configuration lives in the existing versioned lifecycle state at
`${XDG_STATE_HOME:-~/.local/state}/dotfiles/install.conf` — there is no second
configuration store, no saved command file and no saved shell script:

| Key | Meaning |
|---|---|
| `selection` | the configuration of the run being applied, for diagnostics |
| `last_successful_selection` | the `--rerun` target: the configuration of the newest completely successful install |
| `last_successful_platform` | the platform that configuration installed |
| `last_successful_at` | when it completed |
| `selection_schema` | encoding version of `last_successful_selection` (currently `1`) |

A selection is a compact `option:value` record — for example
`theme:mocha,kde:false,...,hardware:ga402xz,secure-boot:true,charge-limit:80` —
whose options are declared per platform in `config/install-options.tsv`. The
common layer turns that record back into the arguments the current parser
accepts; `config/install-options.tsv` is the one place where a persistent
option's flag spelling lives, and the capability-owning rows are checked
against `config/capabilities.tsv`.

The human-readable `rerun` command recorded next to it stays for display and
debugging only. Nothing in this path evaluates stored command text, and no
credential, token or password is ever part of a selection.

### Last-known-good semantics

Only a completely successful installation replaces the remembered
configuration. A dry run, a failed preflight, a cancelled confirmation, a
failed step, a failed verifier and an interrupted run all leave the previous
successful configuration in place, so a broken attempt never costs a machine
its ability to reapply the configuration it actually had.

That also means a failed run has nothing for `--rerun` to reapply, so it ends
by printing the literal command that reproduces the selection it was
attempting:

```text
==> Safe rerun: ./install.sh --platform fedora-wsl --theme mocha --no-ocaml --latex --no-containers --no-ai --non-interactive
```

Every platform renders that line from the same selection the record stores, so
it names the machine you asked for rather than the platform's defaults.

### Validation, errors and migration

Before anything is applied, `--rerun` validates the state schema, requires a
recorded successful install, resolves the remembered platform, and checks every
remembered option and value against the current manifest and parser. It stops
with a focused diagnostic — never a generic "invalid arguments" — when there is
no previous successful install, when only interrupted state exists, when the
state is corrupt or its schema unsupported, when the platform does not match,
when a remembered option has been removed or renamed, and when illegal options
accompany `--rerun`. An option *added* after the record was written is reported
and falls back to its declared default rather than disappearing silently.

The minimum lifecycle state that supports `--rerun` is profile-state schema 2
with `last_successful_selection`, `last_successful_platform` and
`selection_schema=1` in the `install` profile. State written before this feature
existed has no structured configuration and cannot be reconstructed faithfully,
so `--rerun` refuses it with a migration message (and shows the old recorded
command for reference) instead of guessing. One ordinary installation records
everything a rerun needs; no reinstall-from-scratch is required.

`./install.sh doctor` reports whether a valid remembered configuration exists
and how to use it, without dumping the record itself.
