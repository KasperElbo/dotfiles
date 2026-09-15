# Capability and provider contract

`config/capabilities.tsv` is the authoritative inventory of supported and
intentionally unsupported capabilities. Each row assigns one provider for a
capability on a platform/profile and records its CLI contract, dependencies,
conflicts, packages, Stow packages, verifier, local state, documentation, and
provenance classification.

To add or change a capability:

1. Add or update its rows for every relevant platform. Record intentional
   absence with `status=unsupported`; do not imply cross-platform parity.
2. Keep one package owner per platform. Baseline and optional package lists
   must not both own the same package.
3. Add the installer implementation and verifier before marking it
   `implemented`.
4. Add focused positive and negative tests, then run
   `./scripts/validate-capabilities.py`, regenerate the support table with
   `./scripts/render-capability-matrix.py` and the option reference with
   `./scripts/render-installer-options.py`, then run `./scripts/lint.sh`, and
   `./scripts/test.sh`. `./scripts/validate-capabilities.py` also checks this
   manifest against `config/install-options.tsv`: a capability that owns a
   `cli_flag` needs a persistent option on the same platform whose `on_flag`
   is that flag, and the two defaults must agree — `enabled` is `true`,
   `disabled` is `false` (`inherit` for a tristate, `-` for a value option),
   and `auto` is `auto`. It names the platform and the option when they
   disagree, so changing a default in one manifest alone fails lint. A flag
   that controls one invocation rather than the machine has no option row at
   all; `--dev-workflows` is the only such flag today and the validator lists
   it as an explicit exception.

`config/capabilities.tsv` records which capability owns a provider and
packages. Its companion, `config/network-sources.tsv`, records where each
network source comes from, its provenance tier, privilege level, integrity
mechanism, update cadence, and rollback strategy. Together they are the
authoritative source/ownership model; see
[supply-chain.md](supply-chain.md) and the generated
[network-source inventory](supply-chain-sources.md). A capability whose
provider reaches the network must have its sources registered there, and
`./scripts/lint.sh` fails if one is missing.

`config/actions.tsv` is the third manifest in this family. It owns the
repository's user-facing actions — keyboard bindings, status-bar clicks, shell
helpers and editor mappings — with the same rules: one authoritative row per
action, an explicit record of what is deliberately absent, and mechanical
validation in both directions by `./scripts/validate-actions.py`. The full
reference in [reference/keybindings.md](reference/keybindings.md) is generated
from it; the printable cheat sheets are checked against it.

The manifest is declarative ownership metadata. It deliberately does not
generate package-manager commands or replace the independently useful
component installers.

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
