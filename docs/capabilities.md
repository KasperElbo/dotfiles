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
| `platform` | Which platform the row is about | `fedora`, `fedora-wsl`, `macos`, `parrot-ctf` |
| `profile` | The profile within that platform | any |
| `cli_flag` | The flag that selects it, if it has one | a flag, or `-` |
| `default` | What it does when the flag is absent | `enabled`, `disabled`, `auto` |
| `dependencies` | Capabilities that must also be selected | names, or `-` |
| `conflicts` | Capabilities it cannot be selected with | names, or `-` |
| `provider` | Who installs it | any; an `unsupported` row must use `unsupported`, `windows-host` or `user-managed` |
| `packages` | The packages this capability owns on that platform | names, or `-` |
| `stow` | The Stow packages it deploys | names, or `-` |
| `verifier` | The script that checks it | a path, or `none` on an unsupported row |
| `state` | Its machine-local state file | a name, or `-` |
| `docs` | Where it is documented | a path, optionally with an `#anchor` |
| `provenance` | Where the thing itself comes from | any |
| `status` | Whether this repository provides it | `implemented`, `unsupported` |

An `implemented` row must name a provider, a verifier, documentation and a
provenance; an `unsupported` row must name who owns that absence. Deliberate
absence is recorded rather than left out, so the generated
[capability matrix](reference/capability-matrix.md) can distinguish "we do not
do this here" from "nobody has considered it".

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
| `values` | The permitted values of a `value` option | a regex alternation, or `-` |
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
  exception because it is a transient control.
- Packages are compared with the files that install them, in both directions:
  a package a row declares must be requested by that capability's installers,
  and every entry of a `*packages=(...)` array in an installer must be owned
  by some capability on that platform.
- Conflicts must be declared on both rows of a pair.

## To add or change a capability

1. Add or update its rows for every relevant platform. Record intentional
   absence with `status=unsupported`; do not imply cross-platform parity.
2. Keep one package owner per platform. Baseline and optional package lists
   must not both own the same package. A package two independently selectable
   capabilities each install on their own is the one exception, and it is
   listed explicitly in `./scripts/validate-capabilities.py` with its reason.
3. Give it a row in `config/install-options.tsv` if it has a `cli_flag`, and
   add the installer implementation and verifier before marking it
   `implemented`.
4. Add focused positive and negative tests, then run `./scripts/lint.sh` and
   `./scripts/test.sh`. Lint runs every validator and every generator in
   `--check` mode, so a manifest change that was not regenerated fails there;
   regenerate with `./scripts/render-capability-matrix.py`,
   `./scripts/render-installer-options.py` and
   `./scripts/render-action-reference.py`.

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
`platforms/<platform>/scripts/verify.sh` to mention that capability in the
file; `base` is exempt, because a platform verifier is about the baseline from
its first line. Where the section that performs the check does not name the
capability in its own code, mark it with a one-line `# verifies: <capability>`
comment in the section header. Separators are normalized when the file is
searched, so `dotnet-debug` is also satisfied by `check_easy_dotnet_debugger`.

The check is deliberately shallow: it cannot prove a check is correct, only
that a verifier declared for a capability says something about it. A verifier
that never mentions the capability it is declared for verifies nothing, and a
selected profile then passes verification unconditionally — which is exactly
what the README's "what is not verified is said to be not verified" forbids.

## Fedora command-provider closure

`config/fedora-command-providers.tsv` closes the narrower bootstrap boundary
for the Fedora workstation and official Fedora WSL profiles. It maps each
native command used by bootstrap, installation, or base/Sway verification to
one owning capability and provider, and classifies availability as:

- `bootstrap-prerequisite`: required before the installer can mutate the host;
- `supported-base`: guaranteed by the documented supported Fedora image but
  still checked before mutation;
- `baseline-package`: installed by exactly one capability package owner before
  the command is used;
- `repository-file`: installed or linked from one named file in this checkout.

The table does not duplicate language-runtime or repository-script ownership.
Those remain with mise, Mason, Stow, and the capability manifest. Run
`./scripts/validate-fedora-dependency-closure.py` after changing either Fedora
baseline, the Sway packages, or their command requirements.
