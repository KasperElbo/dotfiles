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
   `./scripts/render-capability-matrix.py`, then run `./scripts/lint.sh`, and
   `./scripts/test.sh`.

`config/capabilities.tsv` records which capability owns a provider and
packages. Its companion, `config/network-sources.tsv`, records where each
network source comes from, its provenance tier, privilege level, integrity
mechanism, update cadence, and rollback strategy. Together they are the
authoritative source/ownership model; see
[supply-chain.md](supply-chain.md) and the generated
[network-source inventory](supply-chain-sources.md). A capability whose
provider reaches the network must have its sources registered there, and
`./scripts/lint.sh` fails if one is missing.

The manifest is declarative ownership metadata. It deliberately does not
generate package-manager commands or replace the independently useful
component installers.
