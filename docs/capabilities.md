# Capability and provider contract

Two manifests describe the same installer from different sides.
`config/capabilities.tsv` says what a capability *is*: who provides it on
which platform, what it owns, what verifies it. `config/install-options.tsv`
says what the *CLI* accepts: the flag spellings, the kind of value, and what a
machine may remember. Documentation that states a supported capability, an
option, a default or a provider is generated from one of them or checked
against it, and `./scripts/validate-capabilities.py` checks the two against
each other so a change to one can never silently disagree with the other.

## `config/capabilities.tsv`

The authoritative inventory of supported and intentionally unsupported
capabilities. Each row assigns exactly one provider for a capability on a
platform and profile:

| Column | Meaning | Accepted values |
|---|---|---|
| `capability` | The capability's name, unique per platform and profile | any |
| `platform` | Which platform the row is about | `fedora`, `fedora-wsl`, `macos`, `parrot-ctf`, `windows` |
| `profile` | The profile within that platform | any |
| `cli_flag` | The flag that selects it, if it has one | a flag, or `-` |
| `default` | What it does when the flag is absent | `enabled`, `disabled`, `auto` |
| `dependencies` | Capabilities that must also be selected | names, or `-` |
| `conflicts` | Capabilities it cannot be selected with | names, or `-` |
| `provider` | Who installs it | any; an `unsupported` row must use `unsupported`, `windows-host` or `user-managed` |
| `packages` | The packages this capability owns on that platform, in that platform's own package manager | names, or `-` |
| `stow` | The Stow packages it deploys | names, or `-` |
| `verifier` | The script that checks it | a path, or `none` on an unsupported row |
| `state` | Its machine-local state file | a name, or `-` |
| `docs` | Where it is documented | a path, optionally with an `#anchor` |
| `provenance` | Where the thing itself comes from | any |
| `status` | Whether this repository provides it | `implemented`, `unsupported` |
| `installers` | The files that request its packages | repository-relative paths, or `-` |
| `ci_scope` | Whether it is deliberately never selected by the real-install workflow, and why | `-`, or `excluded:<why>` |

An `implemented` row must name a provider, a verifier, documentation and a
provenance; an `unsupported` row must name who owns that absence. Deliberate
absence is recorded rather than left out, so the generated
[capability matrix](reference/capability-matrix.md) can distinguish "we do not
do this here" from "nobody has considered it".

`ci_scope` is the one column that is about CI rather than about the capability
itself, and it exists because "a verifier ran" and "this capability was
installed" are different claims. `-` makes no claim: the capability must then
actually be selected by `.github/workflows/real-install.yml` or a script one of
its steps runs. `excluded:<why>` says it deliberately never is, and the reason
is part of the value, because this file has no comment syntax — three readers
treat line 1 as the header and every other line as a row. Three rows carry one
today: `fedora/latex` and `fedora-wsl/latex`, whose TeX Live install is
gigabytes on every scheduled run, and `macos/dictation`, which needs a desktop
session and a microphone no runner has and is verified by the manual checklist
in [the dictation profile](profiles/dictation.md). An exclusion the workflow
contradicts fails, so it cannot outlive its reason.

`-` is this file's only spelling of "none", in every column that can be empty.
It is a decision, not a blank: `packages` is `-` when the capability installs
no package at all, and `stow` is `-` when it deploys no Stow package at all.
Two columns therefore read the same way on a platform that has no Stow tree:

- **`packages` is that platform's package manager, whichever one it is.** The
  `windows` rows record Scoop package names (`noctty`, `handy`) exactly as the
  Fedora rows record DNF names and the macOS rows record Homebrew formulae. The
  `provider` column is what says which manager a name belongs to, and
  `installers` names the files that request them — for Windows,
  `platforms/windows/install.ps1` and the `platforms/windows/manifest.psd1` it
  reads the package and bucket names from.
