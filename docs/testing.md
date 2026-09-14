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
| Apple Silicon macOS | A GitHub-hosted `macos-26` Apple Silicon runner executes the real bootstrap/install path, verifier, idempotent rerun, then an OCaml/defaults/theme state transition. | GitHub's image is disposable and real macOS/arm64, but it is not a factory-fresh Mac and cannot grant interactive Accessibility/Tailscale approvals. Those remain manual assurance. |
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
