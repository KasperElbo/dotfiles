# Verification and installation testing

The repository deliberately separates **fast mocked/contract evidence** from
**real-environment installation evidence**. A green mocked suite is not treated
as proof that a clean machine can install, survive a new login, or converge on
a second run.

## Fast PR validation

`./scripts/test.sh` is the normal aggregate runner. It:

- preflights the normal Linux aggregate toolchain before the default suite set;
- runs independent suites to completion by default;
- reports passed, failed, and skipped suites in one final summary;
- exits non-zero when any required suite fails;
- accepts `--fail-fast` for local debugging;
- accepts explicit suite paths for targeted debugging without requiring
  unrelated aggregate-only tools.

`DOTFILES_TEST_REQUIRED_COMMANDS` can be set to request runner-level dependency
preflight explicitly. Missing commands in that list are a **runner error**, not
a skip and never a pass. Individual targeted suites remain responsible for
reporting dependencies specific to themselves.

These tests use isolated homes, strict mocks, disposable directories and
containers where appropriate. Their output is labelled
`mocked/unit/contract evidence` because they do not replace clean-machine tests.

### Shared shell-test contracts

Shell suites should source `tests/lib/test.sh` instead of defining another
temporary-root, assertion, capture, or privileged-command framework. The
library creates per-suite HOME/XDG roots and provides exact-argv stubs for
`sudo`, `dnf`, `apt-get`, `systemctl`, `git`, `curl`, and `mise`. A command is
rejected with status 96 unless the suite explicitly registers its complete
argument vector with `test_stub_allow`.

Stateful behavior remains visible in the owning suite. After the shared stub
has logged and accepted an invocation, it executes an optional handler at
`$TEST_STUB_ROOT/handlers/<command>`. Handlers may model such things as login
shell changes or system/user service state; they do not widen the allow-list.
This keeps command policy centralized while leaving domain fixtures auditable.

### Supply-chain and transition suites

Three suites carry the invariants from the AI/mise/supply-chain workstream:

- `tests/test-supply-chain.sh` validates the network-source registry, proves
  the linter fails closed on a new unregistered `curl`/`wget`/PowerShell
  download, Git clone, or container image, rejects a registry row whose tier
  and integrity mechanism contradict each other, rejects a wildcard used as
  an exact pin, asserts no installer passes `--nogpgcheck` or pipes a
  download into a shell, and exercises the bounded fetch policy (single
  successful attempt, bounded retry on a transient failure, clear terminal
  failure, empty-body rejection, non-HTTPS refusal, digest and shape
  rejection).
- `tests/test-mise-context.sh` copies `tests/fixtures/unrelated-project`,
  whose `.mise.toml` declares a sentinel tool, and runs the real global and
  AI bootstraps from inside it, from a nested directory inside it, from
  `$HOME`, and from the dotfiles checkout. The resolved tool set must be
  identical every time and must never contain the sentinel. The fixture
  first proves it *can* see the sentinel without isolation, so the test
  cannot pass vacuously.
- `tests/test-ai-transitions.sh` walks the full optional-component matrix:
  fresh core-only install, add one component, no-op rerun, full install,
  rerun omitting an installed component, dry-run preview, declined removal,
  explicit removal, a removal refused because the target was user-modified,
  an enabled-but-missing component, a disabled-but-present component, an
  interrupted transition and its recovery, and a lost state file. Each step
  asserts both the profile state and the filesystem.

### Installer lifecycle repeatability

`tests/test-install-rerun.sh` owns the `./install.sh --rerun` contract. It
records a real selection by parsing the installer's own dry-run output, so the
fixtures cannot drift from the option contract, and then asserts the round trip
(the reconstructed arguments must resolve to the identical record), the
last-known-good invariant (a failed, cancelled, verifier-failed or dry-run
attempt never replaces the remembered configuration), that transient execution
controls are neither stored nor replayed, the focused refusals for missing,
interrupted, corrupt, unsupported, pre-#210 and removed-option state, that
configuration-changing options are rejected alongside `--rerun`, and that no
stored command text is ever executed. Fedora, Fedora WSL, macOS and Parrot CTF
each get a round-trip fixture, and the persistent-option manifest is checked
against `config/capabilities.tsv`.

`tests/test-ai-profile.sh` additionally covers the staged-installation
failure modes: a failing `curl` that a piped consumer would have reported as
success, an empty body, markup instead of a script, a digest mismatch, and an
installer that runs but produces the wrong target.

### Platform capability suites

- `tests/test-ocaml-verification.sh` fixes one fact per case about a machine
  with a mocked opam and asserts the verdict `common/verify-ocaml.sh` reaches:
  healthy, unselected, selected-but-never-installed, missing opam, missing
  switch, wrong selected switch, wrong compiler, missing opam-managed tool,
  an opam outside the platform's native prefix, a missing or unparsable shell
  hook, a switch that cannot compile, a compiler override that round-trips,
  a switch and compiler that disagree, and verification run in the same
  process immediately after installation.
- `tests/test-macos-ai.sh` proves the selection a user typed reaches the
  shared AI installer unchanged, that an unselected profile plans no AI
  mutation, that the AI step is ordered after mise, and that demoting one
  component in the capability manifest rejects exactly that sub-flag while
  the rest of the profile still installs and the demoted component can still
  be removed.
- `tests/test-macos.sh` walks the capability manifest and requires every
  implemented macOS capability to be reachable from help, the parser and a
  dry-run plan, and every unimplemented one to declare no flag.

## Scheduled/manual real-install validation