- **`stow` is `-` on every `windows` row, and that is the whole story.** The
  Windows host has no Stow tree and no Stow script under `platforms/windows/`:
  `install.ps1` writes *copies* into `%LOCALAPPDATA%\noctty\`, compared by
  hash and rewritten when they differ, rather than symlinking into a checkout.
  The Stow ownership check skips a platform that declares no Stow package and
  has no Stow script; declaring one there fails, and adding a `stow.sh` puts
  the platform straight back under the check.

The Windows host differs from the other four platforms in two further ways,
both recorded rather than implied. Its `cli_flag` values are PowerShell
switches of `platforms\windows\install.ps1` (`-Handy`), not `--flags` of a
Bash parser, and they have no `config/install-options.tsv` row: that manifest
is the contract of the `platforms/<platform>/install.sh` parsers and of what
`./install.sh --rerun` remembers, while the Windows installer records its own
selection in `%LOCALAPPDATA%\dotfiles\windows-selection.json` for its verifier
to read. And `--platform windows` is deliberately rejected by `./install.sh`:
that entry point runs `platforms/<name>/install.sh`, so its list of supported
names is the manifest's implemented `base` rows that have one. See
[the Windows host guide](platforms/windows.md).

## `config/install-options.tsv`

Every persistent installer option: what the parser accepts and what a machine
may remember. `common/lib/install-selection.sh`, the installer's own parser
and the generated [installer options](reference/installer-options.md) all read
it, so an option that is not here is one the installer rejects.

| Column | Meaning | Accepted values |
|---|---|---|
| `platform` | Which platform's installer accepts it | as above |
| `option` | The name used in a remembered selection record | any |
| `kind` | What kind of value it carries | `boolean`, `tristate`, `value` |
| `on_flag` / `off_flag` | How it is turned on and off | a flag, or `-` |
| `default` | What it resolves to when neither flag is given | `true`, `false`, `auto` (boolean); `true`, `false`, `inherit`, `auto` (tristate); a value or `-` (value) |
| `values` | The permitted values of a `value` option; the installer and `common/setup-local.sh` read `theme`'s flavours from here | a regex alternation, or `-` |
| `capability` | The capability the option selects | a name, or `-` |
| `summary` | The one-line description the reference renders | any |

A default of `auto` means the installer resolves the option itself, by
detecting or by asking; a *recorded* value is always the resolved one, never
`auto`. Controls that belong to one invocation rather than to the machine —
`--dry-run`, `--non-interactive`, `--rerun`, `--dev-workflows` — deliberately
have no row here, because a machine's remembered configuration must not
replay them.

## How the two are checked against each other

`./scripts/validate-capabilities.py` reads both and fails when they disagree:

- A capability with a `cli_flag` needs an option on the same platform whose
  `on_flag` is that flag, and the defaults must agree: `enabled` is `true`,
  `disabled` is `false` (`inherit` for a tristate, `-` for a value option),
  and `auto` is `auto`. Changing a default in one manifest alone fails lint.
- `--dev-workflows` is the one flag with no option row, carried as an explicit
  exception because it is a transient control. The `windows` rows are exempt
  from this check as a whole: their flags are PowerShell switches, and that
  manifest has no rows for a platform without an `install.sh`.
- An option that selects a capability needs an `implemented` row for that
  capability on its platform, so deleting a row cannot quietly drop an option.
- Packages are compared with the files that install them, in both directions:
  a package a row declares must be requested by one of the files its
  `installers` column names (a mise configuration is parsed, so the package
  must be a declared tool), and every entry of a `*packages=(...)` array in an
  installer must be owned by some capability on that platform. A row that
  declares packages but names no installers fails, unless it is listed with
  its reason in `PACKAGES_CHECKED_ELSEWHERE`.
- The `stow` column, which preflight uses to find conflicting dotfiles before
  anything is installed, must name exactly the Stow packages
  `common/stow.sh` and `platforms/<platform>/scripts/stow.sh` can deploy on
  that platform, conditional branches included. A platform that deploys no
  Stow package and has no Stow script is skipped rather than reported as
  missing one.
- Conflicts must be declared on both rows of a pair.

`./scripts/validate-install-options.py` closes the loop with the code that
reads the options: every flag a `platforms/<platform>/install.sh` argv parser
accepts must be an `on_flag` or `off_flag` of that platform, and every such flag
must have a case arm, reported by name in both directions. Transient controls
and deprecated aliases are listed in the validator, and so are the flags a
platform deliberately rejects with an explanation (`--tailscale` on Fedora WSL,
`--latex` on macOS), whose arms must really `die`.

`--dry-run` stops before preflight, but it still runs the pure
`capability_validate_selection` check, so a plan is never shown for a
capability the manifest does not implement.

## To add or change a capability

1. Add or update its rows for every relevant platform. Record intentional
   absence with `status=unsupported`; do not imply cross-platform parity.
2. Keep one package owner per platform. Baseline and optional package lists
   must not both own the same package. A package two independently selectable
   capabilities each install on their own is the one exception, and it is
   listed explicitly in `./scripts/validate-capabilities.py` with its reason.
3. Give it a row in `config/install-options.tsv` if it has a `cli_flag`, and
   add the installer implementation and verifier before marking it
   `implemented`. Name the files that request its packages in `installers`,
   and its Stow packages in `stow` next to the Stow script that deploys them.
   Then select it in `.github/workflows/real-install.yml`, or in the
   `tests/integration/` sequence one of its steps runs, so a real installation
   proves it — or write the reason it never will into `ci_scope`.
4. Add focused positive and negative tests, then run `./scripts/lint.sh` and
   `./scripts/test.sh`. Lint runs every validator and every generator in
   `--check` mode, so a manifest change that was not regenerated fails there.
   Six generators read `config/capabilities.tsv`, and a change can reach any of
   them; regenerate with `./scripts/render-action-reference.py`,
   `./scripts/render-capability-matrix.py`,
   `./scripts/render-file-ownership.py`,
   `./scripts/render-installer-options.py`,
   `./scripts/render-package-ownership.py` and
   `./scripts/render-verifier-reference.py`.

`config/capabilities.tsv` records which capability owns a provider and
packages. Its companion, `config/network-sources.tsv`, records where each
network source comes from, its provenance tier, privilege level, integrity
mechanism, update cadence, and rollback strategy. Together they are the
authoritative source/ownership model; see
[supply-chain.md](supply-chain.md) and the generated
[network-source inventory](supply-chain-sources.md). A capability whose
provider reaches the network must have its sources registered there, and
`./scripts/lint.sh` fails if one is missing.

`config/actions.tsv` belongs to the same family. It owns the
repository's user-facing actions — keyboard bindings, status-bar clicks, shell
helpers and editor mappings — with the same rules: one authoritative row per
action, an explicit record of what is deliberately absent, and mechanical
validation in both directions by `./scripts/validate-actions.py`. The full
reference in [reference/keybindings.md](reference/keybindings.md) is generated
from it; the printable cheat sheets are checked against it.

The manifests are declarative ownership metadata. They deliberately do not
generate package-manager commands or replace the independently useful
component installers.

## Verifiers must name what they verify

A row that names a verifier promises a check. `./scripts/validate-capabilities.py`
therefore requires every `implemented` row whose verifier is a platform
verifier — `platforms/<platform>/scripts/verify.sh`, or
`platforms/<platform>/verify.ps1` on the Windows host — to mention that
capability in the file; `base` is exempt, because a platform verifier is about
the baseline from its first line. Where the section that performs the check does not name the
capability in its own code, mark it with a one-line `# verifies: <capability>`
comment in the section header. Separators are normalized when the file is
searched, so `dotnet-debug` is also satisfied by `check_easy_dotnet_debugger`.

