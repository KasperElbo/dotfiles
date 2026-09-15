# Verification

Run:

```bash
./platforms/fedora/scripts/verify.sh
```

The verifier checks:

- Fedora security baseline: SELinux enforcing, firewalld active, Secure Boot
  state (always, independent of `--hardening`)
- required core commands
- Stow-managed links
- machine-local theme state
- required theme assets
- derived Ghostty/Delta/tmux theme overrides
- Git local configuration
- mise configuration and commands
- expected Mason editor tooling and warnings for untracked Mason packages
- Neovim startup/version
- optional opam switch, compiler, and OCaml Platform tools
- optional LaTeX toolchain when the `latex` capability was selected (`biber`,
  `latex`, `latexindent`, `latexmk`, `lualatex`, `pdflatex`, `xelatex`), and a
  warning when TeX is present without it
- Catppuccin tmux installation/version
- optional ASUS hardware profile, drivers, services, and Secure Boot state
- optional Fedora VM-host backend, KVM, libvirt, network, and storage validation
- optional Fedora VM-guest detection, agents, channels, and network route
- optional Fedora security-hardening profile settings (see
  [the hardening profile guide](../profiles/hardening.md))
- optional AI-assisted development profile: Claude Code/Codex/Herdr/GNHF/
  backpass PATH ownership, FirstMate's clone, and Treehouse/No Mistakes
  (see [the AI profile guide](../profiles/ai.md)) — and confirms none of
  it is present when the profile
  was not selected
- nested Git repositories
- obvious generated junk files

Missing essential components are failures. Optional/editor-specific omissions may be warnings.

Validate every tracked shell script and sourced shell fragment with Bash and
ShellCheck:

```bash
./scripts/lint.sh
```

The lint command supplies the Bash dialect for source-only fragments and
resolves sourced libraries relative to each script. It requires `shellcheck`
to be available in `PATH`.

Before opening a pull request, run the same read-only validation used by CI:

```bash
./scripts/lint.sh
./scripts/test.sh
git diff --check
```

The bootstrap harness covers Secure Boot helpers, power-profile service
handling, installer option validation and dry-runs, fresh and repeated local
setup, legacy Git identity migration, developer-tool ownership invariants, and
preservation of unrelated user files and symlinks. It validates the optional
OCaml profile's idempotency, switch state, and manager boundaries without
downloading a compiler. It also exercises GA402XZ and GA402RK hardware
preflights, fail-before-mutation behavior, and
representative package and service flows through command mocks.
The guest harness additionally proves that bare metal and unsupported
hypervisors fail before package mutation, no ASUS/NVIDIA, power, bridge, or
NetworkManager command is issued, and repeated guest setup preserves stable
local state.
The macOS harness validates the Bash 3.2-compatible root bootstrap and its
modern-Homebrew-Bash re-exec boundary, exact argument forwarding, empty
system/verifier argument cases, dry-run options, Homebrew versus mise ownership,
AeroSpace/Sway-equivalent bindings, the wrapped 3×3 workspace helper,
reversible defaults, the macOS-native VimTeX PDF-viewer override, and the
absence of yabai/skhd.

Every integration-style test uses temporary home, XDG, OS-release, and DMI
state. Package managers, firmware tooling, and service commands are either
blocked or mocked, so the harness never installs packages, enrolls keys,
changes real services, or writes to the user's configuration.

GitHub Actions runs the full repository suite in a Fedora 44 container and the
focused macOS profile/lint checks on a macOS 26 arm64 runner for every pull
request and every push to `main`; Windows helpers run on a Windows runner. The
workflows install validation dependencies in their ephemeral environments, but
never perform a workstation install or change firmware, Secure Boot, MOK
enrollment, GPU/MUX settings, macOS preferences, services, or battery limits.