`.github/workflows/real-install.yml` is intentionally separate from normal PR
validation. It runs on a schedule and can be dispatched manually. Clean-state
jobs use disposable hosted machines, disposable containers, a freshly imported
WSL export, or a reverted VM snapshot so previously installed packages, user
configuration, mise/Mason state, lifecycle state, and login-shell changes do not
silently become test fixtures.

| Platform class | Automated evidence | Remaining gap |
| --- | --- | --- |
| Fedora workstation | A privileged disposable Fedora systemd environment runs the real installer, verifier, a second install, and a theme-state transition. A disposable repository copy injects an invalid DNF package and the **real installer** is required to fail while reaching that package. | A containerized systemd userspace does not emulate firmware, a graphical login, Secure Boot, NVIDIA/AMD hardware, suspend/resume, or a physical GA402XZ. Periodic physical-machine validation remains valuable. |
| Apple Silicon macOS | A GitHub-hosted `macos-26` Apple Silicon runner invokes the public entry point through `/bin/bash` with ordinary PATH lookup restricted to Apple system paths, requires explicit Homebrew Bash discovery/re-exec, and executes the real bootstrap/install path, verifier, idempotent rerun, then an OCaml/AI/defaults/theme state transition. Every AI component the platform advertises is then probed individually on that runner: it must resolve through mise, must not be an Intel-only binary or a Homebrew/global-npm duplicate, and must run a harmless `--version`/`--help`. The remembered selection is finally replayed with `./install.sh --rerun` and reverified, which is what proves the optional AI subcomponents survive the persistent-selection round trip. | GitHub's image is disposable and real macOS/arm64, but it already contains Homebrew. Installing Homebrew itself on a factory-fresh Mac and granting interactive Accessibility/Tailscale approvals remain manual assurance. The AI probe never authenticates anything, so it proves installable and runnable, not logged in. TeX is user-managed on macOS, so the LaTeX workflow is never exercised there. |
| Fedora WSL / Windows boundary | `windows-latest` exercises the Windows bootstrap boundary. The manual self-hosted WSL job imports a fresh distro from a clean Fedora WSL export tar for every run, performs the first install, terminates and relaunches that distro so `/etc/wsl.conf` changes take effect, then runs the independent verifier, idempotent rerun and theme transition before unregistering it. | GitHub-hosted Windows runners do not provide a dependable, reboot-capable Fedora WSL installation. Clean WSL evidence therefore depends on maintaining an immutable clean export on the labelled self-hosted runner. |
| Parrot CTF guest | Scheduled CI confirms Parrot/APT availability and requires the real installer to reject a non-QEMU container specifically at the VM preflight boundary. A manual clean/snapshotted KVM/QEMU guest additionally runs an invalid-package failure-propagation check, install, verify, rerun and theme transition. | GitHub has no hosted Parrot KVM/QEMU guest with the repository's required guest channels/isolation. The container job is explicitly **not** counted as VM evidence. The self-hosted VM must be reverted to its clean snapshot between runs. |

### Self-hosted runner contracts

The optional clean WSL job expects a runner labelled:

```text
self-hosted, Windows, X64, dotfiles-wsl
```

The runner must provide an immutable export tar of a clean Fedora WSL distro at
the path supplied by the `wsl_base_tar` workflow input. The archive must contain
the non-root user named by `wsl_user` with non-interactive `sudo`, networking,
Git, and the normal WSL prerequisites needed by the bootstrap. The workflow
imports that archive under a run-specific distro name and install directory,
clones the selected commit into the distro's Linux filesystem, and performs the
first install. It then explicitly terminates the imported distro and launches it
again before the independent verifier. That restart boundary is part of the
test contract: it proves the installed `[interop] enabled=true` /
`appendWindowsPath=false` policy after WSL has re-read `/etc/wsl.conf`, rather
than merely checking the file written during the original session. The workflow
then runs the idempotent install and selected-state transition before
terminating/unregistering the distro and removing the imported files. Do not
refresh the golden export from a previously provisioned validation run; rebuild
or deliberately update it from a known-clean source instead.

The optional real Parrot VM job expects a runner labelled:

```text
self-hosted, Linux, X64, dotfiles-parrot-vm
```

That runner must itself be the disposable Parrot Security Edition KVM/QEMU
guest expected by the profile, including the normal guest-agent/SPICE channels.
Revert its VM snapshot after each validation run; do not preserve `$HOME`, mise,
Mason, package-manager or lifecycle state as a cache. The invalid-package check
uses an isolated HOME and disposable repository copy, but the VM snapshot is
still the authority for clean-machine state.

## Failure-propagation controls

A package manager rejecting a nonsense package only proves package-manager
behavior. Real-install controls therefore mutate a disposable repository copy to
add `dotfiles-package-that-must-not-exist` to the platform package list and run
the actual installer. The control passes only when the installer returns
non-zero **and** its output shows that execution reached the injected package.
This protects the propagation path through the installer rather than merely
proving that DNF/APT reject unknown names.

## Maintenance/release role

Normal pull requests should remain fast and deterministic. The scheduled jobs
are intended to catch failures that mocks routinely miss: first-login PATH
changes, package/repository drift, Neovim/Mason first-bootstrap races, service
activation, and lifecycle state that only diverges after a real installation.

Before a release or after changing bootstrap, login-shell, package-provider,
lifecycle, Neovim bootstrap, VM boundary, or platform-specific installer code,
review the latest real-install run. Where a platform still has an explicit
self-hosted/manual gap, run that platform's manual job or the equivalent clean
machine procedure before treating the release as fully validated.

The capability manifest remains authoritative for what each platform supports;
this document describes **test evidence**, not a second capability matrix.