The check is deliberately shallow: it cannot prove a check is correct, only
that a verifier declared for a capability says something about it. A verifier
that never mentions the capability it is declared for verifies nothing, and a
selected profile then passes verification unconditionally — which is exactly
what the README's "what is not verified is said to be not verified" forbids.

## Verifiers must check what their row relies on

Four further rules in the same validator hold each declared verifier to what
its row actually claims. `tests/test-capabilities.sh` breaks a scratch copy of
the repository once per rule, proving each one can fail:

- **Components.** A row whose `stow` column deploys `starship`, `nvim-lazyvim`
  or `tmux` relies on something outside that package: the machine-local theme
  state that selects the Catppuccin flavour, the tracked Mason inventory, and
  the pinned Catppuccin tmux plugin. Its verifier must check each one;
  `STOW_COMPONENT_EVIDENCE` in the validator names the reference that counts.
- **No copied package lists.** A verifier never keeps a literal
  `packages=(...)` array. It reads the row with `capability_packages` from
  `common/lib/capabilities.sh`, so the list it checks cannot drift from the one
  the installers are validated against.
- **One reporting contract.** Every declared Bash verifier, and every verifier
  it runs, sources `common/lib/verify.sh` instead of defining its own `pass`,
  `fail` and `warning`. `platforms/windows/verify.ps1` cannot source a Bash
  library, so this rule has nothing to say about it; it carries the same
  contract in PowerShell — `[PASS]`/`[FAIL]` lines, a counted summary and a
  non-zero exit — and `tests/test-windows-verifier.ps1` holds it to that. Every summary then counts failures and warnings the
  same way, and every verifier can use the shared ownership checks.
  `scripts/doctor.sh` is not a verifier and documents why it keeps its own.
