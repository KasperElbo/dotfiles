# Generated capability support matrix

Generated from `config/capabilities.tsv`; do not edit this table by hand.

A column is a platform this repository installs, which is not the same as a
platform `./install.sh --platform` accepts: the Windows host is installed by
`platforms/windows/install.ps1` and verified by `platforms/windows/verify.ps1`,
and is answerable to this registry on the same terms as the rest.

A cell reads one of three ways, and the difference matters:

- `✓ <provider>` — supported on that platform, installed and owned by that provider.
- `— <owner>` — deliberately absent, with the named owner of that absence:
  `unsupported` (this repository does not provide it there), `windows-host`
  (the Windows side of a WSL install owns it) or `user-managed` (a person
  installs it themselves).
- `—` alone — not modelled: the manifest has no row for that pair, so this
  repository has taken no position on it either way.

| Capability | Fedora | Fedora WSL | macOS | Parrot CTF | Windows |
|---|---|---|---|---|---|
| `ai` | ✓ `mise` | ✓ `mise` | ✓ `mise` | — unsupported | — |
| `backpass` | ✓ `mise-npm` | ✓ `mise-npm` | ✓ `mise-npm` | — | — |
| `base` | ✓ `dnf+terra` | ✓ `dnf+upstream` | ✓ `homebrew` | ✓ `apt+upstream` | ✓ `wsl` |
| `codex` | ✓ `mise-npm` | ✓ `mise-npm` | ✓ `mise-npm` | — | — |
| `containers` | ✓ `dnf` | ✓ `dnf` | ✓ `homebrew` | — unsupported | — |
| `desktop-tools` | ✓ `dnf+rpmfusion` | — unsupported | — unsupported | — unsupported | — |
| `dev-workflows` | ✓ `repository` | ✓ `repository` | ✓ `repository` | — unsupported | — |
| `dictation` | ✓ `dnf+pinned-rpm` | — windows-host | ✓ `upstream-dmg` | — unsupported | ✓ `scoop-extras` |
| `dotnet-debug` | ✓ `mise-easydotnet` | ✓ `mise-easydotnet` | ✓ `mise-easydotnet` | — unsupported | — |
| `firstmate` | ✓ `mise+upstream-scripts` | ✓ `mise+upstream-scripts` | ✓ `mise+upstream-scripts` | — | — |
| `gnhf` | ✓ `mise-npm` | ✓ `mise-npm` | ✓ `mise-npm` | — | — |
| `hardening` | ✓ `dnf` | — unsupported | — unsupported | — unsupported | — |
| `hardware` | ✓ `dnf+copr` | — unsupported | — unsupported | — unsupported | — |
| `kde` | ✓ `dnf+upstream-theme` | — unsupported | — unsupported | — unsupported | — |
| `latex` | ✓ `dnf` | ✓ `dnf` | — user-managed | — unsupported | — |
| `ocaml` | ✓ `dnf+opam` | ✓ `dnf+opam` | ✓ `homebrew+opam` | — unsupported | — |
| `sway` | ✓ `dnf` | — unsupported | — unsupported | — unsupported | — |
| `tailscale` | ✓ `dnf-tailscale` | — user-managed | ✓ `homebrew-cask` | — unsupported | — |
| `terminal` | ✓ `base` | — windows-host | ✓ `base` | ✓ `repository+upstream-font-only` | ✓ `scoop-noctty` |
| `vm-guest` | ✓ `dnf` | — | — | ✓ `apt` | — |
| `vm-host` | ✓ `dnf` | — | — | — unsupported | — |