- **Run by CI.** Every declared verifier must be run against a real
  installation by `.github/workflows/real-install.yml`, directly or through a
  `tests/integration/` sequence or a `tests/*.ps1` suite one of its steps runs.
  A PowerShell suite spells repository paths with backslashes, which the check
  normalizes before looking for the verifier it is evidence for. The verifiers of
  profiles no real-install job installs are listed in `MOCKED_VERIFIERS` with
  the default fast suite that runs them against a mocked machine instead, and
  that suite must be in `scripts/test.sh`'s default tests and run the verifier.
- **Selected by CI.** Running a verifier is not installing the capability it is
  declared for. Six capabilities declared the shared platform verifier, which
  every real-install job runs, while no job ever passed their flag: their
  verifier ran and they did not. So a second rule reads the flags of every
  `./install.sh` invocation in `.github/workflows/real-install.yml` and in the
  `tests/integration/` sequences its steps run — the invocation's own arguments,
  not the file's text, so a flag written in a step title or a comment proves
  nothing — and requires an `implemented` row with a `--flag` to be among them.
  A row that is not may say so in `ci_scope` and no other way. Rows whose
  evidence is a mocked machine (`MOCKED_VERIFIERS`) answer to the rule above
  instead, and a transient control such as `--dev-workflows` installs nothing,
  so running its verifier is the whole capability.

The shared library carries the checks these rules lead to.
`check_command <name> --probe` runs a command instead of only finding it on
PATH, with a documented probe for the few commands that do not answer
`--version`. `check_system_service_enabled_and_active` and its `_user_`
counterpart require a service to survive a reboot as well as be running, and
name which half is missing. `check_mason_inventory`, `check_catppuccin_tmux`
and `check_mise_owned` are the component and ownership checks every workstation
verifier shares.

## Command-provider closure

`config/command-providers.tsv` is the one list of native commands each bash
platform's installer checks before it mutates the host. Every
`platforms/*/install.sh` preflight reads it through
`preflight_platform_command_providers`; no installer states its own command
list, and `tests/test-command-provider-closure.sh` fails if one does. Each row
maps a command to one owning capability and provider, and classifies its
availability as:

- `bootstrap-prerequisite`: required before the installer can mutate the host;
- `supported-base`: guaranteed by the documented supported base system but
  still checked before mutation;
- `baseline-package`: installed by exactly one capability package owner before
  the command is used;
- `repository-file`: installed or linked from one named file in this checkout.

The Fedora workstation and official Fedora WSL rows close the wider bootstrap
boundary: every native command used by bootstrap, installation, or base/Sway
verification. The Apple Silicon macOS and Parrot CTF rows cover exactly their
pre-mutation checks; the commands their verifiers use are not yet closed here.

The table does not duplicate language-runtime or repository-script ownership.
Those remain with mise, Mason, Stow, and the capability manifest. Run
`./scripts/validate-command-provider-closure.py` after changing a platform
baseline, the Sway packages, or their command requirements.

The validator reads the manifest and checks each row against the tree, not the
other way round: it proves every row names a real owner, provider and file, but
a command a script runs without a row here is simply never preflighted. Adding
the command to a script therefore means adding its row too; nothing fails if
you forget.
