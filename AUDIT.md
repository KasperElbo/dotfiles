# Repository audit: KasperElbo/dotfiles

**Audited revision:** `d02ec77` (working tree at audit time)
**Note on baseline:** `origin/main` was at `bf3cffb`, four commits ahead, during this
audit. That delta touches `README.md`, `common/install-ai.sh`, `common/verify-ai.sh`,
`nvim-lazyvim/.config/nvim/lazy-lock.json` and `tests/test-ai-profile.sh`. Findings
against the AI profile were re-checked against `origin/main` and are annotated where
that delta already changes the picture. Everything else was audited at `d02ec77` and is
unaffected.

**Scope:** implementation and documentation. Focus areas requested: maintainability,
correctness and completeness of the total solution; division of responsibility between
package managers and installers; robustness of the installation process; robustness of
the tests and verifications; cross-platform discrepancies; completeness of the cheat
sheets.

---

## 1. How this audit was carried out, and what that means for trust

Three independent methods were used, and findings are labelled by which one supports
them, because that determines how much you should trust each one.

| Method | What it produced |
|---|---|
| **Executed** | Commands actually run against the repository in a container: `scripts/lint.sh`, `scripts/test.sh`, `setup-local.sh` run twice and byte-compared, `stow.sh` against a conflicting target, `install.sh --help`, `nvim --headless` exit-code probes, a shell-option probe. |
| **Read and cross-checked** | Four exhaustive inventories built by dedicated agents (full option matrix across five installers; package-manager ownership; every repo-defined keybinding versus every documented one; test and verify coverage), then spot-verified against source. Every inventory claim I checked held up. |
| **Audited** | Eight per-dimension audits, each producing findings with file and line evidence. The highest-severity ones were then re-verified by me directly in the files. |

**Coverage is uneven, deliberately stated.** Eight dimensions received a full deep audit
(installer core, the three non-default platform installers, cross-platform parity,
package-manager boundaries, installation robustness, verification scripts, test suite,
shell configuration). Six received a lighter pass driven by the inventories plus targeted
reading rather than a dedicated deep audit (theme system, Neovim and Mason, security and
hardening, README accuracy, cheat sheets, Windows). Where a chapter is based on the
lighter pass, it says so. Nothing in this report is included unless it is anchored to
text in the repository, and several plausible-looking claims were dropped during
verification because the code disproved them.

**Two corrections to my own working notes**, recorded because they show the failure mode
this kind of review is prone to. I first read `scripts/stow.sh` as exiting 0 on a stow
conflict; it exits 1, and my test had piped the output so `$?` was `tail`'s. I also first
read `set -o` output suggesting `errexit` stayed off after sourcing the shared library; a
behavioural probe showed it is on, and the flag readout was misleading because it ran
inside a command substitution. Both original readings were mine, not the repository's.

---

## 2. Overall assessment

This is a well-built repository, considerably more disciplined than most personal
dotfiles. That is worth stating plainly before the findings, because the findings are
numerous and would otherwise give a misleading impression.

**Genuine strengths, verified not assumed:**

- **`scripts/lint.sh` passes cleanly** across all 143 tracked shell files with
  `shellcheck -x -P SCRIPTDIR -s bash`. That is a real and unusual bar for a repository
  this size, and it is enforced in CI on two platforms.
- **`setup-local.sh` is byte-identically idempotent.** Run twice into a fresh HOME, the
  complete file and symlink set and the SHA-256 of every file are identical, and the
  second run correctly reports "Keeping existing theme preference" rather than
  recreating state. This is the hardest part of an installer to get right.
- **Option validation is thorough and tested.** Mutually exclusive and dependent flags
  are genuinely rejected (`--vm-host` with `--vm-guest`, `--secure-boot` without
  `--hardware`, every AI sub-option without `--ai`, out-of-range `--charge-limit`), and
  `tests/test-installer-options.sh` covers 15 of these cases.
- **A stow conflict does not destroy user data.** A pre-existing real `~/.zshenv` is
  preserved byte-for-byte, stow refuses, and the installer aborts.
- **`platforms/windows/install.ps1` is well-formed PowerShell**: `Set-StrictMode -Version
  Latest`, `$ErrorActionPreference = 'Stop'`, a proper `[CmdletBinding()]` param block
  with `ValidatePattern`, comment-based help, and a `-DryRun` switch.
- **The package-manager boundaries are consciously policed in places.**
  `install-terra.sh:29` passes `--disablerepo="copr:copr.fedorainfracloud.org:jdxcode:mise"`
  specifically to prevent a second DNF-level owner of `mise`. Someone thought about this.

**What a maintainer should worry about most, in order:**

1. **The macOS fresh-install path runs under an interpreter nobody tests.** This is the
   only finding rated critical, and two independent audits reached it separately.
2. **The verification scripts are the weakest load-bearing component.** They are what
   tells you the machine is correctly set up, and several of their checks cannot fail.
   A verify script that passes on a broken install is worse than no verify script,
   because it converts an unknown into a false assurance.
3. **The test suite largely validates shell source text, not behaviour.** A green run
   proves the installers still contain certain strings. Two tests were proven here to be
   structurally incapable of failing.
4. **One missing package (`jq`) causes three separate defects**, including a documented
   feature that hard-fails and a verify script that silently passes without checking
   anything. This is the clearest illustration of the parity problem: the same baseline
   is assembled independently per platform with nothing reconciling the lists.
5. **There is no lifecycle beyond install.** No update, no uninstall, no rollback, no
   record of which revision a machine was built from.

The findings are, I think, proportionate: the repository's ambitions are high (five
platforms, a dozen optional profiles, live theming, a reproducibility claim), and most
findings are the cost of that ambition being pursued without a mechanism to keep the
platforms reconciled.

---

## 3. Findings index

Severity: **critical** breaks a fresh install, loses data, or opens a real security hole.
**high** a documented feature does not work, a platform is silently degraded, or a test or
verify gives a false pass. **medium** a real correctness or maintainability problem.
**low** and **nit** below that.

| ID | Sev | Finding | Support |
|---|---|---|---|
| [F-01](#f-01) | critical | macOS bootstrap expands empty arrays under `set -u` while running on system Bash 3.2 | Read + CI evidence |
| [F-02](#f-02) | high | `jq` is absent from the Fedora and Fedora WSL baseline, breaking `--firstmate` against an explicit README promise | Executed |
| [F-03](#f-03) | high | `verify.sh` reports a **dangling** stow symlink as verified, on all four platforms | Executed |
| [F-04](#f-04) | high | `tests/test-neovim-first-launch.lua` can never fail the suite | Executed |
| [F-05](#f-05) | high | The rootless Podman API socket check calls `pass` in both branches | Read |
| [F-06](#f-06) | high | `verify-tailscale.sh` passes without ever determining Tailscale's state | Read |
| [F-07](#f-07) | high | macOS never sets the Zsh login shell, but its verifier hard-fails unless it is exactly `/bin/zsh`, and the README claims it does | Executed |
| [F-08](#f-08) | high | macOS installs the OCaml profile with no verification of it whatsoever | Read |
| [F-09](#f-09) | high | `docs/macos.md` documents a LaTeX workflow macOS cannot install | Read |
| [F-10](#f-10) | high | The Parrot CTF guest stows the full LazyVim and Mason config without provisioning it | Read |
| [F-11](#f-11) | high | `wsl-open` passes raw Linux paths to `explorer.exe` | Read |
| [F-12](#f-12) | high | Nothing installs a Nerd Font, but the Starship prompt is built from Nerd Font glyphs | Read |
| [F-13](#f-13) | high | `install_via_own_script` pipes `curl` into `sh`, recording a failed download as a successful install | Read |
| [F-14](#f-14) | high | Verify scripts' `mise` ownership check passes on any PATH hit | Read |
| [F-15](#f-15) | medium | `common/lib/common.sh` silently forces `errexit` and `pipefail` onto 13 verify scripts that deliberately opted out | Executed |
| [F-16](#f-16) | medium | `--dry-run` never reaches any of the 11 sub-scripts that implement it | Executed |
| [F-17](#f-17) | medium | `scripts/test.sh` aborts on the first failure with no summary and no indication that tests were skipped | Executed |
| [F-18](#f-18) | medium | `tests/test-local-state.sh` depends on git history depth and fails silently on a shallow clone | Executed |
| [F-19](#f-19) | medium | A stow conflict is discovered only after every package and privileged change is applied, with no preflight and no documented remedy | Executed |
| [F-20](#f-20) | medium | `verify-hardening.sh` reports its own core artifacts with `warning`, so it exits 0 when hardening has been reverted | Read |
| [F-21](#f-21) | medium | Eight of twelve assertions in `tests/test-sftp-baseline.sh` cannot fail | Executed |
| [F-22](#f-22) | medium | No network operation anywhere has a retry or a timeout | Read |
| [F-23](#f-23) | medium | No privilege preflight: `sudo ./install.sh` installs 25 packages before aborting | Read |
| [F-24](#f-24) | medium | No ERR trap, so a mid-run failure of a 24-step privileged installer says neither which step failed nor whether re-running is safe | Read |
| [F-25](#f-25) | medium | The installer's last step overwrites the theme preference `setup-local.sh` just promised to preserve | Read |
| [F-26](#f-26) | medium | `--no-latex` does not suppress the interactive LaTeX prompt | Read |
| [F-27](#f-27) | medium | The `--workflows` / `--smoke-test` capability has two names, exists on two platforms, and is absent from Fedora | Executed |
| [F-28](#f-28) | medium | `scripts/test-dev-workflows.sh` is production code living in the test directory, run by no CI job | Executed |
| [F-29](#f-29) | medium | macOS prepends coreutils `gnubin` to PATH, shadowing Apple's tools, and its own comment and docs claim the opposite | Read |
| [F-30](#f-30) | medium | The Homebrew installer is fetched from a moving `HEAD` ref with no checksum | Read |
| [F-31](#f-31) | medium | Documented project-local CSharpier formatting cannot resolve | Read |
| [F-32](#f-32) | medium | PATH is rebuilt without deduplication outside macOS | Read |
| [F-33](#f-33) | medium | Nothing pins any executable the repository installs | Read |
| [F-34](#f-34) | medium | Every interactive shell start runs four unconditional `eval` initialisations and an uncached `compinit` | Read |
| [F-35](#f-35) | medium | 13 verify scripts each redefine `pass`/`fail`/`warning` with five different contracts | Read |
| [F-36](#f-36) | medium | All 32 shell tests reimplement their own assertions and stubs, in five incompatible fake-`sudo` dialects | Read |
| [F-37](#f-37) | medium | No Windows verify script exists at all | Executed |
| [F-38](#f-38) | medium | No lifecycle beyond install: no update, uninstall, rollback, or installed-revision record | Read |
| [F-39](#f-39) | medium | `docs/cheatsheets/README.md` claims `keybindings.md` is the same content as `common-workflow.tex`; it is a strict superset | Executed |
| [F-40](#f-40) | medium | No rendered cheat sheet carries the LaTeX or Markdown-table bindings | Executed |
| [F-41](#f-41) | medium | 20 repo-defined bindings appear in no cheat sheet and not in `keybindings.md` | Read |
| [F-42](#f-42) | low | `docs/keybindings.md` attributes the shell restart to the `theme` binary; it lives in the Zsh wrapper | Executed |
| [F-43](#f-43) | low | `platforms/macos/install.sh` prints a usage synopsis that installs the wrong platform if followed | Executed |
| [F-44](#f-44) | low | `./install.sh --platform=macos` silently misroutes to Fedora | Read |
| [F-45](#f-45) | low | `confirm()` treats "yes" as no and exits 0 | Read |
| [F-46](#f-46) | low | Parrot reimplements the shared login-shell helper with a hardcoded path and no root guard | Executed |
| [F-47](#f-47) | low | Executable bits are inconsistent across the library files | Executed |
| [F-48](#f-48) | low | Four `scripts/` shims are referenced by nothing at all | Executed |
| [F-49](#f-49) | low | Three files named `theme-state.sh` have three unrelated responsibilities | Executed |
| [F-50](#f-50) | low | No repository LICENSE, and an empty `package-lock.json` stub with no `package.json` | Executed |
| [F-51](#f-51) | medium | macOS and Parrot ship no theme-hooks package, so a flavour switch reloads nothing and no verifier checks theme state | Read |
| [F-52](#f-52) | high | A single failing theme hook aborts the rest of the switch with no diagnostic | Read |
| [F-53](#f-53) | low | macOS records optional-profile state that nothing ever reads | Read |
| [F-54](#f-54) | medium | The four generated Starship flavour files have no drift gate | Executed |
| [F-55](#f-55) | high | `apply-kde-theme.sh` applies Plasma identifiers that `--no-kde` never installed | Read |
| [F-56](#f-56) | medium | `tests/test-cheatsheet-bindings.sh` cannot detect a binding documented nowhere | Read |

---

## 4. Chapter A: the fresh-machine installation path

This chapter covers the requested "robustness of the installation process".

### F-01
**macOS bootstrap expands empty arrays under `set -u` while running on system Bash 3.2**
*critical, correctness. Support: read plus corroborating CI evidence.*

**Evidence.** No shell script in the repository checks its interpreter version:
`grep -rn 'BASH_VERSINFO\|BASH_VERSION' --include='*.sh' .` returns nothing. No script
guards an empty-array expansion: `grep -rn '\[@\]+' --include='*.sh' .` also returns
nothing. Four possibly-empty array expansions sit on the fresh-Mac entry path, all under
`set -euo pipefail`:

- `install.sh:36` `for forwarded_arg in "${forwarded_args[@]}"; do`
- `install.sh:54` `exec "$repo_root/platforms/$platform/install.sh" "${forwarded_args[@]}"`
- `platforms/macos/install.sh:155` `install-system.sh "${system_args[@]}"`
- `platforms/macos/install.sh:201` `verify.sh "${verify_args[@]}"`

Every one of these scripts uses `#!/usr/bin/env bash`. On a fresh Apple Silicon Mac,
before Homebrew exists, that resolves to `/bin/bash`, which macOS still ships as
3.2.57. In Bash before 4.4, expanding an **empty** array under `set -u` is an unbound
variable error. `./install.sh --platform macos` consumes both tokens in the dispatcher
loop and leaves `forwarded_args` empty, so it reaches `install.sh:36` empty.
`system_args` is empty whenever the run is interactive; `verify_args` is empty whenever
no optional profile was selected.

`platforms/macos/scripts/install-system.sh:24-41` is the step that installs Homebrew, and
it correctly runs Homebrew's own installer with `/bin/bash "$installer"`. But that is
downstream of the two scripts above, and it cannot change the interpreter already
executing them.

**Corroborating evidence that this path is untested.**
`.github/workflows/validate.yml:74-93` runs `brew install bash` on the macOS runner and
then invokes both `./scripts/lint.sh` and `./tests/test-macos.sh` explicitly as
`/opt/homebrew/bin/bash ...`. CI therefore never executes any of this repository's shell
code under the interpreter a real fresh Mac uses. The maintainer already treats system
Bash as inadequate for the test harness; the installer entry point has no equivalent
protection.

**Honest limit on this finding.** I could not install Bash 3.2 in the audit container to
demonstrate the abort, so this is a version-dependent hazard established from the
documented Bash 4.4 change plus the unguarded call sites, not an observed crash. The
`mapfile` call at `common/install-neovim-tools.sh:13` is a related Bash 4+ dependency but
is probably safe in practice, because `platforms/macos/install.sh:156` calls
`activate_homebrew_path` before it, so later `#!/usr/bin/env bash` children pick up
Homebrew's Bash 5. The two outermost scripts get no such protection.

**Implementation brief.**
1. Add a version preflight as the first executable statement of `install.sh`, before
   `set -euo pipefail` takes effect on any array expansion:
   ```bash
   if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
     printf 'ERROR: bash >= 4.4 is required (found %s).\n' "$BASH_VERSION" >&2
     printf 'On macOS: run "brew install bash" and re-run with /opt/homebrew/bin/bash ./install.sh\n' >&2
     exit 1
   fi
   ```
   This must be a message a user can act on, not an unbound-variable trace. Note the
   bootstrapping problem it creates on a truly fresh Mac: Homebrew is not installed yet.
   Resolve it by option 2 as well, not instead.
2. Make the entry path Bash-3.2-safe so the preflight is a belt-and-braces measure
   rather than a hard gate. Replace every possibly-empty expansion on the entry path with
   the guarded form `${arr[@]+"${arr[@]}"}`, at `install.sh:36`, `install.sh:54`,
   `platforms/macos/install.sh:155` and `platforms/macos/install.sh:201`. Audit the rest
   of `install.sh` and `platforms/macos/install.sh` for the same pattern; do not change
   the deeper scripts, which run after `activate_homebrew_path`.
3. In `.github/workflows/validate.yml`, add a step to the `macos` job that runs the
   dispatcher under **system** Bash specifically, before `brew install bash`:
   `/bin/bash ./install.sh --platform macos --dry-run` and
   `/bin/bash ./install.sh --platform macos --help`. This is the check that would have
   caught the defect, and it costs seconds.
4. Document the Bash requirement in the README's macOS quick-start section next to the
   `xcode-select --install` instruction.

**Acceptance.** The new CI step passes. A new `tests/test-macos-bash-compat.sh` asserts
that `install.sh` contains a `BASH_VERSINFO` guard and that no line in `install.sh` or
`platforms/macos/install.sh` matches `"\$\{[a-z_]+\[@\]\}"` without the `+` guard form.

---

### F-02
**`jq` is absent from the Fedora and Fedora WSL baseline, breaking `--firstmate` against an explicit README promise**
*high, completeness. Support: executed.*

This one missing package causes three separate defects, and it is the clearest example of
the parity problem described in Chapter C.

**Evidence.**
`common/install-ai.sh:326-329`, inside the `--firstmate` branch:
```bash
require_command gh
require_command tmux
require_command jq
require_command curl
```
`require_command` is `common/lib/common.sh:114`, which calls `die` on failure.

`jq` appears **zero** times in either baseline package list, verified by
`grep -c '^\s*jq\s*$'`:
- `platforms/fedora/scripts/install-system.sh` -> 0
- `platforms/fedora-wsl/scripts/install-system.sh` -> 0

On Fedora, `jq` is installed by exactly one script:
`platforms/fedora/scripts/install-sway.sh:17`, inside the optional Sway profile.

`README.md:2344` states the opposite: "Requires `gh`, `tmux`, and `jq` (all already
installed by the base profile);". `README.md:2560` repeats the assumption.

Meanwhile macOS installs `jq` unconditionally (`platforms/macos/Brewfile:13`) and Parrot
installs it unconditionally (`platforms/parrot-ctf/scripts/install-system.sh:26`).

**Consequences.**
1. `./install.sh --ai --firstmate` on Fedora or Fedora WSL dies with "Required command
   not found: jq", late in the run, after all package installation and stowing.
   With `--sway` it works. The README says it always works.
2. F-06 below: `verify-tailscale.sh` needs `jq` and silently passes without it.
3. A parity asymmetry with no stated rationale: two platforms treat `jq` as baseline,
   one gates it behind an unrelated desktop profile, and the fourth (WSL) omits it.

**Implementation brief.**
1. Add `jq` to the baseline package array in `platforms/fedora/scripts/install-system.sh`
   (the array beginning around line 10) and in
   `platforms/fedora-wsl/scripts/install-system.sh` (around line 12), preserving each
   file's existing alphabetical ordering.
2. Remove `jq` from `platforms/fedora/scripts/install-sway.sh:17` so a single owner
   remains. Confirm no other Sway-only consumer depends on it being installed there.
3. Update `README.md:2647`'s Fedora/DNF ownership list to include `jq`. Do not change
   `README.md:2344`; adding the package makes that sentence true, which is the intent.
4. Extend `platforms/fedora/scripts/verify.sh` to assert `jq` is present in the baseline
   tool checks alongside its existing `command -v` checks.

**Acceptance.** Add to `tests/test-mocked-installs.sh` an assertion that the captured
`dnf install` command log for a plain `./install.sh --non-interactive --dry-run`-equivalent
mocked run contains `jq`. Add to `tests/test-ai-profile.sh` an assertion that `jq` appears
in the Fedora and Fedora WSL baseline package lists, so the `require_command jq` in
`install-ai.sh` can never again outrun the baseline. A cheap structural version:
```bash
for f in platforms/fedora/scripts/install-system.sh platforms/fedora-wsl/scripts/install-system.sh; do
  grep -qE '^\s*jq\s*$' "$f" || fail "$f must install jq (required by install-ai.sh --firstmate)"
done
```

---

### F-13
**`install_via_own_script` pipes `curl` into `sh`, recording a failed download as a successful install**
*high, security and correctness. Support: read.*

**Evidence.** `common/install-ai.sh:319` is the only `curl`-into-shell in the repository:
```bash
sh -c "curl --fail --show-error --silent --location '$script_url' | sh"
```
The `curl` flags are good: `--fail` and `--location` are both present. The defect is the
pipeline. Because the failure of the left-hand side of a pipe is invisible without
`pipefail`, and because the whole thing is wrapped in `sh -c` (which does not inherit the
calling script's `pipefail`), a 404, a TLS failure, a proxy error page or a truncated
transfer produces an empty or partial stream that `sh` consumes and exits 0 on. The
profile then records the tool as installed.

**Implementation brief.**
1. Replace the pipe with a download-verify-execute sequence, following the pattern
   `platforms/macos/scripts/install-system.sh:29-41` already uses for Homebrew:
   ```bash
   installer="$(mktemp -t dotfiles-vendor.XXXXXX)"
   trap 'rm -f -- "$installer"' RETURN
   curl --fail --show-error --silent --location --retry 3 --retry-delay 2 \
     --max-time 120 --proto '=https' --tlsv1.2 "$script_url" --output "$installer"
   [[ -s "$installer" ]] || die "Vendor install script was empty: $script_url"
   sh "$installer"
   ```
2. Pin the vendor scripts to a tag or commit rather than a moving ref where the vendor
   offers one, and record the expected SHA-256 next to the URL so a substituted script is
   detected. Where no pinned artifact exists, say so in a comment so the exposure is
   deliberate and visible.
3. Apply the same treatment to `platforms/macos/scripts/install-system.sh:34` (F-30) and
   to the `curl` calls at `platforms/fedora-wsl/scripts/install-system.sh:61,80` and
   `platforms/parrot-ctf/scripts/install-system.sh:72`.

**Acceptance.** Add a case to `tests/test-ai-profile.sh` that stubs `curl` on PATH to exit
non-zero and asserts the installer aborts non-zero rather than reporting the tool
installed. Add a second case where the stub exits 0 but writes an empty file, asserting
the `-s` check fires.

---

### F-16
**`--dry-run` never reaches any of the 11 sub-scripts that implement it**
*medium, maintainability. Support: executed.*

**Evidence.** `platforms/fedora/install.sh` references `$dry_run` at exactly three lines:
declaration at `:29`, assignment at `:293`, and one use at `:391`. At `:391` it prints a
hand-maintained heredoc plan and exits. It never forwards `--dry-run` to any step.

Eleven sub-scripts implement `--dry-run`, and six also implement `--validate`, none of
which the top-level installer can reach:

| Script | Unreachable options |
|---|---|
| `common/install-ai.sh` | `--dry-run --validate` |
| `platforms/fedora/scripts/install-containers.sh` | `--dry-run --validate` |
| `platforms/fedora/scripts/install-hardening.sh` | `--dry-run --validate` |
| `platforms/fedora/scripts/install-tailscale.sh` | `--dry-run --validate` |
| `platforms/fedora/scripts/install-vm-guest.sh` | `--dry-run --validate` |
| `platforms/fedora/scripts/install-vm-host.sh` | `--dry-run --validate --smoke-test` |
| `platforms/fedora/scripts/install-desktop-tools.sh` | `--dry-run` |
| `platforms/fedora/scripts/install-asus-hardware.sh` | `--dry-run` |
| `platforms/fedora-wsl/scripts/install-containers.sh` | `--dry-run --validate` |
| `platforms/fedora-wsl/scripts/configure-interop.sh` | `--dry-run` |
| `platforms/macos/scripts/apply-defaults.sh` | `--restore --dry-run` |

**Why it matters.** `./install.sh --dry-run` is the command the README tells users to run
first, and its output is a hand-written duplicate of the execution order rather than a
projection of it. The two can drift, and nothing compares them. The per-step `--dry-run`
implementations, which would be the accurate source, are dead code from the orchestrator's
perspective. The Fedora WSL plan has already drifted: `platforms/fedora-wsl/install.sh`
lists OCaml and LaTeX after stow, mise and Neovim in the plan (`:246,:260`) but runs them
before (`:388,:396`).

**Implementation brief.** Choose one of two directions; do not leave both mechanisms.

*Option A, recommended: make the plan a projection.* Introduce a step registry in each
platform installer: an array of records, each holding a step label, the script path, the
condition, and the arguments. Have one function iterate it to print the plan and another
iterate it to execute, so the two cannot diverge. Then delete the heredoc at
`platforms/fedora/install.sh:391-...` and forward `--dry-run` to each step so a step's own
plan output is what the user sees. This is more work and is the correct answer for a
five-platform installer.

*Option B, cheaper: pin the duplicate.* Keep the heredoc but add a test that extracts the
ordered list of script paths from the `--dry-run` output and compares it against the
ordered list of script invocations parsed out of the installer body, failing on any
mismatch. This makes the drift impossible to merge without also making the plan a
second source of truth that must be maintained.

**Acceptance.** For either option, add `tests/test-dry-run-plan-matches-execution.sh`
asserting that for a representative set of flag combinations (bare, `--sway`, `--ocaml
--latex`, `--ai --firstmate`, `--hardware ga402xz --secure-boot`) every script path
printed in the plan is invoked in the body under the same condition, in the same order,
and that no invoked script is missing from the plan. Run it for all four bash platforms.

---

### F-19
**A stow conflict is discovered only after every package and privileged change is applied, with no preflight and no documented remedy**
*medium, robustness. Support: executed.*

**Evidence, from an actual run.** With a pre-existing real file at `~/.zshenv` in a
temporary HOME, `./scripts/stow.sh` produced:
```
==> Stowing zsh
WARNING! unstowing zsh would cause conflicts:
  * existing target is neither a link nor a directory: .zshenv
WARNING! stowing zsh would cause conflicts:
  * existing target is neither a link nor a directory: .zshenv
All operations aborted.
```
Real exit code, captured without a pipe: **1**. The user's file was preserved
byte-for-byte. Both of those are correct behaviour.

The problems are the timing, the partial state and the absence of a remedy. Measured
state after that run:
- `.config/starship/catppuccin-macchiato.toml` -> symlink (stowed)
- `.config/git/config` -> symlink (stowed)
- `.config/zsh/.zshrc` -> **missing** (not stowed)

The package order at `common/stow.sh:28-46` is `bat bin fzf git lazygit nvim-lazyvim
starship tmux zsh` then conditionally `mise` and `ghostty`. A conflict on `zsh` is the
most likely conflict in practice, because a non-pristine Fedora or macOS HOME very often
already has a `~/.zshenv` or `~/.zshrc`, and it lands ninth, after eight packages are
already linked. It leaves `zsh`, `mise`, `ghostty` and every platform package
(`zsh-platform`, `theme-hooks`, `theme-assets`) unstowed. Because
`platforms/fedora/install.sh` runs under `set -euo pipefail`, the remaining install steps
(theme application, mise, Neovim tools, verify) are skipped too. On Fedora this happens
at step 12 of 24, after roughly 25 DNF packages, a login-shell change and any hardware or
hardening work have already been applied.

No recovery affordance exists anywhere in the repository:
`grep -rn 'adopt\|backup' over all non-test shell files` returns **zero** hits, so there is
no `--adopt` path and no backup mechanism. `grep -n -i 'conflict' README.md` returns three
hits, all unrelated (power-profile services at `:1145`, a Codex PATH note at `:2291`, git
rebase at `:3419`). There is no stow-conflict section.

**Implementation brief.**
1. Add a preflight to `common/stow.sh`, before the first real `stow` call. Iterate every
   package with `stow --simulate --no --verbose=1 --target="$HOME" "$pkg"`, collect the
   conflicting target paths from all packages, and if any exist, print them all at once
   and `die` before touching anything. Do the same in each
   `platforms/*/scripts/stow.sh` for the platform package list, or better, factor a
   shared `stow_preflight <target> <packages...>` helper into `common/lib/common.sh` and
   call it from all four.
2. Hoist that preflight so it runs before privileged work. Call it from each platform
   installer immediately after option parsing and before the first
   `install-system.sh` invocation, so the failure costs the user nothing.
3. Give the user a documented way out. Add a `--adopt-existing` flag to `common/stow.sh`
   and the platform installers that moves each conflicting target to
   `~/.dotfiles-backup-<UTC timestamp>/<relative path>` and then stows, printing the
   backup location. Do not use `stow --adopt`, which overwrites the repository copy with
   the user's file and would dirty the working tree.
4. Add a "Stow conflicts on a machine that already has dotfiles" section to the README
   explaining the failure text, where the backup went, and how to re-run.

**Acceptance.** Add `tests/test-stow-conflict.sh` that, in a temporary HOME: creates a
real `~/.zshenv`, runs the platform installer's stow step, and asserts (a) exit is
non-zero, (b) the user's file is unchanged, (c) **no** package was stowed, proving the
preflight ran before any mutation, and (d) the output names `.zshenv` and mentions
`--adopt-existing`. Add a second case asserting `--adopt-existing` relocates the file to a
backup directory and completes.

---

### F-22
**No network operation anywhere has a retry or a timeout**
*medium, robustness. Support: read.*

**Evidence.** `common/lib/common.sh` provides no retry helper. Every network operation in
the repository is a bare single attempt: `dnf install` across all Fedora and WSL install
scripts, `brew bundle` at `platforms/macos/scripts/install-system.sh:47`, `apt-get` in
Parrot, `git clone` at `common/install-ai.sh:337`, `opam init` in `common/install-ocaml.sh`,
`mise install`, the Mason bootstrap, the TeX Live install, and the four `curl` calls at
`common/install-ai.sh:319`, `platforms/fedora-wsl/scripts/install-system.sh:61,80`,
`platforms/parrot-ctf/scripts/install-system.sh:72` and
`platforms/macos/scripts/install-system.sh:34`. None of the `curl` calls passes `--retry`
or `--max-time`.

For a bootstrap whose whole job is to run once on a new machine, often over whatever
network that machine happens to have, a single transient mirror failure aborts the run at
whatever step it hits, with the consequences described in F-24.

**Implementation brief.**
1. Add to `common/lib/common.sh`:
   ```bash
   # retry <attempts> <initial delay seconds> -- <command...>
   retry() {
     local attempts="$1" delay="$2"; shift 2; [[ "$1" == -- ]] && shift
     local n=1
     until "$@"; do
       if ((n >= attempts)); then
         warn "Command failed after $attempts attempts: $*"
         return 1
       fi
       warn "Attempt $n of $attempts failed; retrying in ${delay}s: $*"
       sleep "$delay"; delay=$((delay * 2)); n=$((n + 1))
     done
   }
   ```
2. Convert the call sites in this order, highest value first: the four `curl` calls (also
   adding `--retry 3 --retry-delay 2 --max-time 120`), `git clone`, `mise install`, the
   Mason bootstrap, then the package-manager transactions. Wrap package-manager calls as
   `retry 3 5 -- sudo dnf --assumeyes install "${packages[@]}"`.
3. Do not retry anything non-idempotent. Audit each site before converting;
   `usermod --shell`, `systemctl enable` and the `defaults write` calls are safe to
   retry, and the `curl`-then-execute pattern must retry only the download half.

**Acceptance.** Add `tests/test-retry-helper.sh` asserting `retry` succeeds on the first
attempt, succeeds on the third after two failures, returns non-zero after exhausting
attempts, and calls the command exactly the expected number of times using a counter
file. Add an assertion to `tests/test-mocked-installs.sh` that a `dnf` stub failing once
then succeeding still results in a completed install.

---

### F-23
**No privilege preflight: `sudo ./install.sh` installs 25 packages before aborting**
*medium, robustness. Support: read.*

**Evidence.** `platforms/fedora/install.sh` performs no privilege check before its first
step. `ensure_zsh_login_shell` at `common/lib/common.sh:117-125` does contain a root
refusal:
```bash
[[ "$(id -u)" -ne 0 ]] ||
  die "Refusing to change root's login shell; run the installer as a regular user."
```
but it is reached inside `platforms/fedora/scripts/install-system.sh:40`, which is
**after** `sudo dnf install` of the roughly 25 baseline packages at `:38`. A user who runs
`sudo ./install.sh` therefore gets a full privileged package transaction, then an abort,
leaving the machine changed and the run incomplete.

Separately, `sudo` credentials are never validated up front, so a `--non-interactive` run
can stall indefinitely on a hidden `sudo` password prompt part-way through, which defeats
the purpose of the flag.

**Implementation brief.**
1. Add a `require_unprivileged_user` helper to `common/lib/common.sh` containing the same
   root refusal, and call it from all four platform installers immediately after option
   parsing, before any step runs.
2. Add a `prime_sudo` helper that runs `sudo -v` once up front. In interactive mode this
   prompts at a predictable moment; in `--non-interactive` mode use `sudo -n -v` and
   `die` with a clear message if credentials are not already cached, rather than stalling.
   Call it from the same place, but only when the selected options actually require sudo,
   so a `--dry-run` never prompts.
3. Keep the existing check in `ensure_zsh_login_shell` as defence in depth.

**Acceptance.** Add to `tests/test-installer-options.sh` a case that runs the installer
with a stubbed `id` returning 0 and asserts it aborts non-zero with the root message and
that the mocked `dnf` command log is **empty**, proving nothing was installed first. Add a
case asserting `--non-interactive` with a `sudo` stub that exits non-zero on `-n -v` fails
fast rather than hanging.

---

### F-24
**No ERR trap, so a mid-run failure of a 24-step privileged installer says neither which step failed nor whether re-running is safe**
*medium, robustness. Support: read.*

**Evidence.** `platforms/fedora/install.sh:2` sets `set -euo pipefail` and the file
contains no `trap`. A failure at any of the roughly 24 steps therefore terminates the
script with whatever the failing command last printed and a non-zero status. There is no
summary of which steps completed, no statement of whether re-running is safe, and no way
to resume from the failed step.

This compounds F-19: the most likely failure (a stow conflict at step 12) is exactly the
case where the user most needs to be told what state the machine is in.

Idempotency is in fact good in the parts I could measure. `setup-local.sh` is
byte-identically idempotent, and a second `stow.sh` on a clean tree exits 0. So the
correct answer is almost certainly to promise re-runnability rather than to build
step selection, but that promise has to be made explicitly and then tested.

**Implementation brief.**
1. Add to each platform installer, after option parsing:
   ```bash
   current_step=""
   on_error() {
     local status=$?
     printf '\n\033[1;31mInstallation failed\033[0m during: %s\n' "${current_step:-startup}" >&2
     printf 'Exit status: %d\n' "$status" >&2
     printf 'This installer is safe to re-run; completed steps are skipped or reapplied idempotently.\n' >&2
     printf 'See README.md, "Recovering from a failed installation".\n' >&2
     exit "$status"
   }
   trap on_error ERR
   ```
   Set `current_step="Install Fedora system packages"` and so on before each step. Reuse
   the step labels already written in the `--dry-run` heredoc, which is a further reason
   to adopt the step registry from F-16 so the labels exist exactly once.
2. Add the "Recovering from a failed installation" README section the trap points at:
   what partial state can exist, that re-running is the supported recovery, and the
   specific exception cases (a stow conflict needs the conflicting file dealt with first).
3. Back the re-runnability promise with the test below. Do not make the promise before
   the test exists.

**Acceptance.** Extend `tests/test-idempotency.sh` with a fault-injection case: stub one
mid-sequence step to fail, assert the trap message names that step and states re-running
is safe, then re-run with the stub succeeding and assert the run completes and the final
state matches a clean single run byte-for-byte.

---

### F-25
**The installer's last step overwrites the theme preference `setup-local.sh` just promised to preserve**
*medium, correctness. Support: read.*

**Evidence.** `common/setup-local.sh:123-129` deliberately protects an existing choice:
```bash
if [[ ! -e "$state_dir/theme" ]]; then
  printf '%s\n' "$theme" >"$state_dir/theme"
  info "Created theme preference: $theme"
else
  info "Keeping existing theme preference: $(cat "$state_dir/theme")"
fi
```
I confirmed this works: a second `setup-local.sh` run prints "Keeping existing theme
preference: macchiato".

But `platforms/fedora/install.sh` then runs `~/.local/bin/theme "$theme"` as a later step,
where `$theme` defaults to `macchiato` (`:7`). The same pattern exists at
`platforms/macos/install.sh:189-190`. So a user who is on `mocha` and re-runs the
installer without passing `--theme mocha` is told their preference was kept, and is then
switched to `macchiato` moments later by the same run.

**Implementation brief.**
1. Make the installer's theme step use the persisted value rather than the CLI default.
   Distinguish "the user passed `--theme`" from "the default applied": initialise
   `theme=""` and set `theme_explicit=true` only in the `--theme)` branch. After
   `setup-local.sh` has run, read the effective flavour back from
   `"${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/theme"` and pass that to the `theme`
   command unless `theme_explicit` is true.
2. Apply the identical change to all four platform installers, since all four call
   `setup-local.sh` and then `theme`.
3. Make the `--dry-run` plan print the flavour that will actually be applied, so the
   "Catppuccin flavour:" line in the plan stops being misleading on a re-run.

**Acceptance.** Extend `tests/test-local-state.sh`: set the persisted theme to `mocha`,
run the installer's `setup-local` and theme steps with no `--theme`, and assert the
persisted theme is still `mocha`. Then run with `--theme latte` and assert it becomes
`latte`.

---

### F-26
**`--no-latex` does not suppress the interactive LaTeX prompt**
*medium, correctness. Support: read.*

**Evidence.** `platforms/fedora/install.sh:8` initialises `install_latex="false"`.
`:135-144` sets it true for `--latex` and false for `--no-latex`. The interactive prompt
at `:659` fires whenever `install_latex` is still false and the run is interactive. Since
`--no-latex` leaves it false, an explicit opt-out is indistinguishable from omitting the
flag, and the user is asked anyway. `platforms/fedora-wsl/install.sh:104` has the same
shape. An explicit negative flag that the program then asks about is a correctness bug,
not a cosmetic one: it means `--no-latex` cannot be relied on in a script that is
interactive for other reasons.

**Implementation brief.** Introduce a tri-state. Initialise `latex_choice="unset"`; set it
to `"true"` in the `--latex` branch and `"false"` in the `--no-latex` branch. Gate the
prompt on `[[ "$latex_choice" == "unset" && "$interactive" == "true" ]]`, and resolve
`install_latex` from `latex_choice` afterwards. Audit every other `--no-*` flag in all
four installers for the same defect and apply the same pattern: `--no-kde`, `--no-ocaml`,
`--no-sway`, `--no-hardening`, `--no-desktop-tools`, `--no-containers`, `--no-tailscale`,
`--no-ai` and the AI sub-options, plus macOS `--no-defaults` and `--no-workflows`. Note
that `--no-kde` on Fedora is a genuine tri-state already (default is autodetected from
`command_exists plasmashell` at `:380-385`), so it is the model to follow.

**Acceptance.** Extend `tests/test-installer-options.sh` with a case per negative flag:
run the installer interactively with the flag and a stubbed `read` that would answer yes,
and assert the resulting plan shows the profile disabled and that the prompt string never
appeared in the output.

---

### F-45
**`confirm()` treats "yes" as no and exits 0**
*low, correctness. Support: read.*

**Evidence.** `common/lib/common.sh:72-86`:
```bash
if [[ "$default" == "y" ]]; then
  read -r -p "$prompt [Y/n] " answer
  answer="${answer:-y}"
...
[[ "$answer" =~ ^[Yy]$ ]]
```
The anchored single-character pattern means `yes`, `Y `, or any answer other than exactly
`y` or `Y` is treated as no. Call sites such as `platforms/fedora/install.sh:701` are
written `confirm "Continue with installation?" "y" || exit 0`, so typing the most natural
affirmative answer, "yes", silently aborts the installer with **exit status 0**, which
also means any wrapper script sees success.

**Implementation brief.** Change the test to `[[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]` and
add a symmetric negative match so unrecognised input re-prompts rather than being
silently taken as the negative:
```bash
while true; do
  read -r -p "$prompt $hint " answer
  answer="${answer:-$default}"
  case "$answer" in
    [Yy] | [Yy][Ee][Ss]) return 0 ;;
    [Nn] | [Nn][Oo]) return 1 ;;
    *) warn "Please answer yes or no." ;;
  esac
done
```
Separately, review the `|| exit 0` call sites: a user-initiated cancellation arguably
should exit 0, but an unrecognised answer must not be indistinguishable from one. With the
loop above, cancellation becomes unambiguous.

**Acceptance.** Add `tests/test-confirm-helper.sh` driving `confirm` with `y`, `Y`, `yes`,
`YES`, `n`, `no`, empty (both defaults) and `garbage`, asserting the return code for each
and that `garbage` re-prompts rather than returning.

---

## 5. Chapter B: division of responsibility between package managers

This chapter covers the requested "division of responsibility when it comes to using
different package managers and installers for different purposes". The full ownership
inventory is in Appendix B.

### The state of the boundary

The repository states six design principles, four of which are about ownership. Held
against the code, the picture is mixed rather than bad. Principles 1 and 3 are largely
honoured. Principle 2 is honoured in spirit but the boundary moves per platform.
Principle 4 is the one that does not survive contact with the editor config (F-31).

**The structural problem is not any single misplacement. It is that the same baseline is
assembled independently four times, with nothing reconciling the lists.** Seventeen tools
are installed by a different manager depending on platform, and while most of those are
unavoidable (`ghostty` from Terra on Fedora versus a Homebrew cask on macOS is simply how
those platforms work), the same mechanism silently produces defects when a tool is present
on three platforms and absent on the fourth. F-02 is that failure mode in its purest form,
and it took a documented feature down with it.

Notable deliberate good practice worth preserving: `install-terra.sh:29` passes
`--disablerepo="copr:copr.fedorainfracloud.org:jdxcode:mise"` to stop a COPR from becoming
a second DNF-level owner of `mise`. That is exactly the right instinct, applied once.

### F-14
**Verify scripts' `mise` ownership check passes on any PATH hit**
*high, testing. Support: read.*

**Evidence.** `platforms/fedora/scripts/verify.sh:450` (with the same shape at
`platforms/fedora-wsl/scripts/verify.sh:164` and in the macOS verifier) resolves a
mise-managed tool by falling back to any PATH match rather than requiring that the
resolved binary is the one `mise` reports managing. The consequence is that the check
cannot detect the exact condition it exists to detect: a DNF, Homebrew or APT duplicate
shadowing the mise-owned copy, or a failed `mise install` where a system copy happens to
satisfy `command -v`.

**This is already solved elsewhere in the repository.** `common/verify-ai.sh` on
`origin/main` implements `check_mise_owned`, which compares `command -v "$name"` against
`mise which "$name"` using `shell_paths_match`, and additionally accepts mise's shim path
under `${MISE_DATA_DIR:-$XDG_DATA_HOME/mise}/shims/<name>`. That is the correct
implementation and it exists today.

**Implementation brief.**
1. Move `check_mise_owned` out of `common/verify-ai.sh` into a new shared
   `common/lib/verify.sh` (see F-35, which wants that file to exist anyway).
2. Replace the ownership loop in `platforms/fedora/scripts/verify.sh:438-460`, the
   equivalent in `platforms/fedora-wsl/scripts/verify.sh:164`, and the macOS verifier's
   mise section with calls to the shared helper, iterating the tools declared in
   `mise/.config/mise/config.toml` rather than a hand-maintained list.
3. Keep `common/verify-ai.sh` calling the shared copy so there is one implementation.

**Acceptance.** Add `tests/test-mise-ownership.sh`: build a temporary PATH where a fake
`ripgrep` appears both as a mise shim and as a `/usr/bin` copy ordered first, stub
`mise which` to report the shim, and assert the verifier **fails**. Then reorder so the
shim wins and assert it passes. Both cases must exercise the shared helper.

### F-31
**Documented project-local CSharpier formatting cannot resolve**
*medium, correctness. Support: read.*

**Evidence.** `nvim-lazyvim/.config/nvim/lua/plugins/formatting.lua:7` declares
`cs = { "csharpier" }` for Conform. No installer ever puts a `csharpier` executable on
PATH: it is not in `mason-packages.txt`, not in `mise/.config/mise/config.toml`, not in the
Brewfile, and not in any DNF or APT list. `README.md:3631` and `README.md:2860` document
CSharpier as project-local tooling under principle 4, which is the right policy, but
Conform is pointed at a bare `csharpier` binary rather than at `dotnet csharpier`, so a
project that correctly declares CSharpier as a local `dotnet tool` still cannot be
formatted. Formatting C# therefore fails on every machine this repository builds.

**Implementation brief.** In `formatting.lua`, replace the bare formatter reference with a
custom Conform formatter that invokes the project's local tool:
```lua
formatters = {
  csharpier = {
    command = "dotnet",
    args = { "csharpier", "format", "$FILENAME" },
    stdin = false,
    cwd = require("conform.util").root_file({ ".config/dotnet-tools.json", "*.sln", "*.csproj" }),
    require_cwd = true,
  },
},
```
Confirm the subcommand and argument order against the CSharpier version the project pins;
CSharpier changed its CLI between major versions, so check rather than assume. `require_cwd`
makes the behaviour on a project without CSharpier a clean no-op instead of an error, which
is the correct expression of principle 4. Then state that contract explicitly in the README
section: the editor formats C# only when the repository declares CSharpier as a local dotnet
tool, and the command it runs.

**Acceptance.** Extend `tests/test-neovim-tool-ownership.sh` to assert `formatting.lua`
routes `cs` through `dotnet` and sets `require_cwd`, and to assert no installer manifest
contains a global `csharpier` (pinning principle 4 in both directions). Add a fixture under
`tests/fixtures/dotnet-smoke/` with a `.config/dotnet-tools.json` declaring CSharpier and
extend `scripts/test-dev-workflows.sh --dotnet` to format a file through it.

### F-33
**Nothing pins any executable the repository installs**
*medium, completeness. Support: read.*

**Evidence.** `mise/.config/mise/config.toml` uses floating specifications;
`nvim-lazyvim/.config/nvim/mason-packages.txt` is a bare newline-separated list whose
format has no place to put a version; `platforms/macos/Brewfile` pins nothing; the DNF and
APT lists pin nothing; `common/install-ai.sh` installs via mise with `"latest"`. The one
pinned artifact in the repository is `nvim-lazyvim/.config/nvim/lazy-lock.json`, which pins
Neovim **plugins**.

The README describes the repository as producing a "reproducible" workstation. As it
stands, two installs a month apart produce different toolchains, and the only thing that
would reproduce is the plugin set. That is a defensible engineering choice for a personal
workstation that wants to track upstream, but it is not what the word reproducible means,
and the gap between the claim and the behaviour is the finding.

**Implementation brief.** Pick a position and make the documentation match it. Recommended:
1. Keep runtimes pinned and tools floating, which is the pragmatic split. Pin the language
   runtimes in `mise/.config/mise/config.toml` to exact patch versions (`python = "3.14.x"`,
   the .NET runtime, node) since those are what project builds are sensitive to.
2. Leave CLI tools floating deliberately, and say so.
3. Rewrite the README's reproducibility claim to state precisely what is reproducible: the
   configuration, the plugin set, and the language runtimes; not the CLI tool versions.
4. Add an installed-revision stamp (F-38) so a machine can at least report what it was
   built from.

**Acceptance.** Add `tests/test-pinning-policy.sh` asserting every entry in the `[tools]`
table of `mise/.config/mise/config.toml` that names a language runtime matches an exact
version pattern rather than `latest`, and that the README's reproducibility section
contains the words describing the actual guarantee. This is a policy test, so keep its
allowlist explicit and commented.

### F-29
**macOS prepends coreutils `gnubin` to PATH, shadowing Apple's tools, while its own comment and docs claim the opposite**
*medium, correctness. Support: read.*

**Evidence.** `platforms/macos/stow/zsh-platform/.config/zsh/platform-env.zsh:1-5`
prepends the Homebrew coreutils `gnubin` directory to PATH for every shell. The effect is
that `ls`, `date`, `stat`, `readlink`, `sed` and friends resolve to GNU implementations
with different flags and output formats than the BSD versions macOS scripts and tooling
expect. The file's own comment and `docs/macos.md:66` state that Apple's tools are not
shadowed. They are.

This interacts with a second defect: `platforms/macos/scripts/verify.sh:133` asserts that
`gnubin` is the **first** PATH entry in a login shell, which mise activation in
`zsh/.config/zsh/.zshrc:87-92` makes impossible, so that assertion is unsatisfiable as
written.

**Implementation brief.** Decide the intent, then make code, comment, docs and verifier
agree. Two coherent options:

*Option A, keep GNU tools but stop shadowing.* Remove the `gnubin` prepend. Instead expose
the GNU tools under their `g`-prefixed names, which Homebrew coreutils already installs
(`gls`, `gdate`, `gstat`), and add aliases in `platform.zsh` only for the specific commands
where the GNU behaviour is actually wanted. Update the comment and `docs/macos.md:66` to
describe this. Change `verify.sh:133` to assert the `g`-prefixed tools exist rather than
asserting PATH order.

*Option B, keep shadowing but tell the truth.* Keep the prepend, correct the comment and
`docs/macos.md:66` to state plainly that GNU coreutils shadow the BSD tools for
interactive shells and what that implies, and change `verify.sh:133` to assert `gnubin`
precedes `/usr/bin` rather than that it is first overall, which is both satisfiable and the
property actually intended.

Option A is the better fit for principle 6, preferring upstream behaviour over glue.

**Acceptance.** Extend `tests/test-macos.sh` to assert the verifier's PATH assertion is
satisfiable by constructing the real login-shell PATH order (mise activation included) and
running the check, and to assert that `docs/macos.md` and `platform-env.zsh`'s comment
agree with whichever option was implemented.

### F-30
**The Homebrew installer is fetched from a moving `HEAD` ref with no checksum**
*medium, security. Support: read.*

**Evidence.** `platforms/macos/scripts/install-system.sh:34`:
```bash
curl --fail --location --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
  --output "$installer"
```
then `/bin/bash "$installer"` at `:38` or `:40`. The TLS hardening here is good. The
remaining exposure is that `HEAD` is a moving reference: the script executed is whatever is
on Homebrew's default branch at the moment of install, with no pin and no checksum, and it
runs with the ability to prompt for `sudo`. This is the most externally mutable step on the
fresh-Mac critical path, and it is also the first step, so it precedes any verification.

To be proportionate: this is the officially documented way to install Homebrew, and pinning
it has a real cost, because a stale pinned installer breaks on new macOS releases. The
finding is that the tradeoff is undocumented and unbounded, not that using the vendor
script is wrong.

**Implementation brief.**
1. Pin to a tag and record the expected SHA-256 next to the URL. Verify with
   `shasum -a 256 -c` before executing, and `die` with a message naming the expected and
   actual digests on mismatch.
2. Add `--retry 3 --retry-delay 2 --max-time 120` per F-22, and assert the downloaded file
   is non-empty before executing it per F-13.
3. Add a comment stating the review cadence for the pin and that a macOS major upgrade may
   require bumping it, so the pin does not silently rot.
4. If pinning is judged too costly to maintain, keep `HEAD` but say so explicitly in a
   comment and in `docs/macos.md`'s security section, so the exposure is a decision rather
   than an oversight.

**Acceptance.** Add a case to `tests/test-macos.sh` that stubs `curl` to write a file whose
digest does not match and asserts the installer aborts non-zero without executing it, using
a `bash` stub that records invocation to prove the payload never ran.

---

## 6. Chapter C: cross-platform parity

This chapter covers the requested "discrepancies between what options and tools are being
installed on different platforms". The complete option matrix is Appendix A.

### The shape of the problem

Four Unix platforms plus a Windows host, sharing `common/` but each owning its own
installer, its own package list, its own stow list and its own verifier. There is no
mechanism that reconciles them, so every capability added to one platform is a potential
gap in the other three, and the gaps are invisible until someone runs the combination.
`tests/test-platform-boundary.sh` exists and is the right idea, but it pins a small number
of ownership boundaries rather than asserting a parity matrix.

Some divergence is correct and deliberate: Fedora WSL rejecting `--tailscale` with a
pointer to the host-install policy (`platforms/fedora-wsl/install.sh:164-169`) is a good
example of a boundary that is enforced, explained in the error, and documented. That is the
pattern the other gaps should follow.

**The parity gaps found, and whether each is deliberate:**

| Capability | fedora | wsl | macos | parrot | Deliberate? |
|---|---|---|---|---|---|
| `--latex` | yes | yes | **no** | no | No. Documented for macOS anyway. F-09 |
| `--ocaml` | yes | yes | yes | no | Parrot: reasonable. macOS: installed but unverified. F-08 |
| `--ai` and sub-options | yes | yes | **no** | no | Undocumented absence on macOS |
| `--tailscale` | yes | rejected with reason | yes | no | WSL: yes, explicitly. Good model |
| `--containers` | yes | yes | yes | no | Yes |
| `--containers-api-socket` | yes | yes | **no** | no | Undocumented absence on macOS |
| Dev-workflow smoke tests | **no** | `--smoke-test` | `--workflows` | no | No. Two names, one capability. F-27 |
| `--defaults` | no | no | yes (default **on**) | no | Yes, macOS-specific |
| Zsh login shell set | yes | yes | **no** | yes, reimplemented | No. F-07, F-46 |
| Verify script | 780 lines | 450 | 255 | 96 | No. Chapter D |
| Theme hooks package | yes | yes | **no** | **no** | No. F-51 |
| `jq` in baseline | **no** | **no** | yes | yes | No. F-02 |
| Verify script at all | yes | yes | yes | yes | Windows: **none**. F-37 |

### F-07
**macOS never sets the Zsh login shell, but its verifier hard-fails unless it is exactly `/bin/zsh`, and the README claims it does**
*high, parity. Support: executed.*

**Evidence.** `grep -rn 'ensure_zsh_login_shell\|usermod\|chsh' platforms/macos/` returns
nothing: the macOS installer never changes the login shell. `common/lib/common.sh:117`
provides `ensure_zsh_login_shell`, and `platforms/fedora/scripts/install-system.sh` and
`platforms/fedora-wsl/scripts/install-system.sh` both call it. Parrot reimplements it
(F-46). macOS does neither.

But `platforms/macos/scripts/verify.sh:140-141`:
```bash
login_shell="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')"
if [[ "$login_shell" == /bin/zsh ]]; then pass ...; else fail "Account login shell is ${login_shell:-unknown}"; fi
```
And `README.md:137` states, platform-neutrally in the Quick Start: "The installer makes Zsh
the invoking user's default login shell."

**Consequences.** On a default modern macOS the login shell already is `/bin/zsh`, so this
passes by luck of the OS default rather than because the installer did anything. On a Mac
where the user has deliberately moved to a Homebrew Zsh at `/opt/homebrew/bin/zsh`, or to
another shell, the install completes and then **fails verification** on the last step, and
`platforms/macos/install.sh:201-206` turns that into `exit 1` with "verification reported
failures" and no remedy. A user whose only sin was using a newer Zsh gets a failed install.

**Implementation brief.**
1. Call `ensure_zsh_login_shell` from `platforms/macos/scripts/install-system.sh` after
   `brew bundle`, so the promise in `README.md:137` becomes true on macOS too. The shared
   helper already resolves Zsh via `command -v` and refuses to run as root, so it handles
   the Homebrew-Zsh case correctly. Note that on macOS changing the login shell uses
   `chsh -s`, and the target shell must be listed in `/etc/shells`; extend the helper to
   append it via `sudo` when absent, guarding for idempotency.
2. Relax `platforms/macos/scripts/verify.sh:140` to accept any Zsh: resolve the recorded
   shell and compare with `shell_paths_match "$login_shell" "$(resolve_zsh_path)"`, both of
   which already exist in `common/lib/common.sh`. A Homebrew Zsh must pass.
3. Either scope `README.md:137` per platform or, having done step 1, leave it as the
   now-true general statement.

**Acceptance.** Extend `tests/test-macos.sh` to assert `install-system.sh` calls
`ensure_zsh_login_shell`, and to drive the verifier with a stubbed `dscl` returning
`/opt/homebrew/bin/zsh` and a stubbed `command -v zsh` agreeing, asserting it **passes**.
Add a case with a `bash` login shell asserting it fails.

### F-08
**macOS installs the OCaml profile with no verification of it whatsoever**
*high, parity. Support: read.*

**Evidence.** `platforms/macos/install.sh:158` runs
`platforms/macos/scripts/install-ocaml.sh` and `:174` runs `common/install-ocaml.sh` under
`--ocaml`. `platforms/macos/scripts/verify.sh` contains no OCaml section at all, and
`platforms/macos/install.sh:195-199` never adds an OCaml flag to `verify_args`. Fedora, by
contrast, verifies the profile at `platforms/fedora/scripts/verify.sh:528` and Fedora WSL
has an equivalent. `common/verify-ocaml.sh` already exists and is platform-neutral.

So on macOS, `--ocaml` builds an opam switch, and verification then reports overall success
without having checked that the switch exists, that the compiler is the expected version,
or that `ocamllsp`, `ocamlformat` and the DAP tooling are present.

**Implementation brief.**
1. Add an `--ocaml` flag to `platforms/macos/scripts/verify.sh`'s option parser, matching
   the existing `--defaults`, `--containers` and `--tailscale` flags.
2. Under that flag, delegate to `common/verify-ocaml.sh` rather than reimplementing, so all
   three platforms share one OCaml verifier. Check whether `common/verify-ocaml.sh` makes
   Linux-specific assumptions (it declares its own `set -euo pipefail`, unlike the platform
   verifiers) and adjust if so.
3. In `platforms/macos/install.sh:195-199`, add
   `[[ "$install_ocaml" != true ]] || verify_args+=(--ocaml)`.
4. Apply the same treatment to the parity gaps in the same family: the Mason inventory and
   theme state are verified only on Fedora (F-51 and Chapter D).

**Acceptance.** Extend `tests/test-macos.sh` to assert that `verify.sh` accepts `--ocaml`,
that `install.sh` forwards it when `--ocaml` is selected, and that the verifier fails when
`opam` is stubbed as absent.

### F-09
**`docs/macos.md` documents a LaTeX workflow macOS cannot install**
*high, documentation. Support: read.*

**Evidence.** `docs/macos.md:114` and `:125-126` document a LaTeX workflow including the
`./scripts/test-dev-workflows.sh --latex` smoke test. `platforms/macos/install.sh` has no
`--latex` option (confirmed against the option matrix), and `platforms/macos/Brewfile`
contains no TeX distribution: no `mactex`, no `basictex`, no `texlive`. A macOS VimTeX
viewer override is nonetheless shipped at
`platforms/macos/stow/nvim-macos/.config/nvim/lua/plugins/macos.lua`, so the editor is
configured for a toolchain the installer cannot provide.

Compounding it, `tests/test-macos.sh:183` asserts that `docs/macos.md` contains the string
`./scripts/test-dev-workflows.sh --latex`. So the test suite actively pins the presence of
documentation for an uninstallable workflow.

**Implementation brief.** Choose one and make everything agree.

*Option A, implement it.* Add `--latex` / `--no-latex` to `platforms/macos/install.sh`,
add `cask "mactex-no-gui"` (or `basictex` for a smaller install) to a new optional Brewfile
section installed only under the flag, add `--latex` to the macOS verifier delegating to the
same checks Fedora uses, and keep the docs as they are.

*Option B, withdraw it.* Remove the LaTeX sections from `docs/macos.md`, replace them with
an explicit "LaTeX is not supported on macOS because ..." statement, remove the
`tests/test-macos.sh:183` assertion, and decide whether the VimTeX macOS override should
stay (it is harmless if LaTeX is absent, but it is misleading).

Option A is the better fit given the editor override already exists and `--latex` is
supported on two other platforms.

**Acceptance.** For Option A, extend `tests/test-macos.sh` to assert `--latex` appears in
the macOS usage text, that the Brewfile's optional section names a TeX distribution, and
that the verifier gains a LaTeX check; then run `scripts/test-dev-workflows.sh --latex` in
the macOS CI job. For Option B, assert `docs/macos.md` contains the explicit
not-supported statement and no `--latex` reference.

### F-10
**The Parrot CTF guest stows the full LazyVim and Mason config without provisioning it**
*high, parity. Support: read.*

**Evidence.** `platforms/parrot-ctf/scripts/stow.sh:12` invokes `common/stow.sh`, whose
package list at `common/stow.sh:28` includes `nvim-lazyvim`. So the complete LazyVim
configuration, including `lua/plugins/mason.lua` with its `ensure_installed` set and the 16
entries in `mason-packages.txt`, lands in the CTF guest. But
`platforms/parrot-ctf/install.sh:101-111` never runs `common/install-neovim-tools.sh` or the
`common/bootstrap-mason.lua` headless bootstrap, and the Parrot package list provides
neither Node nor .NET, while `platforms/parrot-ctf/stow/mise-ctf/.config/mise/config.toml`
declares only `uv`.

The consequence is that the user's first interactive `nvim` launch in the guest triggers
Mason attempting to install 16 tools, most of which cannot build because their runtimes are
absent. This is precisely the unattended first-launch install the README's Mason ownership
policy exists to avoid, and it happens on the one platform that is meant to be a
lightweight throwaway.

**Implementation brief.** The right answer for a CTF guest is a reduced editor profile, not
a full provisioning run.
1. Add a `--without-nvim-lazyvim` style exclusion to `common/stow.sh`'s package selection,
   in the same manner as the existing `--headless` and `--without-mise` switches, and pass
   it from `platforms/parrot-ctf/scripts/stow.sh`.
2. Create a minimal `platforms/parrot-ctf/stow/nvim-ctf/.config/nvim/` package with an
   `init.lua` that provides the colourscheme and basic editing but no Mason and no LSP
   bootstrapping, and stow that instead. State in its header comment that this is a
   deliberate reduced profile for a disposable guest.
3. Document the boundary in the README's Parrot section: the CTF guest gets the shell,
   theme and tool aliases, and a minimal editor, not the full LazyVim workstation.
4. If instead the full profile is wanted, run the headless Mason bootstrap from
   `platforms/parrot-ctf/install.sh` and add Node to the Parrot package list, and prune
   `mason-packages.txt` per platform. This is materially more work and more to maintain.

**Acceptance.** Extend `tests/test-parrot-ctf.sh` to assert that the recorded stow package
list does **not** contain `nvim-lazyvim`, that it does contain the reduced package, and that
`mason.lua` is absent from the guest's stowed tree. Add an assertion that
`platforms/parrot-ctf/install.sh` does not invoke `install-neovim-tools.sh`, so the two
halves cannot drift back apart.

### F-11
**`wsl-open` passes raw Linux paths to `explorer.exe`**
*high, correctness. Support: read.*

**Evidence.** `platforms/fedora-wsl/stow/interop/.local/bin/wsl-open:17` hands its argument
to `explorer.exe` without translating it through `wslpath -w`. `explorer.exe` interprets
its argument in the Windows filesystem namespace, so a Linux path such as
`/home/user/doc.pdf` is not resolvable and the call fails or opens the wrong thing. URLs
work, because those need no translation, which is why the defect is easy to miss. The file
and PDF half of the helper, which `README.md:502` and the WSL cheat sheet both document,
cannot work. `platforms/fedora-wsl/stow/nvim-wsl/.config/nvim/lua/plugins/wsl.lua:18`
routes Neovim's opener through it, so `gx` on a local file path is affected too.

**Implementation brief.**
1. In `wsl-open`, branch on the argument shape. If it matches a URL scheme
   (`^[a-zA-Z][a-zA-Z0-9+.-]*://`), pass it through unchanged. Otherwise resolve it to an
   absolute path and translate: `target="$(wslpath -w "$(readlink -f -- "$1")")"`, then
   pass `"$target"`.
2. Guard for the tools actually being available: check `command -v wslpath` and
   `command -v explorer.exe`, and `die` with an actionable message naming interop being
   disabled, rather than failing obscurely. Do the same in `wsl-copy` and `wsl-paste` for
   `clip.exe` and `powershell.exe`.
3. Quote throughout and use `--` before user-supplied arguments, so paths with spaces and
   leading dashes work. This is the case the current code would fail on even after
   translation.

**Acceptance.** Extend `tests/test-wsl-interop.sh`: stub `wslpath` and `explorer.exe` on
PATH as recording shims, then assert that (a) a URL reaches `explorer.exe` untranslated,
(b) a relative file path reaches it as a translated Windows path, (c) a path containing a
space is passed as a single argument, and (d) with `wslpath` absent the script exits
non-zero with a message mentioning interop.

### F-27
**The dev-workflow smoke-test capability has two names, exists on two platforms, and is absent from Fedora**
*medium, parity. Support: executed.*

**Evidence.** The same capability, running `scripts/test-dev-workflows.sh`, is exposed as:
- `platforms/macos/install.sh:14,34-35,57-58,182-186` as `--workflows` / `--no-workflows`
- `platforms/fedora-wsl/install.sh:21,70,160,443-444` as `--smoke-test`, which it forwards
  into `platforms/fedora-wsl/scripts/verify.sh:421,428,436`
- Fedora: neither.

Two names for one capability, and the platform most users install has no access to it.

**Implementation brief.** Standardise on one name across all four platforms. `--smoke-test`
is the better name because the thing it runs is a smoke test and the flag also reads
correctly on the verifier. Add `--smoke-test` / `--no-smoke-test` to
`platforms/fedora/install.sh` and `platforms/parrot-ctf/install.sh`; keep `--workflows` on
macOS as a documented deprecated alias for one release, mapping to the same variable, and
note it in the usage text. Route all four platforms through the verifier the way Fedora WSL
does, so the smoke test is part of verification rather than a separate installer step, and
remove the direct invocation at `platforms/macos/install.sh:182-186`.

**Acceptance.** Extend `tests/test-installer-options.sh` with a per-platform case asserting
`--smoke-test` is accepted and appears in the plan, and that on macOS `--workflows` still
works and prints a deprecation notice. Add a parity assertion (see below) so a future flag
cannot be added to one platform silently.

### F-37
**No Windows verify script exists at all**
*medium, parity. Support: executed.*

**Evidence.** `platforms/windows/` contains exactly two files: `install.ps1` and
`set-noctty-theme.ps1`. Every Unix platform ships a `verify.sh`; the Windows host has no
verification entry point. There is also no `-NonInteractive` equivalent to the Unix
`--non-interactive`, and no `-Theme` parameter, though `-DryRun` does exist.

To be fair to the code: `install.ps1` is the best-hygiene script in the repository in some
respects, with `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, a
validated parameter block and comment-based help. The gap is coverage, not craft.

**Implementation brief.**
1. Add `platforms/windows/verify.ps1` mirroring the Unix verifier contract: a `pass` /
   `fail` / `warning` helper trio, a non-zero exit when any check fails, and a final count.
   Check the WSL feature and version, that the resolved Fedora distribution is installed
   and is WSL 2, that Noctty is installed via Scoop, that the Ghostty configuration is
   present at the expected path, and that `/etc/wsl.conf` inside the distribution carries
   the interop settings `configure-interop.sh` writes.
2. Add `-NonInteractive` to `install.ps1` and have it suppress every prompt, matching the
   Unix flag semantics.
3. Call `verify.ps1` at the end of `install.ps1` unless `-DryRun`, and surface its exit
   code, mirroring `platforms/macos/install.sh:201-206`.
4. Extend `tests/test-windows-bootstrap.ps1` to cover the new script, and add it to the
   `windows` CI job.

**Acceptance.** The `windows` CI job runs `verify.ps1` in a mode where its checks are
stubbed and asserts it exits non-zero when a check fails and zero when all pass. Add a
Pester-style or plain-assertion test that `install.ps1` accepts `-NonInteractive` and that
no `Read-Host` executes under it.

### F-46
**Parrot reimplements the shared login-shell helper with a hardcoded path and no root guard**
*low, maintainability. Support: executed.*

**Evidence.** `platforms/parrot-ctf/scripts/install-system.sh:62`:
```bash
sudo usermod --shell /bin/zsh "$current_user"
```
against `common/lib/common.sh:117-135`'s `ensure_zsh_login_shell`, which resolves Zsh via
`command -v`, validates the result is an absolute executable file, refuses to run as root,
and skips the change when the shell already matches. The Parrot copy has none of that and
hardcodes a path that is correct on Debian but is exactly the assumption the shared helper
exists to avoid. Nothing verifies the result on Parrot either.

**Implementation brief.** Replace the hardcoded call with `ensure_zsh_login_shell`.
`platforms/parrot-ctf/scripts/install-system.sh` already sources `common/lib/common.sh`, so
this is a one-line substitution. Then add a login-shell check to
`platforms/parrot-ctf/scripts/verify.sh` matching the Fedora one.

**Acceptance.** Extend `tests/test-parrot-ctf.sh` to assert the captured command log
contains a `usermod --shell` call whose argument is the path a stubbed `command -v zsh`
reported, not a literal `/bin/zsh`, and that the script aborts when `id -u` is stubbed to 0.

### F-51
**macOS and Parrot ship no theme-hooks package, so a flavour switch does not reload anything and nothing verifies theme state**
*medium, parity. Support: read, cross-checked.*

**Evidence.** `platforms/fedora/stow/theme-hooks/` and
`platforms/fedora-wsl/stow/theme-hooks/` provide `theme-hooks.d/` scripts that
`bin/.local/bin/theme` sources to reload Ghostty, Sway, Waybar and the KDE desktop. Neither
`platforms/macos/scripts/stow.sh:12` nor `platforms/parrot-ctf/scripts/stow.sh:12` stows any
theme-hooks package, and none exists for those platforms. So on macOS and Parrot, `theme
<flavour>` rewrites the derived state files but a running Ghostty keeps the old flavour, and
the user is given none of the reload guidance the Fedora and WSL hooks print. In addition,
`platforms/macos/scripts/verify.sh` and `platforms/parrot-ctf/scripts/verify.sh` assert
nothing about `~/.config/dotfiles/theme` or the derived overrides, so a missing or corrupt
theme state is caught on two platforms and invisible on the other two.

**Implementation brief.**
1. Add `platforms/macos/stow/theme-hooks/.config/dotfiles/theme-hooks.d/macos.sh` that
   reloads what macOS can reload: send Ghostty its configuration-reload signal, and if
   AeroSpace or JankyBorders carry colours, reload those. Where a restart is genuinely
   required, print the same style of guidance the Fedora hook prints rather than doing
   nothing.
2. Add the package to `platforms/macos/scripts/stow.sh`'s list.
3. Document the theme hook contract, which is currently undocumented anywhere: what a hook
   receives, that it is sourced rather than executed, the ordering, and the failure
   semantics (see F-52). Put it in a new `docs/theming.md` and link it from the README.
4. For Parrot, decide explicitly that live reload is out of scope for a disposable guest and
   record that in the README's Parrot section, rather than leaving it as an accident.
5. Add theme-state assertions to the macOS and Parrot verifiers: the state file exists,
   contains one of the four flavours, and the derived Ghostty override names the matching
   theme file.

**Acceptance.** Extend `tests/test-theme.sh` to run the switch with a stubbed macOS hook
directory and assert the hook is sourced and the reload command recorded. Extend
`tests/test-macos.sh` and `tests/test-parrot-ctf.sh` to assert their verifiers fail when the
theme state file is missing or contains an unknown flavour.

### F-52
**A single failing theme hook aborts the rest of the switch with no diagnostic**
*high, correctness. Support: read.*

**Evidence.** `bin/.local/bin/theme:87-94` sources each hook in
`~/.config/dotfiles/theme-hooks.d/` under the script's own `set -e`, with no per-hook error
handling. The Fedora hook
(`platforms/fedora/stow/theme-hooks/.config/dotfiles/theme-hooks.d/fedora.sh`) performs
several independent actions in sequence: `apply-kde-theme.sh` at `:22`, the Ghostty reload
chain at `:26-46`, and `swaymsg reload` at `:53`. Because the hook is sourced, a non-zero
exit anywhere in it terminates every later action in that hook and every later hook, and the
`theme` command exits non-zero with whatever the failing command printed. On a KDE machine
where a Plasma tool is missing, the Ghostty and Sway reloads are silently skipped.

**Implementation brief.**
1. In `bin/.local/bin/theme`, run each hook in a subshell with failure contained and
   reported, rather than sourcing it into the current shell:
   ```bash
   hook_failures=0
   for hook in "$hooks_dir"/*.sh; do
     [[ -r "$hook" ]] || continue
     if ! ( set -e; source "$hook" ); then
       warn "Theme hook failed: $hook (continuing with remaining hooks)"
       hook_failures=$((hook_failures + 1))
     fi
   done
   ```
   Decide deliberately whether `theme` should exit non-zero when `hook_failures > 0`;
   reporting a non-zero exit while still having applied everything it could is the right
   behaviour. Note that moving from `source` to a subshell changes the contract if any hook
   currently relies on exporting variables back to `theme`; audit both existing hooks first
   and document the contract per F-51 step 3.
2. Inside `fedora.sh`, make the three independent actions independently guarded so a missing
   Plasma tool cannot prevent the Ghostty reload.

**Acceptance.** Extend `tests/test-theme.sh`: install two stub hooks, the first exiting
non-zero and the second recording that it ran. Assert the second hook ran, that the warning
names the first, and that `theme` exits non-zero. Add a case inside the Fedora hook path
asserting a stubbed failing `apply-kde-theme.sh` does not prevent the recorded Ghostty
reload.

---

## 7. Chapter D: the verification scripts

This chapter covers the requested "robustness of the included verifications". It is the
chapter I would act on first after F-01, because these scripts are the repository's only
mechanism for telling a user whether their machine is correctly built, and several of their
checks report success regardless of the machine's state.

Scale of the asymmetry, which is itself the headline: `platforms/fedora/scripts/verify.sh`
is 780 lines, `platforms/fedora-wsl/scripts/verify.sh` 450, `platforms/macos/scripts/verify.sh`
255, `platforms/parrot-ctf/scripts/verify.sh` 96. The components they check are largely the
same components.

### F-03
**`verify.sh` reports a dangling stow symlink as verified, on all four platforms**
*high, testing. Support: executed.*

**Evidence.** `platforms/fedora/scripts/verify.sh:39-55`:
```bash
check_symlink() {
  local target="$1"
  local expected_prefix="$2"
  if [[ ! -L "$target" ]]; then
    fail "$target is not a symlink"
    return
  fi
  local resolved
  resolved="$(readlink -f "$target")"
  if [[ "$resolved" == "$expected_prefix"* ]]; then
    pass "$target -> $resolved"
  else
    fail "$target resolves outside dotfiles repo: $resolved"
  fi
}
```
There is no existence test. `readlink -f` canonicalises without requiring the target to
exist, so a dangling link still produces a path, and if that path is inside the repository
the prefix matches and `pass` is called.

**Demonstrated:**
```
is symlink: yes
exists    : NO - dangling
readlink -f -> '/tmp/tmp.3qyETMzfFo/repo/does-not-exist'
VERDICT: prefix MATCHES -> check_symlink calls pass()
```

**Why it matters.** This is the single most-used helper in the verification suite, and the
failure mode it misses is the most likely one in practice: the user moves or renames the
dotfiles clone, or deletes it, and every stow symlink in `$HOME` dangles. Verification then
reports every configuration link as correct while the shell, editor, terminal and git
configuration are all in fact broken. A file removed from a stow package but still linked
in `$HOME` produces the same false pass.

**Implementation brief.**
1. Change the existence test to use `readlink -e`, which fails on a nonexistent target, and
   report the dangling case distinctly so the message is actionable:
   ```bash
   local resolved
   if ! resolved="$(readlink -e -- "$target")"; then
     fail "$target is a dangling symlink (points at $(readlink -- "$target"), which does not exist)"
     return
   fi
   ```
   Keep the existing prefix comparison after that.
2. Apply the identical fix to every copy of this helper. It is duplicated across the
   verifiers under both the names `check_symlink` and `check_link`; find them all with
   `grep -rn 'readlink -f' platforms/ common/` and fix each, or better, fix it once in the
   shared `common/lib/verify.sh` that F-35 creates.
3. While there, confirm the resolved path is compared against the actual repository root
   rather than a prefix that a sibling directory could also satisfy: a repo at
   `/home/u/src/dotfiles` and a stray `/home/u/src/dotfiles-old` both match a
   `/home/u/src/dotfiles` prefix. Compare against `"$DOTFILES_ROOT/"` with the trailing
   slash included.

**Acceptance.** Add `tests/test-verify-helpers.sh`: create a temporary HOME with (a) a
correct symlink into a fake repo, (b) a dangling symlink into the fake repo, (c) a real
file where a symlink is expected, and (d) a symlink into a `dotfiles-old` sibling. Assert
`pass` only for (a) and a distinct failure message for each of (b), (c) and (d).

### F-05
**The rootless Podman API socket check calls `pass` in both branches**
*high, testing. Support: read.*

**Evidence.** `platforms/fedora/scripts/verify-containers.sh:108-117`:
```bash
if systemctl --user is-enabled --quiet podman.socket 2>/dev/null; then
  pass "podman.socket is enabled (socket-activated, user-scoped)"
  if systemctl --user is-active --quiet podman.socket 2>/dev/null; then
    pass "podman.socket is active"
  fi
else
  pass "podman.socket is not enabled (default; enable with --api-socket if needed)"
fi
```
Every path calls `pass`. The check can never fail, and more importantly it cannot detect the
condition that matters: the verifier has no idea whether `--containers-api-socket` was
requested, so a user who asked for the API socket and whose socket failed to enable is told
"not enabled (default)" and verification passes.

**Implementation brief.** The verifier needs to know what was requested. macOS already has
the right idea, recording state files at `platforms/macos/scripts/install-containers.sh:32`,
though nothing reads them (F-53).
1. Have `platforms/fedora/scripts/install-containers.sh` record the requested configuration
   in machine-local state, for example
   `"${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/containers.conf` containing
   `api_socket=true|false`, written through `atomic_write_file`.
2. In `verify-containers.sh`, read that file. If `api_socket=true`, the enabled and active
   checks become `fail` on a negative result. If `api_socket=false`, assert the socket is
   **not** enabled and `fail` if it is, since that would mean the machine has an API socket
   the user did not ask for. If the state file is absent, `warning` that the profile
   predates state recording.
3. Add the socket permission check that is currently missing entirely: assert the socket
   path is user-owned and not group- or world-writable.

**Acceptance.** Extend `tests/test-containers.sh` with four cases crossing recorded intent
against stubbed `systemctl --user is-enabled` results, asserting pass or fail per the table
above, plus a case with the state file absent asserting a warning. Assert explicitly that
the `api_socket=true` plus not-enabled combination **fails**, since that is the case that
silently passes today.

### F-06
**`verify-tailscale.sh` passes without ever determining Tailscale's state**
*high, testing. Support: read, root cause executed.*

**Evidence.** `platforms/fedora/scripts/verify-tailscale.sh:82`:
```bash
backend_state="$(printf '%s' "$status_json" | jq -r '.BackendState // "unknown"' 2>/dev/null)"
```
There is no `require_command jq` or `command_exists jq` guard anywhere in the file
(verified by grep). Per F-02, `jq` is not installed on Fedora unless `--sway` was selected.
So `./install.sh --tailscale` without `--sway` produces a machine where this line's `jq` does
not exist. The `2>/dev/null` swallows "command not found", `backend_state` becomes the empty
string, and the `case` at `:84-95` falls through to:
```bash
*)
  warning "tailscale status reported an unrecognized BackendState: ${backend_state:-empty}"
  ;;
```
Because that is `warning` and not `fail`, `failures` is not incremented and the script exits
0. Verification reports success having learned nothing about whether Tailscale is connected,
and misdirects the user toward an imaginary Tailscale problem rather than the missing `jq`.

To be precise about severity: the `*)` branch does handle the empty case explicitly with
`${backend_state:-empty}`, so this is a silent pass rather than a crash, and the author
clearly anticipated an unexpected value. The defect is that a missing dependency is
indistinguishable from an unexpected daemon state, and neither fails.

**Implementation brief.**
1. Fix the root cause by adding `jq` to the Fedora and Fedora WSL baselines per F-02.
2. Add an explicit dependency guard at the top of `verify-tailscale.sh` so this can never
   silently degrade again: `command_exists jq || fail "jq is required to verify Tailscale
   state"` and skip the JSON section, rather than proceeding into it.
3. Remove the `2>/dev/null` from the `jq` invocation, or keep it and check `jq`'s exit
   status explicitly. Suppressing stderr on a parse of untrusted JSON is reasonable;
   suppressing it on a command that may not exist is not.
4. Consider avoiding `jq` here altogether. `tailscale status --json` is the richer form, but
   `tailscale status` in its plain form, or `tailscale status --peers=false`, gives the
   backend state without a JSON dependency and would remove the coupling.

**Acceptance.** Extend `tests/test-tailscale.sh` with a case where `jq` is absent from the
stub PATH and `tailscale` is stubbed as active, asserting the verifier **fails** with a
message naming `jq`. Add a case where `jq` is present but returns an unexpected state,
asserting that is reported distinctly from the missing-dependency case.

### F-15
**`common/lib/common.sh` silently forces `errexit` and `pipefail` onto 13 verify scripts that deliberately opted out**
*medium, correctness. Support: executed.*

**Evidence.** `common/lib/common.sh:3` contains `set -euo pipefail` at library top level. A
sourced library changes its caller's shell options.

Thirteen scripts deliberately declare only `set -u`, because they aggregate failures and
must not die on the first one, and every one of them then sources that library:

`platforms/fedora/scripts/verify.sh`, `verify-asus-hardware.sh`, `verify-containers.sh`,
`verify-desktop-tools.sh`, `verify-hardening.sh`, `verify-tailscale.sh`, `verify-vm-guest.sh`,
`verify-vm-host.sh`; `platforms/fedora-wsl/scripts/verify.sh`, `verify-containers.sh`;
`platforms/macos/scripts/verify.sh`; `platforms/parrot-ctf/scripts/verify.sh`;
`common/verify-ai.sh`. Only `common/verify-ocaml.sh` declares `-euo pipefail` itself.

**Proven behaviourally, because the flag readout is misleading.** A probe script declaring
`set -u`, sourcing the library, then running `false` and echoing afterwards exits 1 and
never reaches the echo, so `errexit` is active. A second probe confirms `pipefail` is on.
Reading `set -o | grep errexit` inside a command substitution reports "off" and should not
be trusted; the behavioural test is the reliable one, and my first reading of this was
wrong for exactly that reason.

**Why it matters, stated honestly.** This is latent, not currently exploding. The
aggregation contract does still work in practice: a live run produced "Verification failed:
4 failure(s), 3 warning(s)", so multiple failures were collected. It works because the
checks all happen to sit inside `if` or `||` guards, where `errexit` does not apply. The
defect is that the authors' explicit intent is silently overridden, so the safety property
holds by accident, and the next check added as a bare command will abort the run at the
first failure, under-report the failure count and skip every later check without saying so.

**Implementation brief.** Delete `set -euo pipefail` from `common/lib/common.sh:3`. A
sourced library must not set shell options for its caller.

**This is safe, and I verified the blast radius rather than assuming it.** Scanning every
consumer of `lib/common.sh` shows all 40-plus install scripts and all four platform
installers declare `set -euo pipefail` themselves, so none of them loses anything. The
`platforms/*/lib/*.sh` files correctly declare nothing, since they are sourced. After the
change, the 13 verify scripts finally get the `set -u`-only semantics they asked for.

**Acceptance.** Add to `tests/test-verify-helpers.sh` an assertion that
`common/lib/common.sh` contains no top-level `set -` line, and a behavioural assertion that
a script declaring `set -u`, sourcing the library, and running a failing command continues
executing. Then add a check to `scripts/lint.sh` that no file under `common/lib/` or
`platforms/*/lib/` contains a top-level `set -` line, so this cannot regress.

### F-20
**`verify-hardening.sh` reports its own core artifacts with `warning`, so it exits 0 when hardening has been reverted**
*medium, testing. Support: read.*

**Evidence.** `platforms/fedora/scripts/verify-hardening.sh` contains 6 `fail` calls and 10
`warning` calls. The artifacts the hardening profile actually creates are checked with
`warning`:
```bash
if command_exists authselect && authselect current 2>/dev/null | grep -q with-faillock; then
  pass "authselect has with-faillock enabled"
else
  warning "authselect does not report with-faillock enabled"
fi
...
if sudo test -f "$faillock_dropin" 2>/dev/null; then
  pass "faillock policy drop-in present: $faillock_dropin"
else
  warning "faillock policy drop-in missing: $faillock_dropin"
fi
...
if sudo test -f /etc/sudoers.d/90-dotfiles-hardening 2>/dev/null; then
  pass "sudo logfile drop-in present: ..."
else
  warning "sudo logfile drop-in missing: ..."
fi
```
Only `fail` increments `failures`, so deleting the faillock drop-in, the sudoers drop-in and
the authselect feature leaves verification exiting 0.

I am stating this more narrowly than the original finding did: it is not that *every*
hardening change can be reverted undetected, since 6 checks do fail properly. It is that the
profile's own drop-in files and PAM state, which are the things it uniquely creates, are all
non-failing.

For a profile whose purpose is a security posture, "we could not confirm any of the
hardening is in place" must not be a pass.

**Implementation brief.**
1. Reclassify to `fail` every check whose subject is an artifact this profile creates: the
   faillock drop-in, the sudoers logfile drop-in, the authselect `with-faillock` feature,
   and the sysctl drop-in. Keep `warning` only for genuinely environmental observations
   where absence is not evidence of a broken install.
2. Gate the whole script on whether the profile was installed, using recorded state as in
   F-05, so a machine that never opted into hardening is not failed for lacking it. Without
   that gate, step 1 would fail every non-hardened machine.
3. Add the missing rollback path. `install-hardening.sh:35` only notes that the README
   documents "rollback instructions for each"; there is no rollback script. Add
   `platforms/fedora/scripts/uninstall-hardening.sh` that removes each drop-in this profile
   created, restores the authselect feature state captured at install time, and reports
   what it changed. Capture the pre-change state at install into machine-local state so the
   rollback is real rather than best-effort.

**Acceptance.** Extend `tests/test-hardening.sh`: with recorded state saying hardening was
installed, stub `sudo test -f` to report each drop-in missing in turn and assert the
verifier **fails** each time. With state saying it was not installed, assert it passes. Add
a case running the new uninstall script and asserting the recorded drop-ins are removed and
the authselect state restored.

### F-35
**Thirteen verify scripts each redefine `pass`/`fail`/`warning` with five different contracts**
*medium, maintainability. Support: read.*

**Evidence.** The helper trio is redefined in each of the 13 verify scripts, for example at
`platforms/fedora/scripts/verify.sh:15` and `platforms/fedora/scripts/verify-containers.sh:33`,
with divergent behaviour: different failure-counter names, different decisions about whether
`warning` affects the exit code, and different final-summary formats. The consequence is that
a caller cannot rely on a uniform contract across the suite, which is exactly what
`platforms/fedora/scripts/verify.sh` does when it delegates to the sub-profile verifiers, and
it is why defects like F-05, F-06 and F-20 can exist in one script and not its neighbours: a
fix to one copy does not reach the others.

**Implementation brief.**
1. Create `common/lib/verify.sh` exporting one contract: `pass`, `fail`, `warning`, a
   `section` heading helper, the `verify_summary` function that prints the counts and
   returns the correct exit status, and the shared checks `check_command`, `check_symlink`
   (with the F-03 fix), `check_mise_owned` (moved from `common/verify-ai.sh` per F-14) and
   `check_command_runs` (see below). Deliberately do **not** put a `set` line in it, per
   F-15.
2. Define the contract explicitly in a header comment: `warning` never affects the exit
   status; `fail` always does; a verifier exits non-zero if and only if at least one `fail`
   fired; a sub-profile verifier invoked by a parent propagates its status.
3. Convert the 13 scripts one at a time, deleting the local definitions. Convert
   `platforms/parrot-ctf/scripts/verify.sh` first because it is smallest, then macOS, then
   Fedora WSL, then Fedora, keeping `scripts/test.sh` green at each step.

**Adopt the primitive the repository already invented.** `origin/main` added to
`common/verify-ai.sh`:
```bash
# check_command_runs <command> <arguments...>: catches an executable that was
# installed but is unusable, such as Claude Code without its required npm
# postinstall step linking the platform-native binary.
check_command_runs() { ... }
```
That comment is a precise diagnosis of the dominant weakness across all these scripts, and
the helper is the correct remedy. It is currently applied to exactly one check,
`check_command_runs claude --version`. Generalising it is the highest-leverage change in
this chapter: for every tool the verifiers currently confirm with `command -v`, run the tool
and check it works. Good candidates: `nvim --version`, `tmux -V`, `starship --version`,
`stow --version`, `rg --version`, `fd --version`, `bat --version`, `zoxide --version`,
`gh --version`, `mise --version`, `lazygit --version`, `jq --version`.

**Acceptance.** `tests/test-verify-helpers.sh` drives the shared helpers directly:
`warning` alone exits 0, one `fail` exits non-zero, the summary counts match, and
`check_command_runs` fails for a stub that exists but exits non-zero (which is the Claude
Code postinstall failure mode that motivated it). Then assert no verify script defines its
own `pass()` any more, so the consolidation cannot silently reverse.

### F-53
**macOS records optional-profile state that nothing ever reads**
*low, completeness. Support: read.*

**Evidence.** `platforms/macos/scripts/install-containers.sh:32` and
`platforms/macos/scripts/install-tailscale.sh:16` write `macos-containers.conf` and
`macos-tailscale.conf` into machine-local state. No verifier reads either file:
`platforms/macos/scripts/verify.sh` gates those sections on the `--containers` and
`--tailscale` flags being passed to it instead. So verification depends on the caller
re-stating what was installed, and a manual `./platforms/macos/scripts/verify.sh` with no
flags silently skips both profiles.

This is the same design problem F-05 describes, and the same fix resolves both. The state
files are the right mechanism and already exist; they are simply not consulted.

**Implementation brief.** Have `platforms/macos/scripts/verify.sh` read the recorded state
files to decide which sections to run, treating an explicit flag as an override rather than
the only source of truth. Then extend the pattern to Fedora per F-05 so all platforms
determine what to verify from what was recorded as installed.

**Acceptance.** Extend `tests/test-macos.sh` to run the verifier with **no** flags but with
`macos-containers.conf` present, asserting the containers section executes and can fail.

---

## 8. Chapter E: the test suite

This chapter covers the requested "robustness of the included tests". The complete
per-file coverage inventory is Appendix C.

### What a green run currently proves

`scripts/test.sh` runs 32 shell tests. The dominant assertion style is grepping installer
**source text** for a literal string. That is a legitimate technique for pinning a
contract, but it is worth being precise about what it establishes: it proves the installer
still *contains* certain text, not that the installer *does* anything. Almost nothing in CI
installs or executes the software under test. The Fedora job runs in a `fedora:44` container
but exercises the installers through PATH stubs; the macOS job installs Homebrew and Stow
and then never runs the macOS installer against them; the Windows job parses `install.ps1`.

That is a defensible design for a bootstrap that cannot easily be run in CI. The problems
are (a) two tests are structurally incapable of failing, (b) the runner hides failures, and
(c) the mocking approach does not scale, which the repository has already felt.

### F-04
**`tests/test-neovim-first-launch.lua` can never fail the suite**
*high, testing. Support: executed.*

**Evidence.** `tests/test-neovim-tool-ownership.sh:54-56`:
```bash
NVIM_LOG_FILE="$nvim_log" nvim --headless -u NONE -i NONE \
  -c 'lua dofile("tests/test-neovim-first-launch.lua")' \
  -c 'quitall!'
```
and immediately below it, at `:58`:
```bash
DOTFILES_TEST_ROOT="$repo_root" NVIM_LOG_FILE="$nvim_log" \
  nvim --headless -u NONE -i NONE -l tests/test-ocaml-dap.lua
```

**Demonstrated with a deliberately failing Lua file:**
```
-c 'lua dofile(...)' exit = 0   (the failure is invisible)
-l script            exit = 1   (-l propagates correctly)
```
Neovim's `-c` executes a command and continues; a Lua `error()` inside it becomes a message,
and the subsequent `quitall!` exits 0. `-l` runs the file as a script and propagates a
non-zero status.

So all 124 lines of assertions in `tests/test-neovim-first-launch.lua`, which cover the
first-launch behaviour that F-10 shows actually matters, are dead. And the correct pattern is
sitting two lines below the broken one in the same file.

**Implementation brief.** Change `tests/test-neovim-tool-ownership.sh:54-56` to use `-l`,
matching line 58:
```bash
NVIM_LOG_FILE="$nvim_log" nvim --headless -u NONE -i NONE -l tests/test-neovim-first-launch.lua
```
Then **run the suite and expect new failures**: these assertions have never executed, so
some are likely stale or wrong. Triage each genuinely rather than adjusting it until it
passes; an assertion that has never run is unproven in both directions. Check whether
`test-neovim-first-launch.lua` relies on `dofile` semantics such as the caller's working
directory or a pre-set global, and pass what it needs via the environment as line 58 does
with `DOTFILES_TEST_ROOT`.

**Acceptance.** After the change, temporarily inject `error("canary")` at the top of
`tests/test-neovim-first-launch.lua` and confirm `scripts/test.sh` fails; remove the canary.
Better, make that permanent: add a `tests/test-lua-harness.sh` that runs a fixture Lua file
which deliberately errors and asserts the runner surfaces a non-zero status, so the harness
itself is tested.

### F-17
**`scripts/test.sh` aborts on the first failure with no summary and no indication that tests were skipped**
*medium, testing. Support: executed.*

**Evidence.** `scripts/test.sh` is a bare loop under `set -euo pipefail`:
```bash
for test_script in "${tests[@]}"; do
  printf '\n==> %s\n' "$test_script"
  "$repo_root/$test_script"
done
printf '\nAll bootstrap tests passed.\n'
```
The first failing test terminates the run. There is no summary, no count, and nothing tells
the operator that later tests never executed.

**Measured across three real runs in this container:**

| Run | Condition | Tests that ran | Exit | Diagnostic |
|---|---|---|---|---|
| 1 | shallow clone, no `nvim` | 5 of 32 | 1 | **none at all** |
| 2 | full history, no `nvim` | 10 of 32 | 1 | clear ("nvim is required") |
| 3 | full history, with `nvim` | 15 of 32 | 1 | clear (environment-specific) |

In run 1 the operator sees a run that stops after five tests with no error message and no
statement that 27 tests were skipped. That is the worst possible failure presentation, and
its cause is F-18.

**Implementation brief.**
1. Rewrite the loop to continue past failures and aggregate:
   ```bash
   failed=() passed=0
   for test_script in "${tests[@]}"; do
     printf '\n==> %s\n' "$test_script"
     if "$repo_root/$test_script"; then
       passed=$((passed + 1))
     else
       failed+=("$test_script")
       printf '\033[1;31mFAILED:\033[0m %s\n' "$test_script" >&2
     fi
   done
   printf '\n%d passed, %d failed of %d\n' "$passed" "${#failed[@]}" "${#tests[@]}"
   if ((${#failed[@]})); then
     printf 'Failed tests:\n'; printf '  %s\n' "${failed[@]}"
     exit 1
   fi
   printf 'All bootstrap tests passed.\n'
   ```
   Note this needs `set +e` around the invocation or the `if` form above, which is already
   `errexit`-safe.
2. Add an opt-in `--fail-fast` for the tight local loop, so the aggregating behaviour is the
   default and fail-fast is the deliberate choice rather than the reverse.
3. Add a prerequisite preflight at the top that checks for `nvim`, `stow`, `shellcheck`,
   `git`, `jq` and `rg` and reports all missing tools at once with a clear message, rather
   than discovering each one 10 tests in. Decide per tool whether absence should skip the
   dependent tests (reported as skipped in the summary) or fail the run; skipping with a
   visible count is the more useful behaviour for a contributor.

**Acceptance.** Add `tests/test-runner-behaviour.sh` (invoked directly, not from
`scripts/test.sh`, to avoid recursion) that runs the runner against a fixture list
containing one passing and two failing stub tests, asserting the exit status is non-zero,
that all three ran, and that the summary names both failures.

### F-18
**`tests/test-local-state.sh` depends on git history depth and fails silently on a shallow clone**
*medium, testing. Support: executed.*

**Evidence.** `common/setup-local.sh:36-52`, in `restore_former_git_config`, recovers a
git identity file that is no longer tracked. It first looks for it on disk, and since
`.gitignore:1-2` ignores `/git/.config/git/local` and `/git/.config/git/drdk`, it is absent
in any clone. It then falls back to **git history**:
```bash
while IFS= read -r revision; do
  if git -C "$DOTFILES_ROOT" cat-file -e "${revision}:${repo_relative_path}" 2>/dev/null; then
    git -C "$DOTFILES_ROOT" show "${revision}:${repo_relative_path}" >"$destination"
    restored="true"; break
  fi
done < <(git -C "$DOTFILES_ROOT" log --all --format='%H' -- "$repo_relative_path" 2>/dev/null)
```
Those paths were tracked in commits `2309ad0` and `485186f`, so with full history the
content is recovered and the test passes. On a **shallow** clone the history walk finds
nothing, `setup-local.sh` warns "Replaced obsolete Git config symlink with an empty local
file", and `tests/test-local-state.sh:87`'s bare `grep -Fq '[user]' "$identity_path"` fails
under `set -e` with **no message**.

Reproduced directly on a shallow clone:
```
local: size=0 mode=600 grep[user]=FAIL
drdk:  size=0 mode=600 grep[user]=FAIL
```
And confirmed as the cause: after `git fetch --unshallow`, the same test passes.

**Three distinct defects here.**
1. *Test:* it is coupled to clone depth. It passes in CI only because
   `.github/workflows/validate.yml:31` sets `fetch-depth: 0`. That dependency is
   undocumented and unenforced, so anyone who trims it, or clones with `--depth`, breaks the
   suite with no clue why.
2. *Production:* on a shallow clone, a real user's legacy git identity file is replaced by an
   **empty** file rather than migrated. The `warn` tells them, but the content is gone. That
   is narrow data loss on the migration path.
3. *Test style:* the assertions are bare `[[ ]]` and `grep -Fq` with no `|| fail "..."`, so
   the failure carries no diagnostic. Contrast `tests/test-neovim-tool-ownership.sh:51`,
   which fails with a clear message. Failure-message discipline is inconsistent across the
   suite.

**Implementation brief.**
1. Make the production path honest about the degradation. In
   `restore_former_git_config`, detect a shallow repository with
   `git rev-parse --is-shallow-repository` and, when shallow and the file is not on disk,
   warn specifically: name the file, say the migration could not recover its contents
   because the clone is shallow, and tell the user to run `git fetch --unshallow` and re-run
   if they want the old contents recovered. Do not silently create an empty file with a
   generic message.
2. Make the test independent of clone depth. Have `tests/test-local-state.sh` construct the
   legacy state it needs rather than relying on repository history: create a fixture file
   with `[user]` content at the expected former path inside a temporary copy of the repo
   root, so the on-disk branch of `restore_former_git_config` is what gets exercised. Add a
   **second** case that explicitly simulates the shallow situation and asserts the new
   specific warning and the empty-file outcome, so the degradation is pinned rather than
   accidental.
3. Add `|| fail "..."` messages to every bare assertion in the file.
4. Document the `fetch-depth: 0` requirement in a comment in
   `.github/workflows/validate.yml` next to the setting, naming this test, so it is not
   trimmed as an optimisation.

**Acceptance.** The reworked test passes on a shallow clone. Prove it in CI by adding a job,
or a step in the existing one, that clones the repository with `--depth 1` into a temporary
directory and runs `tests/test-local-state.sh` against it.

### F-21
**Eight of twelve assertions in `tests/test-sftp-baseline.sh` cannot fail**
*medium, testing. Support: executed.*

**Evidence.** `tests/test-sftp-baseline.sh:11-16` defines the assertion as an unanchored
fixed-string search:
```bash
assert_contains() {
  local file="$1"
  local value="$2"
  grep -Fq -- "$value" "$file" || fail "$file does not contain: $value"
}
```
and `:73-75` loops the SFTP interactive commands over the 4462-line README:
```bash
for interactive_command in ls cd lcd pwd lpwd get put mget mput mkdir rm exit; do
  assert_contains "$readme" "$interactive_command"
done
```

**Measured bare-substring match counts in `README.md`:**

| token | lines matched | discriminating? |
|---|---|---|
| `ls` | 281 | no |
| `rm` | 281 | no |
| `get` | 36 | no |
| `put` | 25 | no |
| `cd` | 11 | no |
| `exit` | 7 | no |
| `mkdir` | 4 | no |
| `pwd` | 2 | no |
| `lcd` | 1 | yes |
| `lpwd` | 1 | yes |
| `mget` | 1 | yes |
| `mput` | 1 | yes |

Eight of the twelve match as substrings of ordinary English words ("tools", "form",
"target", "included", "arm"), so deleting the entire SFTP section from the README would
leave those eight passing.

The same pattern appears elsewhere. `tests/test-latex-profile.sh:45-50` greps the test's own
fixtures under `tests/fixtures/latex-smoke/`, so no change to `install-latex.sh` or the
VimTeX config can fail it. `:52-56` asserts the text of `scripts/test-dev-workflows.sh`, a
sibling harness rather than an implementation, and one that no CI job runs.
`tests/test-neovim-tool-ownership.sh:176-190` greps its own Angular and Python fixtures.

**Implementation brief.**
1. Add an anchored assertion helper and use it for documentation checks. The right unit is a
   line, not a substring:
   ```bash
   assert_line_matches() {
     local file="$1" pattern="$2"
     grep -Eq -- "$pattern" "$file" || fail "$file has no line matching: $pattern"
   }
   ```
   For the SFTP command list, assert against the specific documentation table rather than the
   whole README: extract the SFTP section first (for example with `awk` between the
   `## 7. SFTP client` heading and the next `## ` heading) into a temporary file, then assert
   each command appears as a table cell or code span within that section only. Scoping the
   search to the relevant section is what actually makes the assertion meaningful.
2. Delete the fixture-grepping assertions in `tests/test-latex-profile.sh:45-50` and
   `tests/test-neovim-tool-ownership.sh:176-190`, or convert them into assertions about the
   **implementation** that consumes those fixtures. A fixture is an input; asserting its
   contents tests nothing.
3. Replace `tests/test-latex-profile.sh:52-56`'s assertions about
   `scripts/test-dev-workflows.sh` text with actually running
   `scripts/test-dev-workflows.sh --latex` in an environment where its tools are stubbed,
   which tests behaviour instead of source text.
4. Sweep the suite for the same shape: any `assert_contains "$readme"` or
   `assert_contains "$repo_root/tests/fixtures/..."` call is suspect. Appendix C lists the
   ones found.

**Acceptance.** For each converted assertion, prove it can fail: delete the SFTP section
from a temporary copy of the README and assert the test fails; corrupt the relevant
implementation file and assert the converted test fails. Add these as explicit
negative-control cases rather than trusting that the new assertion is stricter.

### F-28
**`scripts/test-dev-workflows.sh` is production code living in the test directory, run by no CI job**
*medium, maintainability. Support: executed.*

**Evidence.** `scripts/test-dev-workflows.sh` is invoked as part of installation and
verification:
- `platforms/macos/install.sh:183,185` under `--workflows`
- `platforms/fedora-wsl/scripts/verify.sh:421,428,436` under `--smoke-test`

It is **not** in `scripts/test.sh`'s list and is run by no CI job. Meanwhile
`tests/test-latex-profile.sh:52-56` and `tests/test-macos.sh:183` assert things about its
source text, and `README.md:3932-3937` documents it as a user-facing command.

So a script that runs during a real macOS install, and during Fedora WSL verification, is
never itself executed in CI, and is placed in the directory that signals "test tooling".
Its 300 lines create disposable projects, run `dotnet`, `ng`, `python`, `dune` and `latexmk`,
and hit the network (`:148` fetches over `curl`), so a regression in it breaks an install
rather than a test run.

`scripts/` is mixed-purpose in general: it holds roughly 20 thin back-compatibility shims
that `exec` into `platforms/fedora/scripts/*`, plus five pieces of real tooling (`lint.sh`,
`test.sh`, `test-installer.sh`, `test-dev-workflows.sh`, `update-starship-themes.sh`), and
`test-installer.sh` is now only a deprecation stub. A blanket rule for the directory is
therefore wrong; it needs splitting by purpose.

**Implementation brief.**
1. Move `scripts/test-dev-workflows.sh` to `common/run-dev-workflow-smoke-tests.sh`, naming
   it for what it is: a smoke-test runner that installers and verifiers call. Update the two
   call sites, the two tests that assert its text, `README.md:3932-3937`, `README.md:4121`
   and `docs/macos.md:111`. Keep a thin `scripts/test-dev-workflows.sh` shim for one release
   if the documented path must keep working, matching the existing shim pattern.
2. Give it CI coverage appropriate to its role. A full run needs .NET, Angular, Python,
   OCaml and LaTeX and is too heavy for every push, so add a scheduled workflow (weekly) or
   a `workflow_dispatch` job that runs it on the Fedora container and the macOS runner, and
   add a fast `--dry-run` mode exercised on every push that validates its argument parsing
   and project scaffolding without invoking toolchains or the network.
3. Reorganise `scripts/` explicitly: keep repository tooling (`lint.sh`, `test.sh`,
   `update-starship-themes.sh`) there, move the smoke-test runner to `common/` per step 1,
   and address the shims per F-48.

**Acceptance.** The new fast mode runs in the existing Fedora CI job and fails if argument
parsing breaks. Assert in `tests/test-platform-boundary.sh` that no file under `tests/` and
no file matching `scripts/test-*` is referenced from any `platforms/*/install.sh` or
`platforms/*/scripts/verify*.sh`, which pins the production-versus-test boundary this
finding is about.

### F-36
**All 32 shell tests reimplement their own assertions and stubs, in five incompatible fake-`sudo` dialects**
*medium, maintainability. Support: read.*

**Evidence.** Every test file defines its own helpers. Examples of the divergence:
`tests/test-installer-options.sh:34-41`, `tests/test-markdown-workflow.sh:12-17`,
`tests/test-parrot-ctf.sh:8-13`, `tests/test-containers.sh:213-222`. There are two
incompatible `assert_contains` signatures in the suite (one taking file-then-value, another
taking value-then-file), and five different fake-`sudo` implementations with different
argument handling and logging formats. Command-log stubs are re-derived per file, as the
40-plus `printf ... >>"$COMMAND_LOG"` sites show.

The scalability cost is visible in the repository's own history: a commit had to "mock
openssh-clients in the complete-bootstrap idempotency test" because adding one package to a
baseline list required updating a mock in an unrelated test. Every new baseline package is a
potential edit to several hand-written stubs.

Five tests also create temporary directories with no `EXIT` trap and leak them on failure:
`tests/test-containers.sh:8`, `tests/test-containers-wsl.sh:8`, `tests/test-hardening.sh:11`,
`tests/test-tailscale.sh:8`, `tests/test-wsl-interop.sh:86`.

**Implementation brief.**
1. Create `tests/lib/harness.sh` with one canonical set: `fail`, `pass`,
   `assert_contains <file> <value>`, `assert_line_matches <file> <pattern>` (per F-21),
   `assert_not_contains`, `assert_exit <expected> -- <command...>`, `temp_home` (creating a
   temp HOME and registering an `EXIT` trap), `with_stub_path` (creating a stub bin dir and
   prepending it), `make_recording_stub <name>` (writing a stub that appends its argv to a
   log), and `fake_sudo` (one dialect: strip `sudo`, log the argv, execute the remainder).
   Standardise on the file-then-value argument order already used by the majority.
2. Make the package-manager stubs data-driven so adding a baseline package needs no test
   edit: `make_package_manager_stub dnf` should accept any package and log it, and
   assertions should check the log for expected packages rather than the stub enumerating
   what it accepts. This directly removes the "mock openssh-clients" class of churn.
3. Migrate incrementally, smallest first, keeping `scripts/test.sh` green at each step:
   `test-platform-boundary.sh`, `test-local-state.sh`, `test-secure-boot.sh`,
   `test-power-profiles.sh`, then the larger container and hardening tests. Do not migrate
   and refactor assertions in the same commit; F-21's changes should land separately so a
   behavioural change is never hidden inside a mechanical one.
4. Keep it `shellcheck`-clean: add `# shellcheck shell=bash` at the top of the library since
   it has no shebang, and confirm `scripts/lint.sh` picks it up, since it globs
   `git ls-files -- '*.sh'` and will.

**Acceptance.** `scripts/lint.sh` and `scripts/test.sh` stay green after each migration
commit. Add `tests/test-harness-self.sh` exercising the helpers directly: `assert_exit`
detects a wrong status, `temp_home` cleans up on failure, `make_recording_stub` records argv
faithfully including arguments containing spaces, and `fake_sudo` logs and delegates. Assert
that no migrated test file defines its own `fail()` any more.

---

## 9. Chapter F: shell and tool configuration, and the theme system

*Support for this chapter: the shell-configuration and theme dimensions received a full
audit; the findings below were spot-verified by me where marked.*

### F-12
**Nothing installs a Nerd Font, but the Starship prompt is built from Nerd Font glyphs**
*high, completeness. Support: read.*

**Evidence.** `starship/.config/starship/template.toml` uses Nerd Font glyphs throughout
(`:4`, `:40`, `:49` and beyond) for the prompt's language, git and status symbols. No
platform installs a Nerd Font: there is no font package in
`platforms/fedora/scripts/install-system.sh`, none in `platforms/macos/Brewfile`, none in
the Parrot list. `ghostty/.config/ghostty/config` and `shared.conf` set no `font-family`, so
the terminal uses its default. `platforms/windows/install.ps1` does install fonts for the
Windows host, which is the one place it is handled.

The result on a fresh Fedora or macOS install is a prompt rendering tofu boxes for every
symbol, which is both the most visible possible first impression and trivially avoidable.

**Implementation brief.**
1. Add a Nerd Font to each platform's baseline. Fedora: the appropriate
   `*-nerd-fonts` package from Terra, installed in `install-terra.sh` alongside the other
   Terra-owned packages. macOS: `cask "font-jetbrains-mono-nerd-font"` (or whichever face is
   intended) in `platforms/macos/Brewfile`. Parrot: skip deliberately and record why, since
   the guest is disposable and console-oriented.
2. Set `font-family` explicitly in `ghostty/.config/ghostty/shared.conf` to the installed
   face, so the terminal actually selects it rather than relying on fontconfig ordering.
   Pick the face name from the installed package rather than guessing; verify with
   `fc-list | grep -i nerd` on Fedora and `fc-list` or Font Book on macOS.
3. Add a verify check asserting a Nerd Font is present, since a missing font is exactly the
   kind of cosmetic-but-total breakage verification should catch.
4. Confirm the Windows side installs the same face, so the WSL and host terminals agree.

**Acceptance.** Extend `tests/test-mocked-installs.sh` to assert the Fedora package log
contains the font package, and `tests/test-macos.sh` to assert the Brewfile names the cask.
Add an assertion that `shared.conf` sets `font-family` and that the value matches the
installed package's face name (a literal cross-check is fine here, since both are in the
repository).

### F-32
**PATH is rebuilt without deduplication outside macOS**
*medium, correctness. Support: read.*

**Evidence.** `zsh/.zshenv:5` prepends to PATH unconditionally. `.zshenv` is sourced by
**every** Zsh invocation, including non-interactive subshells, so each nested shell grows
PATH again. Only the macOS overlay
(`platforms/macos/stow/zsh-platform/.config/zsh/platform-env.zsh:3`) uses the deduplicating
form; `platforms/fedora-wsl/.../platform-env.zsh:1` and the Fedora and Parrot overlays do
not. `typeset -U path` is not used in the portable configuration.

This compounds with F-42: the `theme()` wrapper re-execs the shell on every theme switch, so
each switch adds another PATH copy to the new shell's environment.

**Implementation brief.** Add `typeset -U path PATH` to `zsh/.zshenv` **before** any PATH
manipulation. In Zsh this makes the `path` array deduplicating for the lifetime of the
shell and is the idiomatic fix; it also makes the ordering deterministic, which matters for
the manager-precedence question in Chapter B. Then remove the now-redundant per-platform
deduplication from the macOS overlay so there is one mechanism. Verify the resulting order
is still what Chapter B's ownership expectations require, since deduplication keeps the
**first** occurrence and could change which copy of a doubly-installed tool wins.

**Acceptance.** Add `tests/test-shell-startup.sh` running
`zsh -c 'source .zshenv; source .zshrc; print -l $path'` in a controlled HOME, asserting no
duplicate entries, then re-sourcing both files and asserting the length is unchanged. Assert
the relative order of `~/.local/bin`, the mise shim directory and `/usr/bin` matches the
documented intent.

### F-34
**Every interactive shell start runs four unconditional `eval` initialisations and an uncached `compinit`**
*medium, maintainability. Support: read.*

**Evidence.** `zsh/.config/zsh/.zshrc` runs tool initialisations unconditionally at `:2`,
`:18`, `:21`, `:60`, `:77` and beyond, including `eval "$(zoxide init zsh)"` at `:60`. Each
`eval "$(tool init zsh)"` forks a process and waits for it before the prompt appears, and
`compinit` runs without a cached dump. On a slow or loaded machine this is the difference
between an instant and a sluggish shell, and none of it is guarded by whether the tool is
installed, which interacts with the missing-tool cases in Chapter C.

**Implementation brief.**
1. Guard each initialisation on the tool existing, so a platform lacking it degrades to a
   working shell rather than an error on every prompt:
   `command -v zoxide >/dev/null && eval "$(zoxide init zsh)"`.
2. Cache the generated init scripts. Write each `tool init zsh` output to
   `${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/<tool>-init.zsh`, regenerate only when the
   cache is older than the tool binary, and `source` the cache. This removes the forks from
   the common path.
3. Use a cached `compinit`: `autoload -Uz compinit` then `compinit -C -d "$dump"` when the
   dump file is newer than 24 hours, falling back to a full `compinit -d "$dump"` otherwise.
   Keep the security check on the slow path only.
4. Measure before and after with `for i in {1..10}; do time zsh -i -c exit; done` and record
   the numbers in the commit message, so the change is justified by data rather than
   assumption.

**Acceptance.** Extend `tests/test-shell-startup.sh` to assert that with an empty stub PATH
(no `zoxide`, `starship`, `mise`, `direnv`) an interactive shell starts successfully and
prints no error, and that a second start reuses the cache rather than regenerating it (assert
via a recording stub that `tool init` is not re-invoked).

### F-42
**`docs/keybindings.md` attributes the shell restart to the `theme` binary; it lives in the Zsh wrapper**
*low, documentation. Support: executed.*

**Evidence.** `docs/keybindings.md` states that `theme` "updates tmux, Ghostty/Noctty,
Starship, bat, and Lazygit theming together ... and restarts the current shell."

`bin/.local/bin/theme` contains **zero** occurrences of `exec zsh` or `exec $SHELL`
(verified by grep). The restart is in the Zsh function wrapper at
`zsh/.config/zsh/.zshrc:54-57`:
```bash
theme() {
  command theme "$@" || return
  exec zsh
}
```
So the documented behaviour is a property of the interactive Zsh function, not of the
command. It does not happen when `theme` is called from a script, from a theme hook, or from
any non-Zsh shell, which is precisely when someone reading the documentation would rely on
it.

A related low-severity consequence of the same wrapper: it re-execs after **any** successful
invocation, including `theme --help`, so asking for help replaces your shell.

**Implementation brief.** Correct the documentation to attribute the behaviour accurately:
state that the `theme` command rewrites the derived theme state and reloads what it can, and
that the Zsh wrapper additionally re-execs the shell so already-exported variables are
refreshed. Then narrow the wrapper so it does not re-exec for informational invocations:
```bash
theme() {
  case "${1:-}" in
    -h | --help | --print | "") command theme "$@"; return ;;
  esac
  command theme "$@" || return
  exec zsh
}
```
Check `bin/.local/bin/theme`'s actual option set (`:22`, `:24`) and match the case list to
it rather than copying the above verbatim.

**Acceptance.** Extend `tests/test-theme.sh` to assert `docs/keybindings.md` describes the
wrapper and the command separately. Add a case running the wrapper with `--help` in a
subshell and asserting no re-exec occurred (for example by checking a marker variable
survives).

### F-54
**The four tracked Starship flavour files are generated, with no drift gate**
*medium, maintainability. Support: executed.*

**Evidence.** `scripts/update-starship-themes.sh` generates
`starship/.config/starship/catppuccin-{latte,frappe,macchiato,mocha}.toml` from
`template.toml` by rewriting only the `palette = ` line. Those four generated files are
tracked. Nothing in `scripts/lint.sh`, `scripts/test.sh` or CI regenerates them and compares.

**I checked the current state: all four are in sync with `template.toml` right now.** So this
is a missing gate, not present drift. The exposure is that the next edit to `template.toml`
that skips the regeneration step ships four stale prompt configurations silently, and because
the generator only rewrites one line, the staleness would be invisible to a casual diff.

**Implementation brief.** Add a drift check to `scripts/lint.sh` (so it runs in both CI
jobs): regenerate into a temporary directory and `diff` against the tracked files, failing
with the exact command to fix it. Add `--check` to `scripts/update-starship-themes.sh` and
call that, so the generator owns the comparison:
```bash
if [[ "$check_only" == "true" ]]; then
  diff -u "$output_dir/catppuccin-${flavour}.toml" "$tmp/catppuccin-${flavour}.toml" ||
    die "starship/${flavour} is stale; run ./scripts/update-starship-themes.sh"
fi
```
Consider whether the generated files should be tracked at all. Tracking them means stow can
link them directly with no build step at install time, which is a good reason to keep them;
the gate is what makes that safe.

**Acceptance.** `scripts/lint.sh` fails when `template.toml` is edited without regenerating.
Prove it: in a scratch commit, change a non-palette line in `template.toml`, run
`./scripts/lint.sh`, confirm failure, then regenerate and confirm it passes.

### F-55
**`apply-kde-theme.sh` applies Catppuccin Plasma identifiers that `--no-kde` never installed**
*high, correctness. Support: read.*

**Evidence.** `platforms/fedora/scripts/apply-kde-theme.sh:112,179,180` applies global
theme, colour scheme and cursor identifiers that the Catppuccin KDE packages provide. Those
packages are installed by `platforms/fedora/scripts/install-kde-theme.sh`, which
`platforms/fedora/install.sh:855` runs only when `install_kde` is true. The theme hook that
calls `apply-kde-theme.sh` gates on the Plasma **binaries** being present, not on the
Catppuccin packages being installed.

So a user who installs on KDE Plasma (the declared primary target) with `--no-kde`, whose
documented effect is to skip the Catppuccin KDE integration, still gets `theme <flavour>`
attempting to apply Plasma theme identifiers that do not exist on the machine. Depending on
the tool, that either errors (which per F-52 then aborts the rest of the switch, including
the Ghostty and Sway reloads) or silently applies nothing.

**Implementation brief.**
1. Record whether the KDE integration was installed, in machine-local state, the same
   mechanism F-05 introduces. `install-kde-theme.sh` writes it; the absence of the file means
   not installed.
2. Gate `apply-kde-theme.sh` on that state rather than on `command_exists plasmashell`. When
   the state says not installed, return 0 with an `info` explaining that the KDE integration
   was not installed so the desktop theme is being left alone. That is the correct behaviour
   for `--no-kde` and it stops the hook from failing.
3. Additionally verify the specific theme identifiers exist before applying them, so a
   partially installed package set degrades to a warning rather than an error.
4. Combine with F-52 so that even if this step does fail, the Ghostty and Sway reloads still
   run.

**Acceptance.** Extend `tests/test-kde-theme.sh` with a case where the KDE state file is
absent and the Plasma binaries are stubbed as present, asserting `apply-kde-theme.sh` exits 0
and records **no** `plasma-apply-*` or `kwriteconfig6` side effects. Add a case with the
state present asserting the side effects are recorded as they are today.

---

## 10. Chapter G: documentation and cheat sheets

This chapter covers the requested "completeness of the cheat sheets". The full
binding-versus-documentation inventory is Appendix D.

*Support: the keybinding inventory received a full dedicated pass and I verified its three
sharpest claims directly. The README-accuracy dimension did not get a dedicated audit, so
the README findings here are the ones surfaced by other dimensions plus my own checks, not
an exhaustive sweep of 4462 lines. That gap is stated in section 13.*

### F-39
**`docs/cheatsheets/README.md` claims `keybindings.md` is the same content as `common-workflow.tex`; it is a strict superset**
*medium, documentation. Support: executed.*

**Evidence.** `docs/cheatsheets/README.md:20-22` states that `keybindings.md` "is the same
shared content as an ordinary Markdown page, for reading on screen or linking from the
README instead of opening a PDF."

Measured: `docs/cheatsheets/common-workflow.tex` contains **zero** occurrences of
`localleader`, `VimTeX` or `vimtex`, and has no Markdown-table section. `docs/keybindings.md`
carries a full `### LaTeX` section at `:154-173` documenting the `\l`-prefixed VimTeX and
TexLab bindings, and a Markdown and table-nvim section at `:132-152`.

So the two are not the same content, and a user who prints the sheet believing the README's
claim gets strictly less than the Markdown page.

**Implementation brief.** Decide which is canonical and make the claim true. Recommended:
treat `keybindings.md` as canonical and `common-workflow.tex` as a printable subset, then
correct `docs/cheatsheets/README.md:20-22` to say exactly that, naming which sections the
printable sheet omits and why (page budget). The alternative, bringing the sheet up to
parity, is F-40.

**Acceptance.** Extend `tests/test-cheatsheet-bindings.sh` to assert that every `###`
section heading in `keybindings.md` either appears in `common-workflow.tex` or is listed in
an explicit, commented `PRINTABLE_SHEET_OMITS` allowlist in the test. That makes the
divergence a deliberate, reviewed decision instead of drift.

### F-40
**No rendered cheat sheet carries the LaTeX or Markdown-table bindings**
*medium, completeness. Support: executed.*

**Evidence.** Following from F-39: the `\ll`, `\lv`, `\le`, `\lo`, `\lt` and `\li` VimTeX
bindings and the `<leader>m*` table-nvim bindings (`nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua:38-48`)
appear in `docs/keybindings.md` and in **none** of the five `.tex` files. The printable A4
sheets are the artefact the README presents as the per-profile reference, so the bindings for
two supported workflows are absent from every printable reference.

**Implementation brief.** Add a compact LaTeX section and a Markdown-table section to
`docs/cheatsheets/common-workflow.tex`, using the existing `\csrow` macro from
`cheatsheet.sty` so the layout stays consistent. Keep them terse: the local-leader prefix
plus the six VimTeX bindings, and the seven table-nvim bindings, are about 13 rows. If the
A4 page budget genuinely will not take them, put them on the profile sheets that can have
LaTeX installed (`fedora-kde`, `fedora-sway`, `fedora-wsl`) and record the decision per
F-39's allowlist. Check the rendered PDF page count before and after, since the sheets are
designed to be a single page.

**Acceptance.** `docs/cheatsheets/generate.sh` still produces a one-page PDF for each sheet
(assert the page count, not just successful compilation). The F-39 acceptance test then
covers the content.

### F-41
**Twenty repo-defined bindings appear in no cheat sheet and not in `keybindings.md`**
*medium, completeness. Support: read (inventory), representative items verified.*

**Evidence.** The full table is Appendix D, section 2. Grouped by the sheet that should own
them:

*fedora-sway:* `Super + mouse drag` for floating windows
(`platforms/fedora/stow/sway/.config/sway/config:17`); the three Waybar click handlers for
network, bluetooth and audio (`waybar/config.jsonc:40,48,53`); the
`power-profile-status` module (`waybar/config.jsonc:25-29` plus its script); the
`sway-screenshot` notification behaviour.

*macos:* `Ctrl+Opt+E` for `layout tiles horizontal vertical`
(`aerospace.toml:72`), whose Sway peer `Super+E` **is** documented, so this is a parity gap
in the documentation itself.

*common-workflow:* the three EasyDotnet test bindings `<leader>tr`, `<leader>tt`,
`<leader>td` (`plugins/dotnet.lua:100,105,110`); the seven table-nvim bindings per F-40.

*No sheet exists to own them:* the Parrot `bat` and `fd` command shims
(`platforms/parrot-ctf/stow/command-shims/.local/bin/{bat,fd}:2`).

The repository's own binaries are the most consequential group, because a user cannot
discover them without reading the source: `theme`, `wsl-copy`, `wsl-open`, `wsl-paste`,
`sway-workspace-grid`, `sway-screenshot`, `sway-session-start`, `power-profile-status`,
`aerospace-workspace-grid`. Several are documented; the discovery story for the rest is
non-existent, and the README's stated philosophy of learning bindings "through each tool's
own discovery mechanism" does not apply to bespoke scripts, which have none.

**Implementation brief.**
1. Add the missing rows to the sheets named above, using `\csrow`.
2. Add a "Repository-provided commands" section to `docs/keybindings.md` listing every
   executable this repository installs into `~/.local/bin`, with a one-line purpose and its
   defining path. Generate the list from the stow packages rather than maintaining it by
   hand: the `bin` package plus each platform's `stow/*/.local/bin/*`.
3. Decide the Parrot question explicitly: either add a fifth sheet or record in the README's
   Parrot section that the CTF guest gets no printable sheet because it is a disposable
   profile with a deliberately reduced surface. Either is defensible; the current silence
   is not.

**Acceptance.** See F-56, which is the enforcement mechanism that keeps this from
re-drifting.

### F-56
**`tests/test-cheatsheet-bindings.sh` cannot detect a binding that exists in no document**
*medium, testing. Support: read.*

**Evidence.** The test passes today (I ran it) while the 20 bindings in F-41 are
undocumented. That is definitional: the test validates consistency for bindings it knows
about rather than enumerating what the configuration defines and requiring each to be
documented. It therefore cannot catch an *addition* that nobody documented, which is the
drift that actually happens.

**Implementation brief.** Build the registry the test needs.
1. Add `tests/lib/extract-bindings.sh` with one extractor per configuration format, each
   emitting `<source>\t<binding>\t<action>` lines:
   - sway: `grep -E '^\s*bindsym' platforms/fedora/stow/sway/.config/sway/config`
   - aerospace: parse the `[mode.*.binding]` tables from the TOML
   - tmux: `grep -E '^\s*bind(-key)?' tmux/.tmux.conf`
   - Neovim: `grep -oE 'keys\s*=\s*\{.*' plus `vim.keymap.set` over
     `nvim-lazyvim/.config/nvim/lua/**` and the two platform overlays
   - ghostty: `grep -E '^\s*keybind' ghostty/.config/ghostty/{config,shared.conf}`
   - waybar: extract `on-click*` values from `config.jsonc`
   - zsh: `grep -E '^\s*bindkey' over the platform overlays
2. Add `docs/cheatsheets/upstream-defaults.allow` listing bindings that are upstream
   defaults the sheets deliberately document without owning, with a comment per entry. This
   is what makes the check tractable, since the sheets legitimately document upstream keys.
3. Have `tests/test-cheatsheet-bindings.sh` assert, for every extracted binding not in the
   allowlist, that it appears in at least one of the five `.tex` files or `keybindings.md`;
   and conversely that every binding a sheet presents as repository-defined is in the
   extracted set. Fail with the specific binding and the file that should carry it, so the
   message tells the author what to do.

**Acceptance.** Add a new `bindsym` to the Sway config in a scratch commit and confirm the
test fails naming it and pointing at `fedora-sway.tex`; document it and confirm the test
passes. Do the reverse for a documented-but-undefined binding. Both negative controls must
be demonstrated, since a registry test that silently matches nothing is worse than none.

### F-43
**`platforms/macos/install.sh` prints a usage synopsis that installs the wrong platform if followed**
*low, documentation. Support: executed.*

**Evidence.** Running `./install.sh --platform macos --help` prints the dispatcher banner,
then "Options for platform 'macos'", then a second synopsis: `Usage: ./install.sh [options]`.

The four platform installers disagree:

| File | Synopsis |
|---|---|
| `platforms/fedora/install.sh:33` | `Usage: ./install.sh [options]` (correct, Fedora is the default) |
| `platforms/fedora-wsl/install.sh:25` | `Usage: ./install.sh --platform fedora-wsl [options]` (correct) |
| `platforms/parrot-ctf/install.sh:15` | `Usage: ./install.sh --platform parrot-ctf [options]` (correct) |
| `platforms/macos/install.sh:20` | `Usage: ./install.sh [options]` (**wrong**) |

macOS is the odd one out. A user following its synopsis literally, for example
`./install.sh --theme latte`, installs the **Fedora** profile.

**Implementation brief.** Change `platforms/macos/install.sh:20` to
`Usage: ./install.sh --platform macos [options]`. Then remove the duplicated banner: have
the dispatcher not print its own usage before exec-ing when `--help` is present for a
non-default platform, or have the platform scripts omit the synopsis line when invoked
through the dispatcher (pass a variable). One banner, correct for the selected platform.

**Acceptance.** Add to `tests/test-installer-options.sh` a case per platform asserting the
`--help` output contains exactly one `Usage:` line and that it names the correct
`--platform` value (or omits it for Fedora).

### F-44
**`./install.sh --platform=macos` silently misroutes to Fedora**
*low, correctness. Support: read.*

**Evidence.** `install.sh:10-19` matches only the space-separated `--platform` form. The
`--platform=macos` equals form falls through to the catch-all at `:19` and is appended to
`forwarded_args`, so the dispatcher keeps its default of `fedora` and execs the Fedora
installer, which then reports `--platform=macos` as an unknown option
(`platforms/fedora/install.sh:308`). The error names the option rather than the real mistake,
and on a Mac the user is told an option is unknown when the actual problem is that they are
about to run the wrong platform.

**Implementation brief.** Handle both forms in the dispatcher:
```bash
--platform=*)
  platform="${1#*=}"
  shift
  ;;
```
placed before the existing `--platform)` case. Validate identically. While there, reject an
empty value from the equals form explicitly.

**Acceptance.** Add to `tests/test-installer-options.sh` assertions that
`--platform=macos --dry-run` produces the macOS plan, that `--platform=` fails with a clear
message, and that an unknown `--platform=bogus` produces the same error as the
space-separated form.

---

## 11. Chapter H: structural maintainability and lifecycle

This chapter covers the requested "maintainability ... of the total solution".

*Support: the maintainability dimension did not receive a dedicated audit pass. The findings
below are ones I established directly, plus structural observations the other dimensions
surfaced. This chapter is therefore less exhaustive than Chapters A through E.*

### F-38
**No lifecycle beyond install: no update, uninstall, rollback, or installed-revision record**
*medium, completeness. Support: read.*

**Evidence.** The repository provides `install.sh` and `verify.sh` per platform. There is no
update path, no uninstall, no per-profile rollback, and nothing records which revision a
machine was built from. `platforms/fedora/scripts/install-hardening.sh:35` refers to the
README documenting "rollback instructions for each" hardening change, which is the only
rollback story anywhere and it is prose rather than code.

For a repository whose purpose is to rebuild a workstation on a bad day, and which is
expected to survive years of Fedora and macOS upgrades, the missing operations matter in a
specific order:

1. **Installed-revision stamp.** Cheapest and highest value. Without it, a machine cannot
   report what it was built from, so no other lifecycle operation can reason about it.
2. **Update.** Currently "re-run the installer", which is close to correct given the good
   idempotency, but it is not stated as a supported operation and nothing tests it against a
   previously installed machine rather than a clean one.
3. **Per-profile uninstall.** Most valuable for `--hardening` (which changes PAM, sudoers and
   sysctl), `--containers`, `--tailscale` and `--vm-host`, all of which add system state a
   user may want to remove without rebuilding.
4. **Rollback of a failed run.** Largely subsumed by making re-runnability an explicit,
   tested guarantee per F-24.

**Implementation brief.**
1. Write an install stamp. At the end of a successful run, have each platform installer write
   `"${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/install-state.json"` through
   `atomic_write_file`, containing: the platform, the resolved option set, the repository
   `git rev-parse HEAD`, whether the tree was dirty (`git status --porcelain`), the UTC
   timestamp, and a schema version. Note that `atomic_write_file` chmods 600, which is fine
   here.
2. Read it back. Have `verify.sh` print the recorded revision and options at the top of its
   report, and compare the recorded option set against what it was asked to verify, warning
   on a mismatch. This closes the loop that F-05 and F-53 both need.
3. Add `platforms/<p>/scripts/uninstall-<profile>.sh` for the profiles that add system state,
   starting with hardening per F-20 step 3. Each must capture pre-change state at install
   time into machine-local state, so the uninstall restores rather than guesses.
4. Document the lifecycle in a new `docs/lifecycle.md`: how to update, what re-running
   guarantees, which profiles can be removed and how, what is not reversible, and how to read
   the install stamp. Link it from the README.

**Acceptance.** Extend `tests/test-local-state.sh` to assert the stamp is written with the
expected fields and a plausible revision, and that a second run updates it rather than
duplicating it. Add a test asserting `verify.sh` prints the recorded revision. For each
uninstall script, a test that installs into a mocked environment, uninstalls, and asserts the
recorded system changes are reverted.

### F-48
**Four `scripts/` shims are referenced by nothing, and the directory mixes shims with real tooling**
*low, hygiene. Support: executed.*

**Evidence.** `scripts/` holds roughly 20 thin shims that `exec` into
`platforms/fedora/scripts/*`, plus real tooling. Reference analysis across the whole
repository including README, docs, tests and CI shows four shims that nothing points at:

| Shim | References |
|---|---|
| `scripts/apply-kde-theme.sh` | none |
| `scripts/install-kde-theme.sh` | none |
| `scripts/install-mise.sh` | none |
| `scripts/install-neovim-tools.sh` | none |

The rest **are** referenced, mostly by `README.md` (which documents them as the user-facing
entry points) and by tests. So a blanket deletion would be wrong, and my earlier reading that
the shims were broadly dead was mistaken. Two further shims are effectively dead in a
different way: `scripts/lib/common.sh` and `scripts/lib/theme-state.sh` exist only to keep an
old sourcing path working, nothing uses that path, and the theme-state one sources only
`common/lib/theme-state.sh` and therefore could not satisfy a caller expecting the Fedora
functions (see F-49).

`scripts/test-installer.sh` is now only a deprecation notice.

**Implementation brief.**
1. Delete the four unreferenced shims and both `scripts/lib/` files. Confirm with a fresh
   reference scan immediately before deleting, since the README is large and a reference may
   be added after this audit.
2. Decide a policy for the rest and write it down in a short `scripts/README.md`: these shims
   exist because the README documents them, they are the stable public entry points, and new
   code should call `platforms/<p>/scripts/*` directly. Give them a removal horizon, or state
   that they are permanent public API. Either is fine; the undocumented middle is not.
3. Separate concerns in the directory. Repository tooling (`lint.sh`, `test.sh`,
   `update-starship-themes.sh`) stays. The smoke-test runner moves to `common/` per F-28.
   Consider moving the shims to `scripts/compat/` so the directory listing distinguishes
   public entry points from tooling at a glance, updating the README references in the same
   commit.
4. Remove `scripts/test-installer.sh` once its deprecation horizon passes.

**Acceptance.** `scripts/lint.sh` and `scripts/test.sh` stay green. Add to
`tests/test-platform-boundary.sh` an assertion that every file in `scripts/` is either
referenced from the README, referenced from a test, or listed in an explicit allowlist in the
test, so a new unreferenced shim cannot accumulate silently.

### F-49
**Three files named `theme-state.sh` have three unrelated responsibilities**
*low, maintainability. Support: executed.*

**Evidence.** My first reading of this was that the file was triplicated. It is not, and the
real problem is arguably worse for a reader:

| File | Lines | Actual responsibility |
|---|---|---|
| `common/lib/theme-state.sh` | 18 | the portable `write_theme_state` helper |
| `platforms/fedora/lib/theme-state.sh` | 244 | the Fedora desktop palette, wallpaper and cursor logic |
| `scripts/lib/theme-state.sh` | 4 | a shim sourcing only the `common/` one |

Three identically named files, three different jobs, and the shim cannot serve a caller that
wants the Fedora functions. `platforms/fedora/scripts/setup-local.sh:6-9` sources both real
files in sequence, which is the only place the layering is visible. A `grep theme-state` in
this repository returns hits that strongly suggest duplication where there is none, which
costs every future reader time.

**Implementation brief.** Rename for responsibility rather than consolidating, since the two
real files are correctly separated:
- `common/lib/theme-state.sh` -> `common/lib/theme-state.sh` (keep; it is the generic one)
- `platforms/fedora/lib/theme-state.sh` -> `platforms/fedora/lib/desktop-theme.sh`
- delete `scripts/lib/theme-state.sh` per F-48

Update the sourcing sites: `platforms/fedora/scripts/setup-local.sh:8`,
`platforms/fedora/scripts/apply-kde-theme.sh:7`, and
`platforms/fedora/stow/theme-hooks/.config/dotfiles/theme-hooks.d/fedora.sh:4`. Update the
`# shellcheck source=` directives in the same edit, or `scripts/lint.sh` will fail.
Document the two-layer contract in the `docs/theming.md` that F-51 creates.

**Acceptance.** `scripts/lint.sh` passes (it will catch a stale `shellcheck source=` path) and
`scripts/test.sh` passes. Assert in `tests/test-theme.sh` that the renamed file is sourced by
the hook and that the generic helper is not expected to provide the Fedora functions.

### F-47
**Executable bits are inconsistent across the library files**
*low, hygiene. Support: executed.*

**Evidence.** Of the 15 library files meant to be sourced rather than executed, three carry
the executable bit and 12 do not:

| Executable | Not executable |
|---|---|
| `common/lib/common.sh` | the other 12, including all `platforms/fedora/lib/*.sh` except `tailscale.sh` |
| `platforms/fedora/lib/tailscale.sh` | |
| `platforms/parrot-ctf/lib/parrot.sh` | |

Sourced libraries should not be executable, since executing them does nothing useful and the
bit implies otherwise.

Separately, `common/verify-ai.sh` is an executable entry point yet declares only `set -u` and
relies on the library for its options, which is F-15's subject.

**Implementation brief.** `chmod -x common/lib/common.sh platforms/fedora/lib/tailscale.sh
platforms/parrot-ctf/lib/parrot.sh`. Verify none is invoked directly anywhere first
(`grep -rn 'lib/tailscale.sh\|lib/parrot.sh' --exclude-dir=.git .`); they should only ever be
sourced. Then add a mode check to `scripts/lint.sh` so it cannot drift: every file under a
`lib/` directory must be non-executable, and every other tracked `.sh` that is not under
`lib/` and is not a stow-package config fragment must be executable. The `fzf` theme files
under `fzf/.config/fzf/themes/` are sourced config fragments and correctly non-executable, so
the rule needs to key off directory rather than extension alone.

**Acceptance.** The new `scripts/lint.sh` check fails on a deliberately `chmod +x`-ed library
file and passes on the corrected tree.

### F-50
**No repository LICENSE, and an empty `package-lock.json` stub with no `package.json`**
*low, hygiene. Support: executed.*

**Evidence.** `LICENSES/Catppuccin.txt` exists, correctly attributing the upstream palette,
but there is no repository-level `LICENSE`. `package-lock.json` at the repository root
contains:
```json
{ "name": "dotfiles", "lockfileVersion": 3, "requires": true, "packages": {} }
```
with no `package.json` anywhere and no npm-managed dependency in the repository. Also absent:
`.editorconfig`, `.shellcheckrc`, and any root `AGENTS.md` or `CLAUDE.md` (the tracked
`common/assets/AGENTS.md` is a stowed asset that the AI profile links into agent config
directories, not repository guidance).

**Does this matter for a personal dotfiles repository?** Partly. Being honest about which
items are real:
- **The missing LICENSE does matter**, because the repository is public. Without one, the
  default is all rights reserved, so nobody can reuse the configuration the README implicitly
  invites them to. Given `LICENSES/Catppuccin.txt` shows attention to upstream licensing, this
  is likely an oversight rather than a decision.
- **The `package-lock.json` stub is genuine debris.** It is inert, but it makes tooling and
  readers believe there is a Node project here.
- **`.editorconfig` and `.shellcheckrc` are optional**, though a `.shellcheckrc` would let
  `scripts/lint.sh` drop its `-x -P SCRIPTDIR -s bash` flags into config and keep editor
  integrations consistent with CI, which has real value given how much shell this is.
- **A root `AGENTS.md` would help**, given how much of this repository's history is
  agent-authored: it is where the repository's own conventions belong (the shell style, the
  verify contract, the parity expectations this audit recommends).

**Implementation brief.** Add a `LICENSE` (MIT is the conventional choice for dotfiles;
confirm it is compatible with everything vendored, which for a configuration repository it
will be) and reference it from the README alongside the existing Catppuccin attribution.
Delete `package-lock.json`. Add a `.shellcheckrc` carrying the options `scripts/lint.sh`
passes and simplify the lint invocation accordingly. Add `.editorconfig` covering shell, Lua,
TOML and Markdown indentation to match the existing style. Consider a root `AGENTS.md`
recording the conventions this audit recommends fixing, so they are enforced socially as well
as by tests.

**Acceptance.** `scripts/lint.sh` still passes after moving options into `.shellcheckrc`
(prove it by deliberately introducing a violation and confirming it is still caught). Assert
in a hygiene test that `package-lock.json` is absent and `LICENSE` is present.

### Extension cost, as a summary observation

The recurring theme across Chapters C, D and E is that adding anything requires touching a
number of files that nobody has counted. Working from the option matrix and the ownership
inventory, adding one optional profile to one platform today means editing: the platform
installer's option parser, its usage text, its dry-run heredoc, its execution sequence, the
platform verifier, `README.md`, the relevant `.tex` cheat sheet if it binds anything,
`tests/test-installer-options.sh`, and whichever mocked-install test covers the packages. That
is nine places, four of which are prose, and none of which is checked against the others.

Every finding in this report that takes the form "X exists on platform A but not B" is a
symptom of that, not an independent mistake. The single highest-leverage structural change is
therefore the parity assertion:

**Add `tests/test-platform-parity.sh`** that builds the option and capability matrix by
parsing each platform installer's option parser, and asserts every cell is either implemented
or listed in an explicit `PARITY_EXCEPTIONS` table with a one-line reason that must also
appear in the README. Fedora WSL's `--tailscale` rejection is the model: the boundary is
enforced in code, explained in the error message, and documented. Making every other gap look
like that one converts this whole class of finding from a recurring defect into a reviewed
decision, and it is the change that would have prevented F-02, F-07, F-08, F-09, F-27, F-37
and F-51.

---

## 12. Recommended implementation sequence

Ordered by dependency, not by severity alone. Batches 1 and 2 are the ones I would not
defer.

### Batch 1: unblock the fresh-machine path (do first)

These are independent of everything else and two of them are the only defects that can stop
an install outright.

| Finding | Why first |
|---|---|
| F-01 | The only critical. A fresh Mac is the case with no workaround available to the user. |
| F-02 | One package. Fixes a hard-failing documented feature, unblocks F-06, and removes a parity gap. |
| F-15 | One line, verified safe, and it must land **before** Chapter D's work so the verify scripts have the semantics their authors intended while you edit them. |
| F-47, F-50 | Trivial hygiene, no interactions, clears noise from every later diff. |

Do F-15 before F-03, F-05, F-06 and F-20. Editing verify-script control flow while the
effective shell options are not the declared ones is how subtle mistakes get made.

### Batch 2: make verification mean something

Sequenced deliberately: create the shared library first, then fix each defect once in the
shared copy rather than 13 times.

1. **F-35** create `common/lib/verify.sh` and define the pass/fail contract. Migrate the
   smallest verifier first.
2. **F-03** fix `check_symlink` in the shared copy. This is the highest-value single fix in
   the chapter, because it is the most-used helper and the failure it misses is the most
   likely one.
3. **F-14** move `check_mise_owned` into the shared library and use it everywhere.
4. **F-35 (second half)** generalise `check_command_runs`, the primitive the repository
   already invented, across the verifiers.
5. **F-05, F-53** introduce recorded install state and make the containers checks conditional
   on intent. F-05 and F-53 are the same fix seen from two platforms; do them together.
6. **F-06** dependency guard for `jq` (F-02 already removed the root cause).
7. **F-20** reclassify the hardening artifacts to `fail`, gated on recorded state from step 5.
   This depends on step 5 and must not land before it, or every non-hardened machine fails.

### Batch 3: make the tests able to fail

| Order | Finding | Note |
|---|---|---|
| 1 | F-17 | Do this first. Until the runner reports all failures, every later test fix is hard to evaluate. |
| 2 | F-04 | One-line change, then triage the assertions that have never run. Expect real failures. |
| 3 | F-18 | Decouple from clone depth and fix the silent production degradation. |
| 4 | F-21 | Convert the tautological assertions, with negative controls proving each can now fail. |
| 5 | F-36 | The harness extraction. Do it **after** the above, and never in the same commit as a behavioural change. |
| 6 | F-28 | Move the smoke-test runner out of the test namespace and give it CI coverage. |

F-36 last in this batch is deliberate: extracting a shared harness while individual tests are
also being corrected makes both changes hard to review.

### Batch 4: close the parity gaps, then lock them

The individual fixes are independent of each other, so order within the group by whichever
platform you use most. The enforcement mechanism goes last, because it needs the exceptions
table populated with the decisions the earlier fixes make.

1. F-07 (macOS login shell), F-08 (macOS OCaml verification), F-09 (macOS LaTeX: implement or
   withdraw), F-27 (unify the smoke-test flag name), F-46 (Parrot login-shell helper),
   F-51 (macOS theme hooks), F-10 (Parrot editor profile), F-37 (Windows verify script).
2. **The parity assertion** from the end of Chapter H. This is the change that prevents the
   whole class from recurring, and it is worth more than any single fix above it.

### Batch 5: robustness and correctness follow-ups

Independent of each other; schedule as convenient.

F-19 (stow preflight, hoisted before privileged work), F-22 (retry helper), F-23 (privilege
preflight), F-24 (ERR trap and the tested re-run guarantee), F-25 (theme reset on re-run),
F-26 (negative-flag tri-state, applied to every `--no-*`), F-13 and F-30 (download
verification), F-52 and F-55 (theme hook isolation and the `--no-kde` gate), F-45 (`confirm`),
F-44 (`--platform=` form), F-43 (usage synopsis).

Note two sequencing constraints: **F-24 depends on F-16** if you adopt the step registry,
because both want the step labels to exist exactly once. And **F-25 and F-51/F-52 both touch
the theme path**, so do them in one pass over `bin/.local/bin/theme` and the hooks rather than
twice.

### Batch 6: structural and documentation work

F-16 (dry-run projection; the larger Option A is worth it if you adopt the step registry),
F-38 (lifecycle: the install stamp first, it is cheap and everything else reads it),
F-48 and F-49 (shim cleanup and the `theme-state.sh` renames), F-29 (macOS `gnubin`
decision), F-31 (CSharpier), F-32, F-34 (shell startup), F-33 (pinning policy and the
honest reproducibility claim), F-12 (Nerd Font), F-54 (Starship drift gate),
F-39, F-40, F-41, F-56 (cheat sheets and the binding registry), F-42.

F-56 depends on F-41: populate the sheets first, then turn on the check that keeps them
populated. The same relationship holds for F-33 and F-38: decide the pinning policy before
writing the stamp that records it.

### A note on what to do about the README

The README-accuracy dimension did not get a dedicated pass (section 13), so I am not
proposing the 4462-line split as a graded finding. But several findings here are README
defects (F-02's `jq` claim at `:2344`, F-07's login-shell claim at `:137`, F-09's macOS
LaTeX documentation, F-33's reproducibility claim, F-39's cheat-sheet equivalence claim), and
they share a cause: prose that duplicates behaviour, with nothing checking the copy. Before
investing in restructuring, the higher-value change is a small number of tests that pin the
claims a user would act on: the baseline tool list, the option defaults, and the per-platform
capability statements. Those are the sentences that cost someone a broken install when they
are wrong.

---

## 13. Coverage, limitations, and what I would look at next

Stated plainly so the report is not read as more complete than it is.

**Fully audited, with the highest-severity findings independently re-verified by me:**
installer core and dispatch; the three non-default platform installers; cross-platform
parity; package-manager boundaries; installation robustness and idempotency; the
verification scripts; the test suite; shell and tool configuration; the theme system.

**Covered but not exhaustively:**

- **README accuracy.** The dedicated pass over 4462 lines did not complete. I verified the
  specific claims that other findings depend on, and every one I checked was wrong in the way
  the finding describes, which is itself a signal. A systematic sweep would very likely find
  more, and the mechanical high-value check I did not run is: confirm every repository path
  referenced anywhere in the README actually exists.
- **Neovim and Mason.** I established F-04 empirically and F-31, and Chapter B covers the
  ownership split from the package inventory. Not covered: whether the stow overlay mechanism
  (`nvim-wsl`, `nvim-macos` dropping files into `.config/nvim/lua/plugins/`) actually loads
  given `lua/config/lazy.lua`'s spec imports. That is a load-order question that deserves a
  direct answer, and if the overlays do not load, the platform-specific editor configuration
  is silently inert on two platforms.
- **Security and hardening.** I covered download trust (F-13, F-30), the hardening verify
  gap (F-20) and the absence of rollback (F-38). Not covered: a systematic review of every
  `sudo` call site for necessity and minimality; what `--containers-api-socket` actually
  exposes and whether the socket's permissions are right; whether the hardening profile
  conflicts with the containers, libvirt, Tailscale or portal profiles; and the AI profile's
  credential handling and the filesystem access the `--gnhf` and `--backpass` tools receive.
  That last item is the one I would prioritise, because the help text describes `--gnhf` as
  unattended and overnight, and the audit did not establish what it is authorised to do.
- **Windows and WSL.** F-11 and F-37 are solid. `install.ps1`'s 684 lines received a
  hygiene-level read, not a line-by-line audit: elevation handling, the WSL distro import,
  registry writes and per-step idempotency are unverified. The two-sided sequencing contract
  between `install.ps1` and the Linux installer is also unverified, and it is the kind of
  thing that is only wrong once, on a fresh machine.

**Method limitations:**

- I could not install Bash 3.2, so F-01 rests on the documented Bash 4.4 behaviour change
  plus the unguarded call sites and the CI evidence, not an observed crash.
- The container is Debian-based, not Fedora 44, so `scripts/test.sh` cannot complete here.
  Fifteen of 32 tests ran; the rest are unverified by execution, and CI is green on `main`
  as far as I could tell, so I am not claiming the suite fails in its intended environment.
- The adversarial verification stage of my process did not run, twice interrupted by usage
  limits. For the nine audited dimensions I substituted my own direct verification of the
  critical and high findings, which is why every one of those carries either "Executed" or an
  explicit note about what supports it. The medium and low findings marked "Read" are
  single-source: their evidence is real and cited, but a second pair of eyes did not
  challenge the reasoning or the proposed fix. Treat the implementation briefs for those as
  strong proposals rather than settled conclusions.

**If you want the gaps closed**, the four I would run next, in order: the AI profile's
security posture; whether the Neovim platform overlays load at all; a systematic
README-claim sweep; and a line-by-line pass on `install.ps1`.

---

# Appendices: reference inventories

These four inventories are the factual ground truth the report was built on. They contain no
findings and no opinions. Each was produced by a dedicated pass over the named files, and I
spot-verified each one against source before relying on it; every claim I checked held up.
They are included in full because they are useful independently of this audit, as a map of
what the repository actually does.

## Appendix A: option and profile matrix



`./install.sh` is a dispatcher only. It consumes `--platform NAME` (default `fedora`), validates it against `fedora|fedora-wsl|macos|parrot-ctf`, prints a usage banner if `-h/--help` appears anywhere in the remaining args (then still `exec`s the platform script), and `exec`s `platforms/$platform/install.sh` with all other args. It knows nothing else about options. `platforms/windows/install.ps1` is not reachable through it.

### 1. Full option table

Columns: fedora | fedora-wsl | macos | parrot-ctf | windows. `-` = not accepted (bash platforms `die "Unknown option..."`).

| option | fed | wsl | mac | parrot | win | default | what it actually runs |
|---|---|---|---|---|---|---|---|
| `--platform NAME` | dispatcher-only | same | same | same | - | `fedora` | selects `platforms/NAME/install.sh` |
| `-h`, `--help` | yes | yes | yes | yes | (`Get-Help`) | - | `usage()` then `exit 0` |
| `--theme FLAVOUR` | yes | yes | yes | yes | - | `macchiato` (validated `latte\|frappe\|macchiato\|mocha`) | `setup-local.sh <theme>` + `~/.local/bin/theme <theme>` |
| `--kde` / `--no-kde` | yes | - | - | - | - | `auto` -> `true` iff `command_exists plasmashell` | `platforms/fedora/scripts/install-kde-theme.sh` |
| `--latex` / `--no-latex` | yes | yes | - | - | - | fedora: false, but interactively prompted; wsl: false | `platforms/fedora/scripts/install-latex.sh` (wsl reuses the Fedora script); wsl also adds `--latex` to `verify.sh` |
| `--ocaml` / `--no-ocaml` | yes | yes | yes | - | - | false | fedora: `platforms/fedora/scripts/install-ocaml.sh` + `common/install-ocaml.sh`; wsl: same two; mac: `platforms/macos/scripts/install-ocaml.sh` + `common/install-ocaml.sh` |
| `--sway` / `--no-sway` | yes | - | - | - | - | false | `install-sway.sh`; also adds `--sway` to `setup-local.sh` and `stow.sh` (stows `sway`, `waybar`) |
| `--vm-host` | yes | - | - | - | - | false | `install-vm-host.sh` |
| `--vm-guest` | yes | - | - | - | - | false | `install-vm-guest.sh --preflight` (early), then `install-vm-guest.sh` |
| `--hardening` / `--no-hardening` | yes | - | - | - | - | false | `install-hardening.sh [--non-interactive]` |
| `--desktop-tools` / `--no-desktop-tools` | yes | - | - | - | - | false | `install-desktop-tools.sh [--force-defaults]` |
| `--desktop-tools-force-defaults` | yes | - | - | - | - | false; requires `--desktop-tools` | passes `--force-defaults` |
| `--containers` / `--no-containers` | yes | yes | yes | - | - | false | fedora: `platforms/fedora/scripts/install-containers.sh`; wsl: `platforms/fedora-wsl/scripts/install-containers.sh`; mac: `platforms/macos/scripts/install-containers.sh` (brew podman + `podman machine init --now` + alpine aarch64 smoke test) |
| `--containers-api-socket` | yes | yes | - | - | - | false; requires `--containers` | passes `--api-socket` to the platform containers script |
| `--tailscale` / `--no-tailscale` | yes | rejected | yes | - | - | false | fedora: `install-tailscale.sh` (Tailscale DNF repo); mac: `install-tailscale.sh` (cask `tailscale-app`, `open -a Tailscale`) + `--tailscale` to verify. wsl accepts the token only to `die` with the host-install policy message |
| `--ai` / `--no-ai` | yes | yes | - | - | - | false | `common/install-ai.sh` (Claude Code + Herdr via mise conf.d/ai.toml, links `common/assets/AGENTS.md`) |
| `--codex` / `--no-codex` | yes | yes | - | - | - | false; requires `--ai` | `common/install-ai.sh --codex` |
| `--firstmate` / `--no-firstmate` | yes | yes | - | - | - | false; requires `--ai` | `--firstmate`: git clone to `~/.local/share/firstmate`, Treehouse and No Mistakes via their own install scripts, gh-axi/chrome-devtools-axi/lavish-axi/tasks-axi/quota-axi via mise |
| `--gnhf` / `--no-gnhf` | yes | yes | - | - | - | false; requires `--ai` | `common/install-ai.sh --gnhf` (mise) |
| `--backpass` / `--no-backpass` | yes | yes | - | - | - | false; requires `--ai` | `common/install-ai.sh --backpass` (backpass + acpx via mise) |
| `--hardware MODEL` | yes | - | - | - | - | empty; `ga402xz\|ga402rk` | `install-asus-hardware.sh --model M --preflight`, then the real run; also `setup-local.sh --hardware M` when `--sway` |
| `--secure-boot` | yes | - | - | - | - | false; requires `--hardware` | adds `--secure-boot` to `install-asus-hardware.sh` |
| `--charge-limit N` | yes | - | - | - | - | empty; integer 40-100 | adds `--charge-limit N` to `install-asus-hardware.sh` |
| `--defaults` / `--no-defaults` | - | - | yes | - | - | **true** | `platforms/macos/scripts/apply-defaults.sh`; also `--defaults` to `verify.sh` |
| `--workflows` / `--no-workflows` | - | - | yes | - | - | false | `scripts/test-dev-workflows.sh --all`, plus `--ocaml` run when `--ocaml` |
| `--smoke-test` | - | yes | - | - | - | false | adds `--smoke-test` to `platforms/fedora-wsl/scripts/verify.sh`, which runs `scripts/test-dev-workflows.sh --all` (+ `--ocaml`) |
| `--dry-run` | yes | yes | yes | yes | `-DryRun` | false; also sets `interactive=false` on all four bash platforms | prints plan, `exit 0` |
| `--non-interactive` | yes | yes | yes | yes | - | false | suppresses `confirm`; forwarded to `install-asus-hardware.sh`, `install-hardening.sh`, `macos/scripts/install-system.sh` |
| `-FedoraDistribution NAME` | - | - | - | - | yes | auto: newest `FedoraLinux[-N]` from `wsl --list --online`, else Microsoft's `DistributionInfo.json` | `Resolve-FedoraDistribution`, then `Install-WslDistribution` |
| `-SkipNoctty` | - | - | - | - | yes | false | skips `Install-Noctty` and `Set-NocttyConfiguration` |
| `-SkipNocttyConfiguration` | - | - | - | - | yes | false | skips `Set-NocttyConfiguration` only |
| `-ElevatedWslPhase` (hidden) | - | - | - | - | yes | false | `Invoke-ElevatedEntryPoint { Install-WslDistribution }` |
| `-ElevatedWslUpdateOnly` (hidden) | - | - | - | - | yes | false | `Invoke-ElevatedEntryPoint { Update-Wsl }` |
| `-ElevatedLogPath PATH` (hidden) | - | - | - | - | yes | empty | `Start-Transcript` in the elevated child |

Rejected combinations: fedora `--vm-host`+`--vm-guest`, `--vm-guest`+`--hardware`, `--secure-boot`/`--charge-limit` without `--hardware`, `--containers-api-socket` without `--containers`, `--desktop-tools-force-defaults` without `--desktop-tools`, any AI sub-option without `--ai`. Windows: `-ElevatedWslPhase` + `-ElevatedWslUpdateOnly`; running elevated as the top-level entry point.

Sub-script options never reachable from any top-level installer: `install-containers.sh --dry-run|--validate`, `install-hardening.sh --dry-run|--validate`, `install-tailscale.sh --dry-run|--validate`, `install-vm-host.sh --dry-run|--validate|--smoke-test`, `install-vm-guest.sh --dry-run|--validate`, `install-desktop-tools.sh --dry-run`, `install-asus-hardware.sh --dry-run`, `configure-interop.sh --dry-run`, `apply-defaults.sh --restore|--dry-run`, `common/install-ai.sh --dry-run|--validate`, `common/stow.sh --headless|--without-mise` (set by platform wrappers, not by flags).

### 2. Ordered execution per platform

### fedora (sudo used inside every `install-*` step below except `setup-local.sh`, `common/install-mise.sh`, `common/install-neovim-tools.sh`, `common/install-ocaml.sh`, `common/install-tmux-theme.sh`, `common/install-ai.sh`, `stow.sh`, `verify.sh`)
1. `install-vm-guest.sh --preflight` (if `--vm-guest`)
2. `install-asus-hardware.sh --model M [--secure-boot] [--charge-limit N] --preflight` (if `--hardware`)
3. `scripts/install-system.sh` (`sudo dnf install` 25 packages; `ensure_zsh_login_shell` -> `sudo usermod --shell`)
4. `scripts/install-terra.sh` (`sudo dnf` Terra repo + packages)
5. `scripts/install-ocaml.sh` (if `--ocaml`; `sudo dnf`)
6. `scripts/install-asus-hardware.sh --model M [...] [--non-interactive]` (if `--hardware`)
7. `scripts/install-sway.sh` (if `--sway`; `sudo dnf`, `sudo install`)
8. `scripts/install-vm-host.sh` (if `--vm-host`)
9. `scripts/install-vm-guest.sh` (if `--vm-guest`)
10. `scripts/install-hardening.sh [--non-interactive]` (if `--hardening`)
11. `scripts/install-desktop-tools.sh [--force-defaults]` (if `--desktop-tools`)
12. `scripts/install-containers.sh [--api-socket]` (if `--containers`)
13. `scripts/install-tailscale.sh` (if `--tailscale`)
14. `scripts/setup-local.sh <theme> [--sway [--hardware M]]` (wraps `common/setup-local.sh`)
15. `scripts/stow.sh [--sway]` (calls `common/stow.sh`, then `zsh-platform theme-hooks theme-assets` [+ `sway waybar`])
16. `common/install-mise.sh`
17. `common/install-neovim-tools.sh`
18. `common/install-ocaml.sh` (if `--ocaml`)
19. `common/install-tmux-theme.sh`
20. `common/install-ai.sh [--codex] [--firstmate] [--gnhf] [--backpass]` (if `--ai`)
21. `scripts/install-kde-theme.sh` (if resolved `--kde`; `sudo dnf install kio-extras`)
22. `scripts/install-latex.sh` (if `--latex`; `sudo dnf`)
23. `~/.local/bin/theme <theme>` if executable, else `warn`
24. `scripts/verify.sh` (no flags; auto-detects optional profiles from state files under `~/.config/dotfiles/`, delegating to `verify-asus-hardware.sh`, `verify-vm-host.sh`, `verify-vm-guest.sh`, `verify-hardening.sh`, `verify-desktop-tools.sh`, `verify-containers.sh`, `verify-tailscale.sh`, `common/verify-ocaml.sh`, `common/verify-ai.sh`). Non-zero verify -> `exit 1`.

The dry-run plan lists steps in a different order than 1-24 above (it places OCaml prerequisites before hardware, and AI after tmux but before KDE/LaTeX, which matches; it omits both `--preflight` calls).

### fedora-wsl (sudo in `install-system.sh`, `configure-interop.sh`, the reused Fedora `install-ocaml.sh`/`install-latex.sh`, and `install-containers.sh`)
1. `require_fedora_wsl` (lib/wsl.sh), `systemd_is_running` info/warn, `/mnt/*` cwd warning
2. `scripts/install-system.sh` (`sudo dnf`, `ensure_zsh_login_shell`, user-local mise from `https://mise.run`)
3. `scripts/configure-interop.sh` (rewrites `/etc/wsl.conf` `[interop]` with sudo; no sudo if already correct)
4. `platforms/fedora/scripts/install-ocaml.sh` (if `--ocaml`)
5. `platforms/fedora/scripts/install-latex.sh` (if `--latex`)
6. `common/setup-local.sh <theme>`
7. `scripts/stow.sh` -> `common/stow.sh --headless` + `interop nvim-wsl theme-hooks zsh-platform`
8. `common/install-mise.sh`
9. `common/install-neovim-tools.sh`
10. `common/install-ocaml.sh` (if `--ocaml`)
11. `scripts/install-containers.sh [--api-socket]` (if `--containers`)
12. `common/install-tmux-theme.sh`
13. `common/install-ai.sh [subflags]` (if `--ai`)
14. `~/.local/bin/theme <theme>` if executable (silent otherwise)
15. `scripts/verify.sh [--smoke-test] [--latex]`

Real order differs from the printed plan: the plan puts `setup-local`/stow/mise/nvim before OCaml and LaTeX, and containers before tmux; the code runs OCaml/LaTeX prerequisites at positions 4-5.

### macos (no `sudo` in any step; Homebrew and `defaults` only)
1. `require_apple_silicon_macos`
2. `scripts/install-system.sh [--non-interactive]` (rejects `/usr/local/bin/brew`, requires CLT, installs `/opt/homebrew` via `curl | bash` with `NONINTERACTIVE=1` when non-interactive, `brew bundle --file=platforms/macos/Brewfile`)
3. `activate_homebrew_path`
4. `scripts/install-ocaml.sh` (if `--ocaml`)
5. `scripts/install-containers.sh` (if `--containers`)
6. `scripts/install-tailscale.sh` (if `--tailscale`)
7. `common/setup-local.sh <theme>`
8. `scripts/stow.sh` -> `common/stow.sh` + `zsh-platform aerospace nvim-macos`
9. `common/install-mise.sh`
10. `common/install-neovim-tools.sh`
11. `common/install-tmux-theme.sh`
12. `common/install-ocaml.sh` (if `--ocaml`)
13. `scripts/apply-defaults.sh` (if `--defaults`, the default)
14. `scripts/test-dev-workflows.sh --all` then `--ocaml` (if `--workflows`)
15. `~/.local/bin/theme <theme>` if executable
16. `open -a AeroSpace` (warn on failure)
17. `scripts/verify.sh [--defaults] [--containers] [--tailscale]`; failure -> `exit 1`

### parrot-ctf (sudo in `install-system.sh` and `install-guest-integration.sh`)
1. `require_parrot`, `require_qemu_vm`, `require_guest_channels`
2. `scripts/install-system.sh` (APT working-environment list)
3. `scripts/install-guest-integration.sh` (`qemu-guest-agent`, `spice-vdagent`)
4. `common/setup-local.sh <theme>`
5. `scripts/stow.sh` -> `common/stow.sh --headless --without-mise` + `command-shims mise-ctf zsh-platform`
6. `common/install-mise.sh`
7. `common/install-tmux-theme.sh`
8. `~/.local/bin/theme <theme>` if executable
9. `scripts/verify.sh`

No Neovim/Mason, OCaml, LaTeX, containers, or AI steps exist here.

### windows/install.ps1
1. Hidden elevated entry points short-circuit first: `-ElevatedWslUpdateOnly` -> `Update-Wsl`; `-ElevatedWslPhase` -> `Install-WslDistribution`.
2. Refuse to run if already administrator; require `wsl.exe`.
3. `Resolve-FedoraDistribution -AllowUnavailable` (reads `wsl --list --quiet`, `--list --online --quiet`, then `Invoke-RestMethod` on Microsoft's DistributionInfo.json).
4. If unresolved: `Invoke-ElevatedWslUpdate` (UAC child running `wsl --update --web-download`), then re-resolve.
5. If not installed or not WSL 2: `Invoke-ElevatedWslInstall` (UAC child: `Update-Wsl` non-fatal, `wsl --set-default-version 2`, `wsl --install --distribution NAME --no-launch [--web-download]`, or `wsl --set-version NAME 2`).
6. Unless `-SkipNoctty`: `Install-Noctty` (Scoop via `https://get.scoop.sh` if absent, `scoop bucket add noctty`, `scoop install noctty/noctty`), then unless `-SkipNocttyConfiguration`: `Set-NocttyConfiguration` (managed block in `%LOCALAPPDATA%\noctty\config.ghostty`, `Sync-NocttyGhosttyConfig` copying `ghostty/.config/ghostty/shared.conf`, all `themes/*.conf`, and `set-noctty-theme.ps1`).
7. Post-check readiness; exit 2 with a restart warning if Fedora is not yet on WSL 2. Elevation is the only privileged mechanism; Scoop and Noctty stay per-user.

### 3. Interactive prompt flow

`confirm()` (`common/lib/common.sh`) reads stdin, `[Y/n]` for default `y`, `[y/N]` for default `n`, and treats any answer other than `y`/`Y` as no. All prompts are suppressed by `--non-interactive` or `--dry-run`.

- **fedora**: (1) preflight banner, then `Install LaTeX toolchain?` default **n**, asked only when `--latex` was not passed (`--no-latex` does not suppress it, since both leave the variable `false`). (2) Re-printed choices, then `Continue with installation?` default **y**; declining exits 0. Later, inside `install-hardening.sh`, `Continue with hardening installation?` default **y** (suppressed by the forwarded `--non-interactive`). Inside `install-asus-hardware.sh` under Secure Boot with an unenrolled MOK key, `Initiate MOK enrollment now?` default **y**; declining `die`s, accepting schedules `mokutil --import` and exits 2. Homebrew-style extra prompts do not exist here; `sudo` may still prompt for a password at any `install-*` step.
- **fedora-wsl**: single `Continue with installation?` default **y**.
- **macos**: single `Continue with installation?` default **y**. When interactive, the upstream Homebrew installer is run without `NONINTERACTIVE=1` and adds its own confirmation and `sudo` password prompt.
- **parrot-ctf**: single `Continue with the isolated lab profile?` default **y**, printed after guest validation.
- **windows**: no scripted prompts at all. The only interaction is the Windows UAC consent dialog (retried up to 3 times), plus whatever the Scoop installer asks.

### 4. What `--dry-run` suppresses

**fedora, fedora-wsl, macos, parrot-ctf: fully honored for every installation step.** Each installer prints its plan and `exit 0` before any step runs, and `--dry-run` also forces `interactive=false`, so no prompt appears either. Read-only side effects that still happen before the plan prints:

- fedora: `command_exists plasmashell` to resolve `--kde=auto`. No preflight, no sudo.
- fedora-wsl: none; notably `require_fedora_wsl`, the systemd check, and the `/mnt/*` cwd warning are skipped, so the plan prints on any host.
- macos: none; `require_apple_silicon_macos` is skipped, so the plan prints on non-Apple hardware.
- parrot-ctf: none; `require_parrot`/`require_qemu_vm`/`require_guest_channels` are skipped.
- All four: no forwarding of `--dry-run` to sub-scripts, so the sub-scripts' own `--dry-run` plans are never shown.

**windows: partially honored.** Fully honored: `Update-Wsl` and both elevated phases (`Invoke-ElevatedWslUpdate`, `Invoke-ElevatedWslInstall` return after `Write-Step "Would ..."`, so no UAC prompt), Scoop install, `scoop bucket add`, `scoop install noctty/noctty`, `Sync-NocttyGhosttyConfig` file copies and directory creation, and the `config.ghostty` write. Not honored (side effects or network reads that still occur): `wsl --list --quiet`, `wsl --list --online --quiet`, `wsl --list --verbose`, the `Invoke-RestMethod` fetch of Microsoft's distribution catalogue, `Get-Command scoop`/`noctty` probes, and `scoop bucket list` when Scoop already exists. Also, when Fedora cannot be resolved the dry run stops early at that prerequisite and never previews the Noctty half.

### 5. Options present on one platform whose capability plainly exists elsewhere but has no option

- `--ai` (+ `--codex`, `--firstmate`, `--gnhf`, `--backpass`): fedora and fedora-wsl only. `common/install-ai.sh` is pure mise/npm/git tooling and macOS installs mise from the Brewfile, yet macos has no `--ai` (its dry-run plan says "unavailable until repository issue #16 lands"); parrot-ctf excludes it by policy.
- `--latex`: fedora and fedora-wsl only, both via `sudo dnf`. macos has no `--latex` even though `scripts/test-dev-workflows.sh --latex` exists and Homebrew can supply the toolchain.
- `--containers` / `--containers-api-socket`: the API socket sub-option exists on fedora and fedora-wsl; macos has `--containers` but no socket option (Podman machine has an equivalent Docker-compatible socket), and parrot-ctf has neither.
- `--defaults` / `--no-defaults`: macos only. Fedora applies KDE look-and-feel through `--kde` and `install-kde-theme.sh` with no comparable opt-out of desktop-setting changes beyond `--no-kde`.
- `--workflows` (macos) vs `--smoke-test` (fedora-wsl): the same `scripts/test-dev-workflows.sh` driver, two different option names, and native fedora and parrot-ctf expose neither.
- `--non-interactive`: all four bash platforms; `install.ps1` has no equivalent switch even though its only blocking interaction (UAC) and the Scoop installer would both benefit.
- `--theme`: all bash platforms; Windows synchronizes Ghostty themes for Noctty and installs `set-theme.ps1` but has no option to choose the initial flavour, always taking the `theme =` line from `ghostty/.config/ghostty/shared.conf`.
- `--tailscale`: fedora and macos. fedora-wsl explicitly rejects it by design; parrot-ctf accepts no such option at all despite being a normal APT Debian derivative Tailscale supports.
---

## Appendix B: package-manager ownership inventory


`KasperElbo/dotfiles` @ `/home/user/dotfiles`. Line numbers are as-tracked. "Floating" = no version constraint in the repo.

### 1. Ownership table

Cross-platform CLI core (same tool, four managers). Platform keys: **F** = fedora, **W** = fedora-wsl, **M** = macos, **P** = parrot-ctf.

| Tool | Manager(s) | Platforms | file:line | Pin |
|---|---|---|---|---|
| bat | dnf `bat` / dnf `bat` / brew `bat` / apt `bat` (+ stow shim `bat`->`batcat`) | F W M P | fedora/scripts/install-system.sh:11; fedora-wsl/scripts/install-system.sh:13; macos/Brewfile:5; parrot-ctf/scripts/install-system.sh:16; parrot-ctf/stow/command-shims/.local/bin/bat:2 | floating |
| eza | dnf / dnf / brew / apt | F W M P | install-system.sh:13; :16; Brewfile:7; parrot install-system.sh:20 | floating |
| fd | dnf `fd-find` / dnf `fd-find` / brew `fd` / apt `fd-find` (+ shim `fd`->`fdfind`) | F W M P | :14; :17; Brewfile:8; parrot :21; command-shims/.local/bin/fd:2 | floating |
| fzf | dnf / dnf / brew / apt | F W M P | :15; :18; Brewfile:9; parrot :22 | floating |
| gh | dnf / dnf / brew / apt | F W M P | :16; :22; Brewfile:10; parrot :23 | floating |
| git | dnf / dnf / brew / apt | F W M P | :17; :23; Brewfile:11; parrot :24 | floating |
| git-delta | dnf / dnf / brew / apt | F W M P | :18; :24; Brewfile:12; parrot :25 | floating |
| neovim | dnf / dnf / brew / apt | F W M P | :20; :27; Brewfile:15; parrot :28 | floating (targets 0.12+) |
| ripgrep | dnf / dnf / brew / apt | F W M P | :22; :30; Brewfile:16; parrot :35 | floating |
| shellcheck | dnf `ShellCheck` / dnf `ShellCheck` / brew `shellcheck` / apt `shellcheck` | F W M P | :23; :31; Brewfile:17; parrot :36 | floating |
| sqlite | dnf `sqlite`+`sqlite-devel` / dnf same / brew `sqlite` / apt `sqlite3` | F W M P | :25-26; :33-34; Brewfile:18; parrot :37 | floating |
| stow | dnf / dnf / brew / apt | F W M P | :27; :35; Brewfile:20; parrot :39 | floating |
| tmux | dnf / dnf / brew / apt | F W M P | :28; :36; Brewfile:21; parrot :40 | floating |
| zoxide | dnf / dnf / brew / apt | F W M P | :31; :38; Brewfile:22; parrot :43 | floating |
| zsh | dnf / dnf / apt (macOS uses system zsh) | F W P | :32; :39; parrot :44 | floating |
| zsh-autosuggestions | dnf / dnf / brew / apt | F W M P | :33; :40; Brewfile:23; parrot :45 | floating |
| zsh-syntax-highlighting | dnf / dnf / brew / apt | F W M P | :34; :41; Brewfile:24; parrot :46 | floating |
| curl | dnf / dnf / apt | F W P | :12; :15; parrot :19 | floating |
| libicu | dnf / dnf | F W | :19; :25 | floating |
| openssh-clients | dnf / dnf | F W | :21; :28 | floating |
| shadow-utils | dnf / dnf | F W | :24; :32 | floating |
| jq | dnf (Sway profile only) / brew / apt | F M P | fedora/scripts/install-sway.sh:19; Brewfile:13; parrot :26 | floating |
| mise | dnf via Terra / curl-pipe `https://mise.run` / brew / curl-pipe `https://mise.run` | F W M P | fedora/scripts/install-terra.sh:16,28; fedora-wsl/scripts/install-system.sh:80-86; Brewfile:14; parrot install-system.sh:72-74 | floating |
| starship | dnf via Terra / curl-pipe `https://starship.rs/install.sh` / brew / apt | F W M P | install-terra.sh:17,28; fedora-wsl install-system.sh:61-65; Brewfile:19; parrot :38 | floating |
| ghostty | dnf via Terra / brew cask | F M | install-terra.sh:15,28; Brewfile:26 | floating |
| lazygit | mise / apt | F W M / P | mise/.config/mise/config.toml:5; parrot install-system.sh:27 | latest / floating |
| bash | brew (macOS only) | M | Brewfile:4 | floating |
| coreutils | brew (gnubin prepended to PATH) | M | Brewfile:6; macos/lib/macos.sh:28 | floating |
| aerospace | brew cask from tap `nikitabobko/tap` | M | Brewfile:2,27 | floating |
| noctty | Scoop, bucket `noctty` | Windows | windows/install.ps1:435,445 | floating |

Platform-only OS packages:

| Tool / set | Manager | Platform | file:line | Pin |
|---|---|---|---|---|
| wl-clipboard, xdg-utils | dnf | F | fedora install-system.sh:29-30 | floating |
| bzip2, gawk, gcc, gcc-c++, make, procps-ng, unzip | dnf | W | fedora-wsl install-system.sh:14,19,20,21,26,29,37 | floating |
| build-essential, ca-certificates, pipx, python-is-python3, python3, python3-dev, python3-pip, python3-venv, xdg-utils | apt | P | parrot install-system.sh:17,18,29,30,31,32,33,34,42 | floating |
| ark, gwenview, okular (installed only if missing) | dnf | F | install-desktop-tools.sh:16-18,198 | floating |
| gimp, pdfarranger, skanpage, xdg-utils | dnf | F | install-desktop-tools.sh:24-27,204 | floating |
| mpv | dnf (after RPM Fusion) | F | install-desktop-tools.sh:210 | floating |
| kio-extras | dnf | F | install-kde-theme.sh:17 | floating |
| blueman, brightnessctl, cliphist, dex-autostart, fuzzel, grim, jq, libnotify, lxqt-policykit, mako, nm-connection-editor, pavucontrol, playerctl, slurp, sway, swaybg, swayidle, swaylock, sway-systemd, swappy, waybar, wireplumber, xdg-desktop-portal-gtk, xdg-desktop-portal-wlr | dnf | F | install-sway.sh:11-35,38 | floating |
| dotfiles-sway + .desktop | manual `install -Dm` from repo assets | F | install-sway.sh:41-46 | repo content |
| texlive-scheme-medium, latexmk, biber, texlive-biblatex, texlive-latexindent | dnf | F, W | install-latex.sh:10-19 | floating |
| edk2-ovmf, libvirt-client, libvirt-daemon-config-network, libvirt-daemon-driver-qemu, qemu-img, qemu-kvm, spice-gtk, spice-server, swtpm, swtpm-tools, virt-install, virt-manager, virt-viewer | dnf | F | install-vm-host.sh:19-32,130 | floating |
| qemu-guest-agent, spice-vdagent, xclip | dnf | F | install-vm-guest.sh:18-21,132 | floating |
| qemu-guest-agent, spice-vdagent | apt | P | install-guest-integration.sh:15-17 | floating |
| asusctl, asusctl-rog-gui, fwupd, mokutil, pciutils | dnf via Terra | F | install-asus-hardware.sh:220-226,228,231 | floating |
| kmodtool, akmods, mokutil, openssl | dnf | F | install-asus-hardware.sh:261 | floating |
| akmod-nvidia, xorg-x11-drv-nvidia-cuda | dnf via RPM Fusion | F | install-asus-hardware.sh:257,321 | floating |
| amd-gpu-firmware, mesa-dri-drivers, mesa-va-drivers, mesa-vulkan-drivers | dnf | F | install-asus-hardware.sh:334-342 | floating |
| audit | dnf | F | fedora/lib/hardening.sh:153 | floating |
| dnf5-plugin-automatic | dnf | F | fedora/lib/hardening.sh:254 | floating |
| dnf5-plugins | dnf | F | fedora/lib/tailscale.sh:33 | floating |
| tailscale | dnf, Tailscale's own repo | F | install-tailscale.sh:106 | floating |
| tailscale-app | brew cask | M | macos/scripts/install-tailscale.sh:14 | floating |
| podman, podman-compose | dnf | F, W (reuses F script) | fedora install-containers.sh:18-19,138 | floating |
| podman, podman-compose | brew | M | macos/scripts/install-containers.sh:14 | floating |
| bzip2, bubblewrap, gcc, gcc-c++, m4, make, opam, patch, pkgconf-pkg-config, unzip | dnf | F, W | fedora/scripts/install-ocaml.sh:13-26 | floating |
| opam, pkg-config, gmp | brew | M | macos/scripts/install-ocaml.sh:12 | floating |
| Homebrew itself | curl-pipe vendor script | M | macos/scripts/install-system.sh:34-41 | `HEAD` |
| Scoop itself | Invoke-WebRequest + powershell | Windows | windows/install.ps1:386-390 | floating |
| FedoraLinux WSL distro | `wsl.exe --install` (Store or `--web-download`) | Windows | windows/install.ps1:328-338 | newest catalogue entry |

Language/tool managers:

| Tool | Manager | Platforms | file:line | Pin |
|---|---|---|---|---|
| ast-grep | mise | F W M | mise config.toml:2 | latest |
| dotnet | mise | F W M | :3 | `10` |
| EasyDotnet | mise `dotnet:` backend | F W M | :4 | latest |
| node | mise | F W M | :6 | `24` |
| @mermaid-js/mermaid-cli | mise `npm:` backend | F W M | :7 | latest |
| neovim (npm host) | mise `npm:` | F W M | :8 | latest |
| pynvim | mise `pipx:` | F W M | :9 | latest |
| python | mise | F W M | :10 | `3.14` |
| tree-sitter | mise | F W M | :11 | latest |
| uv | mise | F W M | :12 | latest |
| uv | mise (separate CTF config) | P | parrot-ctf/stow/mise-ctf/.config/mise/config.toml:2 | latest |
| @anthropic-ai/claude-code | mise `npm:`, into untracked `conf.d/ai.toml` | F W | common/install-ai.sh:230 | latest |
| herdr | mise registry | F W | install-ai.sh:231 | latest |
| @openai/codex | mise `npm:` (`--codex`) | F W | install-ai.sh:233 | latest |
| gnhf | mise `npm:` (`--gnhf`) | F W | install-ai.sh:236 | latest |
| gh-axi, chrome-devtools-axi, tasks-axi, quota-axi | mise `npm:` (`--firstmate`) | F W | install-ai.sh:239-242 | latest |
| lavish-axi | mise `npm:` (`--firstmate`/`--backpass`) | F W | install-ai.sh:247 | latest |
| backpass, acpx | mise `npm:` (`--backpass`) | F W | install-ai.sh:250-251 | latest |
| FirstMate | git clone | F W | install-ai.sh:16,337 | floating branch |
| Treehouse | curl-pipe vendor script | F W | install-ai.sh:18,319 | floating |
| No Mistakes | curl-pipe vendor script | F W | install-ai.sh:20,319 | floating |
| angular-language-server, debugpy, eslint-lsp, js-debug-adapter, json-lsp, lua-language-server, marksman, netcoredbg, pyright, roslyn, ruff, shfmt, stylua, texlab, vtsls, yaml-language-server | Mason | F W M | nvim-lazyvim/.config/nvim/mason-packages.txt:1-16; common/install-neovim-tools.sh:10-73; common/bootstrap-mason.lua:21; nvim-lazyvim/.config/nvim/lua/plugins/mason.lua:13-18 | floating |
| OCaml compiler | opam switch | F W M | common/install-ocaml.sh:9,28 | `5.5.0` |
| dune, earlybird, ocaml-lsp-server, ocamlformat, utop | opam | F W M | common/install-ocaml.sh:32-37 | floating |
| Catppuccin KDE | git clone + vendor `install.sh` | F | install-kde-theme.sh:20-33,71 | tag `v0.2.7` |
| Catppuccin tmux | git clone / tag fetch | F W M P | common/install-tmux-theme.sh:9-31 | tag `v2.3.0` |
| CI: git jq neovim python3 ripgrep ShellCheck stow | dnf (fedora:44 container) | CI | .github/workflows/validate.yml:36 | floating |
| CI: bash ripgrep shellcheck stow | brew | CI | validate.yml:84 | floating |

No `winget`, `cargo install`, `go install`, bare `npm -g`, bare `pipx install`, or manual tarball extraction appears anywhere in the repo.

### 2. Tools owned by more than one manager, or by different managers per platform

Same tool, different manager per platform:

1. **mise**: Terra/dnf (F), `curl https://mise.run | sh` (W), brew (M), `curl https://mise.run | sh` (P). Four platforms, three mechanisms.
2. **starship**: Terra/dnf (F), `curl https://starship.rs/install.sh` (W), brew (M), apt (P). Four mechanisms.
3. **ghostty**: Terra/dnf (F) vs brew cask (M). Windows substitutes Noctty via Scoop while sharing the same tracked Ghostty config tree (`windows/install.ps1:50-51,526`).
4. **lazygit**: mise on F/W/M vs apt on P (P's `mise-ctf` config declares only `uv`).
5. **opam**: dnf (F, and W via the F script) vs brew (M). The opam-managed switch contents are identical on all three.
6. **podman + podman-compose**: dnf (F, W) vs brew (M).
7. **tailscale**: dnf from `pkgs.tailscale.com` (F) vs brew cask `tailscale-app` (M).
8. **qemu-guest-agent, spice-vdagent**: dnf (F, `install-vm-guest.sh:19-20`) vs apt (P, `install-guest-integration.sh:16-17`).
9. **pkg-config**: dnf `pkgconf-pkg-config` (F/W, `fedora/scripts/install-ocaml.sh:21`) vs brew `pkg-config` (M, `macos/scripts/install-ocaml.sh:12`).
10. **python**: mise `python = "3.14"` (F/W/M) vs apt `python3`/`python3-pip`/`python3-venv`/`pipx` (P).
11. **bat**: apt-provided `batcat` (P) is re-exposed as `bat` by a stow shim; dnf/brew provide the binary named `bat` directly.
12. **fd**: apt-provided `fdfind` (P) re-exposed as `fd` by a stow shim; dnf `fd-find` and brew `fd` provide `fd` directly.
13. **sqlite**: dnf `sqlite`+`sqlite-devel` vs brew `sqlite` vs apt `sqlite3`.
14. **jq**: dnf only inside the optional Sway profile (`install-sway.sh:19`), brew unconditionally (`Brewfile:13`), apt unconditionally (`parrot install-system.sh:26`).
15. **zsh**: dnf (F/W), apt (P), and unmanaged system zsh on macOS (absent from the Brewfile).
16. **Build prerequisites** (`gcc`, `gcc-c++`, `make`, `bzip2`, `unzip`): dnf in `fedora-wsl/scripts/install-system.sh:14,20,21,26,37` and again in dnf in `fedora/scripts/install-ocaml.sh:13,15,16,18,22`; apt `build-essential` (P, `:17`); Xcode CLT plus brew on M (`macos/scripts/install-system.sh:24`).
17. **shellcheck / ripgrep / stow / git / neovim / jq / python3**: additionally installed by CI, dnf in `validate.yml:36` and brew in `validate.yml:84`, in parallel with the platform installers.

Same tool named twice within one manager:

18. **xdg-utils**: dnf twice on Fedora, `install-system.sh:30` and `install-desktop-tools.sh:27`; also apt on P (`:42`).
19. **mokutil**: dnf twice inside one script, `install-asus-hardware.sh:224` (Terra transaction) and `:261` (Secure Boot transaction).
20. **uv**: mise in two different configs, `mise/.config/mise/config.toml:12` (F/W/M) and `parrot-ctf/stow/mise-ctf/.config/mise/config.toml:2` (P).
21. **Terra vs COPR mise**: `install-terra.sh:29` passes `--disablerepo="copr:copr.fedorainfracloud.org:jdxcode:mise"`, an explicit guard against a second dnf-level owner of `mise`.

Split ownership of one ecosystem across two managers:

22. **.NET**: runtime and `EasyDotnet` from mise (`config.toml:3-4`); `roslyn` and `netcoredbg` from Mason (`mason-packages.txt:8,10`).
23. **Python tooling**: interpreter from mise (`:10`); `pynvim` via mise's pipx backend (`:9`); `debugpy`, `pyright`, `ruff` from Mason (`mason-packages.txt:2,9,11`).
24. **Node tooling**: runtime plus `npm:neovim` and `npm:@mermaid-js/mermaid-cli` from mise (`:6-8`); `eslint-lsp`, `js-debug-adapter`, `vtsls`, `angular-language-server` from Mason.
25. **AI profile**: mise npm backend (`install-ai.sh:230-251`), git clone (`:337`), and two curl-pipe vendor scripts (`:319`) all inside one profile.

### 3. Remote fetches that execute code or install a binary

| URL | file:line | Verification |
|---|---|---|
| `https://starship.rs/install.sh` -> `sh` | fedora-wsl/scripts/install-system.sh:61-65 | `--proto '=https' --tlsv1.2` only. No checksum, no GPG, no pin. |
| `https://mise.run` -> `sh` | fedora-wsl/scripts/install-system.sh:80-86 | Same. TLS only. |
| `https://mise.run` -> `sh` | parrot-ctf/scripts/install-system.sh:72-74 | Same. TLS only. |
| `https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh` -> `/bin/bash` | macos/scripts/install-system.sh:34-41 | TLS only. `HEAD`, not a pinned tag. |
| `https://repos.fyralabs.com/terra$releasever` -> installs `terra-release` | fedora/lib/fedora.sh:28-31 | Explicit `--nogpgcheck`. Nothing verified. |
| `https://mirrors.rpmfusion.org/{free,nonfree}/fedora/rpmfusion-*-release-${rpm -E %fedora}.noarch.rpm` | fedora/lib/fedora.sh:46-48 | No `--nogpgcheck` and no `rpm --import`. Relies on dnf's default RPM signature policy. Version is derived at runtime, not pinned. |
| `https://pkgs.tailscale.com/stable/fedora/tailscale.repo` -> `dnf config-manager addrepo` | fedora/lib/tailscale.sh:7,37-38 | Key trust comes from the `gpgkey=` line inside the fetched repofile. No key fingerprint checked by the repo. |
| `https://github.com/catppuccin/kde.git` cloned, then its `./install.sh` executed four times | fedora/scripts/install-kde-theme.sh:21,29-33,71 | Pinned tag `v0.2.7` (`:20`), `--depth 1`. No signature or commit hash. |
| `https://github.com/catppuccin/tmux.git` cloned / tag-fetched, content sourced by tmux | common/install-tmux-theme.sh:11,18-31 | Pinned tag `v2.3.0` (`:9`). No signature. |
| `https://kunchenguid.github.io/treehouse/install.sh` -> `curl ... \| sh` | common/install-ai.sh:18,319 | Nothing. Floating. |
| `https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh` -> `curl ... \| sh` | common/install-ai.sh:20,319 | Nothing. Floating `main`. |
| `https://github.com/kunchenguid/firstmate.git` cloned, later `git pull --ff-only` | common/install-ai.sh:16,335,337 | No tag, no branch, no signature. Default branch. |
| `github:mason-org/mason-registry`, `github:Crashdummyy/mason-registry` -> downloads and runs each Mason package installer | common/bootstrap-mason.lua:13-17,21 | Registries floating. Per-package integrity is whatever the registry entry declares. |
| mise backend downloads for every `config.toml` entry (npm registry, PyPI via pipx, NuGet for `dotnet:EasyDotnet`, GitHub releases for `herdr`/`lazygit`/`ast-grep`/`tree-sitter`) | mise/.config/mise/config.toml:1-15; common/install-mise.sh:21 | mise's own lockless `--yes install`. No repo-level lockfile; `latest` for most entries. |
| `https://get.scoop.sh` -> `powershell -ExecutionPolicy Bypass -File` | windows/install.ps1:386-390 | Nothing. `-UseBasicParsing` only. |
| `scoop bucket add noctty https://github.com/amanthanvi/scoop-noctty`, then `scoop install noctty/noctty` | windows/install.ps1:45,435,445 | Bucket added unverified. Binary integrity is the sha256 in that third-party bucket's manifest. |
| `https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json` | windows/install.ps1:46,112 | Data only (distribution names). Floating `master`. Drives which distro is installed. |
| `wsl.exe --update --web-download`, `wsl.exe --install --distribution <FedoraLinux*>` | windows/install.ps1:183,328-338,344 | Delegated to `wsl.exe`; Microsoft Store or Microsoft-signed web download. |
| `podman run --rm docker.io/library/alpine:latest sh -c ...` | macos/scripts/install-containers.sh:28-29 | Floating tag, no digest. Executes a remote image as an install-time smoke test. |
| `brew install --cask tailscale-app` | macos/scripts/install-tailscale.sh:14 | Cask URL plus sha256 from homebrew-cask. |
| `opam init` / `opam update` / `opam install` | common/install-ocaml.sh:18,22,32 | opam repository defaults. Compiler pinned to `5.5.0`; packages floating. |

### 4. Third-party repositories and taps

| Name | file:line | Key trust |
|---|---|---|
| Terra (`repos.fyralabs.com/terra$releasever`) | fedora/lib/fedora.sh:21-32 | `terra-release` is installed with `--nogpgcheck` via `--repofrompath`; the package then supplies the key that signs later transactions. Bootstrap step is unverified. |
| RPM Fusion free | fedora/lib/fedora.sh:34-48 | Release RPM fetched over HTTPS; key arrives inside the RPM. No fingerprint pinned. |
| RPM Fusion nonfree | fedora/lib/fedora.sh:34-48 | Same. |
| Tailscale Fedora repo | fedora/lib/tailscale.sh:7,25-38 | `dnf config-manager addrepo --from-repofile`; the fetched repofile's own `gpgkey=` URL is trusted. |
| COPR `copr:copr.fedorainfracloud.org:jdxcode:mise` | fedora/scripts/install-terra.sh:29 | Never enabled by this repo; named only to `--disablerepo` it. |
| Homebrew `homebrew/core` + `homebrew/cask` | macos/scripts/install-system.sh:48 | Homebrew's own git/HTTPS trust. |
| Homebrew tap `nikitabobko/tap` | macos/Brewfile:2 (consumed at :27) | Plain `tap` over HTTPS from GitHub. No key or commit pin. |
| Scoop `main` bucket | windows/install.ps1:386-390 (via installer) | Scoop default. Manifest sha256 per app. |
| Scoop bucket `noctty` = `https://github.com/amanthanvi/scoop-noctty` | windows/install.ps1:45,428-437 | `scoop bucket add` over HTTPS. No key, no commit pin. Manifest sha256 only. |
| Mason registry `github:mason-org/mason-registry` | common/bootstrap-mason.lua:14 | Mason's default registry over HTTPS. Floating. |
| Mason registry `github:Crashdummyy/mason-registry` | common/bootstrap-mason.lua:15 | Third-party registry (supplies `roslyn`). HTTPS, floating, no pin. |
| mise backend registries (npm, PyPI, NuGet, GitHub releases) | mise/.config/mise/config.toml:1-15; common/install-ai.sh:227-252 | mise's built-in backend trust. `[settings.npm] package_manager = "npm"` (`config.toml:14-15`). |
| opam default repository | common/install-ocaml.sh:18,22 | opam defaults. |
| Microsoft WSL distribution catalogue | windows/install.ps1:46,112 | HTTPS, floating `master`. |
| Parrot / Fedora / Homebrew distro-default repos | parrot install-system.sh:50; fedora install-system.sh:38 | Distro-supplied keys. No repo added by this project. |

### 5. Transcriptions

### `mise/.config/mise/config.toml`

```toml
[tools]
ast-grep = "latest"
dotnet = "10"
"dotnet:EasyDotnet" = "latest"
lazygit = "latest"
node = "24"
"npm:@mermaid-js/mermaid-cli" = "latest"
"npm:neovim" = "latest"
"pipx:pynvim" = "latest"
python = "3.14"
tree-sitter = "latest"
uv = "latest"

[settings.npm]
package_manager = "npm"
```

### `platforms/parrot-ctf/stow/mise-ctf/.config/mise/config.toml`

```toml
[tools]
uv = "latest"

# Parrot/APT owns the system Python used by the distribution and its security
# tools. Add challenge-specific runtimes in the challenge repository instead
# of turning this VM profile into the general workstation manifest.
```

### `nvim-lazyvim/.config/nvim/mason-packages.txt`

```
angular-language-server
debugpy
eslint-lsp
js-debug-adapter
json-lsp
lua-language-server
marksman
netcoredbg
pyright
roslyn
ruff
shfmt
stylua
texlab
vtsls
yaml-language-server
```

Note on the untracked mise overlay: `common/install-ai.sh:27-28` writes `$XDG_CONFIG_HOME/mise/conf.d/ai.toml` at install time (contents generated at `:227-252`). It is machine-local and not tracked, so its tool set is not transcribable from the repo; the generated keys are listed in section 1.
---

## Appendix C: test and verification coverage inventory


Scope: `scripts/test.sh`, `scripts/lint.sh`, `scripts/test-installer.sh`, `scripts/test-dev-workflows.sh`, all of `tests/`, every `verify*.sh`, `.github/workflows/validate.yml`. Descriptive only.

CI jobs: **repository** (ubuntu-latest, `container: fedora:44`; runs `scripts/lint.sh`, `scripts/test.sh`, `git diff --check`), **windows** (windows-latest; runs `tests/test-windows-bootstrap.ps1` only), **macos** (macos-26; runs `lint.sh` and `tests/test-macos.sh` only).

### 1. Every test file

| File | What it asserts | How | In test.sh | CI job |
|---|---|---|---|---|
| `scripts/test.sh` | Nothing itself; runs 32 `tests/*.sh` in a fixed order, aborts on first non-zero exit | sequential execution, `set -euo pipefail` | n/a | repository |
| `scripts/lint.sh` | Every tracked `*.sh` parses and passes ShellCheck | `bash -n` per file, then `shellcheck -x -P SCRIPTDIR -s bash`; hard-fails if shellcheck absent | no | repository, macos |
| `scripts/test-installer.sh` | Nothing; back-compat shim | `exec scripts/test.sh` | no | no |
| `scripts/test-dev-workflows.sh` | Real .NET/Angular/Python/OCaml/LaTeX toolchains create, restore, build, lint, format, test, package, serve and produce source maps/PDF/bytecode; a deliberate LaTeX error lands in `main.log` with file:line | real command execution against `tests/fixtures/*`; live HTTP probe with `curl`; calls `common/verify-ocaml.sh` | no | no (manual; `platforms/macos/install.sh --workflows`) |
| `tests/test-secure-boot.sh` | `probe_mok_key` maps mokutil output/status to enrolled/pending/not-enrolled/blocked/unknown; `privileged_file_exists`/`privileged_path_exists` work through sudo | sources the real lib; `sudo`/`mokutil` replaced by **shell functions** with a `MOCK_PRIVILEGED` gate | yes | repository |
| `tests/test-power-profiles.sh` | `power-profile-status` renders the profile file; only *installed* conflicting services get masked | real script execution + `systemctl`/`sudo` shell-function stubs writing a command log | yes | repository |
| `tests/test-installer-options.sh` | ~50 `--dry-run`/`--help` outputs and 15 option-validation failures for `install.sh`; dry-runs touch no HOME/XDG state | real installer execution with a `guard-bin` PATH where every mutating binary is a symlink to a script that exits 97; substring match on captured output; `find -mindepth 1` on the isolated dirs | yes | repository |
| `tests/test-platform-boundary.sh` | 11 portable Stow packages exist and contain no Fedora-isms; `common/`, OCaml and AI scripts contain no dnf/rpm/systemd/desktop calls; each platform `stow.sh` deploys exactly its own package set | `grep -R -E` over source text; PATH shim `stow` that appends its last argument to a log | yes | repository |
| `tests/test-local-state.sh` | `setup-local.sh` generates theme/ghostty/sway/swaylock/fuzzel state, creates empty local Git identities, preserves user files/symlinks/theme on rerun, keeps `sway/local.conf` machine-owned, migrates Stow-linked identities to 0600 files | real script execution in temp HOMEs; `grep -Fqx`, `readlink`, `stat -c %a` | yes | repository |
| `tests/test-theme.sh` | `theme` rejects bad flags/missing flavour, writes ghostty/sway/swaylock state, signals Ghostty, applies KDE look-and-feel *before* wallpaper, preserves a custom swaybg wallpaper via `/proc` cmdline, snapshots+restores the KDE wallpaper only with `--preserve-wallpaper`, and skips all KDE integration inside a live Sway session | real `theme` execution; 10 PATH shims logging to `MOCK_LOG`; `DOTFILES_PROC_ROOT` fixture; ordering asserted by comparing `grep -n` line numbers | yes | repository |
| `tests/test-kde-theme.sh` | `install-kde-theme.sh` installs `kio-extras` only when absent, runs the upstream installer for all four flavours twice, and never mutates the live desktop; `apply-kde-theme.sh` applies look-and-feel/colorscheme/cursor/wallpaper/lockscreen exactly once | real script execution; fake `git` that *synthesizes* the upstream installer; `rpm` presence table via `RPM_PRESENT`; side-effect log emptiness check | yes | repository |
| `tests/test-sway-config.sh` | ~35 Sway/Waybar/portal config strings, no auto-suspend, README row present; Stow replaces dangling pre-boundary links; 3x3 workspace-grid arithmetic (6 cases); wallpaper assets non-empty; helper scripts parse; session-start ordering | `grep -F`/`grep -Ev` over tracked config; real `stow.sh`/`setup-local.sh` with real GNU Stow; `swaymsg`+`jq` PATH shims for the grid; `bash -n` on 5 helper scripts | yes | repository |
| `tests/test-cheatsheet-bindings.sh` | 13 Sway bindings, 9 AeroSpace bindings and 3 Waybar keys exist, and the matching `.tex` cheat sheets document them; WSL sheet omits the layout toggle; discovery references in `docs/keybindings.md`; cheat-sheet inputs exist and `generate.sh` is executable | `grep -F`/`grep -E` over config + `.tex` + README; `[[ -f ]]`/`[[ -x ]]` | yes | repository |
| `tests/test-neovim-tool-ownership.sh` | Mason inventory equals an exact 16-package list; 9 LazyVim extras; ~40 strings in dotnet/ocaml/formatting/mason Lua; no project-local tool is mise- or Mason-owned; verify scripts reference the inventory; fixture `package.json`/`launch.json` keys | `grep -F` over Lua/TOML/txt; exact array comparison; **also launches both Lua tests** via `nvim --headless -u NONE` | yes | repository |
| `tests/test-neovim-bootstrap.sh` | `install-neovim-tools.sh` runs a bounded `Lazy! restore` every time, runs Mason bootstrap only until convergence, provisions every inventory package, and surfaces Mason exit 23 and a LazyVim timeout | real script execution; fake `nvim` PATH shim with `MOCK_NVIM_FAIL_MASON` / `MOCK_NVIM_HANG_LAZY` knobs; occurrence counting with `grep -Fc` | yes | repository |
| `tests/test-markdown-workflow.sh` | markdown extras/plugin keys, no `<Tab>` table mapping, `xdg-utils` in two package lists, WSL `vim.ui.open`/mkdp glue | `grep -Fq` over Lua/shell source | yes | repository |
| `tests/test-latex-profile.sh` | 4 LaTeX packages in `install-latex.sh`, VimTeX/texlab config strings, 6 localleader bindings, fixture contents, and three strings inside `scripts/test-dev-workflows.sh` | `grep -Fq` over installer, Lua, its own fixture, and a sibling test script | yes | repository |
| `tests/test-ocaml-profile.sh` | `common/install-ocaml.sh` inits opam bare, creates `dotfiles-ocaml-<v>` once, installs the 5-tool set, writes `ocaml.conf`, is idempotent, rejects a bad `OCAML_COMPILER_VERSION`; `.zshrc` sources opam init | real script execution against a stateful fake `opam` PATH shim; `grep -Fxq`/`grep -Fc` on a command log; `common/verify-ocaml.sh` executed | yes | repository |
| `tests/test-idempotency.sh` | setup+stow are repeatable and preserve user state; Stow conflicts are non-destructive and retryable; generated state never rewrites tracked files (repo `git diff` hash unchanged); legacy folded Git layout migrates; a **complete mocked `install.sh` bootstrap** succeeds twice, sets the login shell, composes with `--vm-guest`; Fedora verify rejects a non-Zsh shell | real installer + real GNU Stow; ~35 PATH shims (mostly `exit 0`), stateful fake `sudo`/`id`/`getent`, fake `nvim`, local Git origin for the tmux theme; sha256 comparison | yes | repository |
| `tests/test-asus-preflight.sh` | `--preflight` passes for GA402XZ/GA402RK, fails fast on disabled Secure Boot and DMI mismatch, mutates nothing; the same two failures abort `install.sh` before base install | real script + real `install.sh`; fake `mokutil` via `MOCK_SECURE_BOOT`; **fake sudo that exits 97 and logs to a mutation tripwire**; DMI fixture dirs | yes | repository |
| `tests/test-asus-verification.sh` | `verify-asus-hardware.sh` accepts a virtual `mesa-va-drivers` provider, detects both AMD GPUs and their `amdgpu` driver, and fails when the provider is missing | real verify script; `rpm`/`systemctl`/`asusctl`/`lspci`/`mokutil` PATH shims; substring match on output | yes | repository |
| `tests/test-mocked-installs.sh` | Exact DNF package lines for system/terra/ocaml/latex/sway, login-shell change happens once, sway session files installed, `asusd` started, conflicting profile daemon masked, AMD firmware installed, charge limit applied, `hardware.conf` idempotent | real scripts; logging `dnf`/`sudo`/`asusctl` shims, `rpm`/`mokutil`/`systemctl`/`id`/`getent` stubs; `grep -Fq` on the command log; sha256 rerun compare | yes | repository |
| `tests/test-sftp-baseline.sh` | `openssh-clients` is a base package and not flag-gated; `verify.sh` checks scp/sftp/ssh + `kio-extras`; no FileZilla anywhere; no second SSH in the Brewfile; README/docs document the workflow | `grep -Fq`/`grep -Eq` over source and docs only | yes | repository |
| `tests/test-ai-profile.sh` | `install-ai.sh` declares only requested tools in `mise/conf.d/ai.toml`, records 15 state keys, links AGENTS.md to three targets without overwriting an existing file, clones/updates FirstMate, installs Treehouse/No Mistakes, de-duplicates `lavish-axi`, is idempotent, honours `--dry-run`/`--validate`, rejects bad option combos; `verify-ai.sh` reports each state | real install+verify execution; a behaviour-mimicking fake `mise` that materializes shims from the generated TOML; fake `curl` emitting a real installer piped into `sh`; a **real local Git repo** as the FirstMate origin | yes | repository |
| `tests/test-vm-host.sh` | VM-host installs `edk2-ovmf`/libvirt but never `qemu-guest-agent`, enables `libvirtd`, autostarts net+pool, runs `virt-host-validate`, no bridge networking, `vm-host.conf` idempotent; `verify-vm-host.sh --smoke-test` treats two WARNs as advisory and runs `virt-install --dry-run --print-xml` with SPICE/agent channels | real scripts; logging `dnf`/`sudo`/`systemctl`/`virsh`/`virt-*`/`install` shims; blanket-success `rpm`; log greps + sha256 | yes | repository |
| `tests/test-vm-guest.sh` | Guest installs agent packages, enables units, disables and deletes the legacy clipboard bridge, touches no hardware/network config, is idempotent; rejects bare metal and non-KVM both directly and through `install.sh`, without mutation; `--dry-run` writes nothing | real scripts; `systemd-detect-virt` shim driven by `MOCK_VIRTUALIZATION_TYPE`; virtio channel fixtures; command-log sha256 as a mutation tripwire | yes | repository |
| `tests/test-desktop-tools.sh` | Dry-run lists missing baseline apps and mutates nothing; missing apps installed, present ones reused; four MIME defaults set; rerun keeps a user's changed default; `--force-defaults` overrides; RPM Fusion enabled, Terra not used | real script; a fake `xdg-mime` implementing a key=value MIME store with awk/sed; `RPM_PRESENT` table; state-file sha256 | yes | repository |
| `tests/test-containers.sh` | 9 scenarios: dry-run purity, subuid/subgid allocated once and non-overlapping, already-provisioned user untouched, `--api-socket` enables the unit in `--user` scope only, `--skip-smoke-test` is inspection-only, verify fails on non-rootless podman and missing subids, full smoke test exercises pull/run/build/mount/volume/port/network/compose, a build failure fails verification | real install+verify; a large stateful fake `podman` with ~10 `MOCK_*` knobs; fake `usermod` that writes subuid/subgid files; unit-state files | yes | repository |
| `tests/test-containers-wsl.sh` | `cgroup_v2_available`, `user_namespaces_available`, `systemd_user_session_available` reflect the filesystem; install and verify fail closed (no systemd PID 1, no `--user` session, no cgroup v2, no userns) before any mutation; dry-run purity; a satisfied host reuses the Fedora logic; `--validate` delegates; verify reports a networking hint | library functions called in `bash -c` subshells; real scripts; fake `ps` (`MOCK_PID1_COMM`), fake `ip`, cgroup/userns/bus fixtures; command-log emptiness as tripwire | yes | repository |
| `tests/test-tailscale.sh` | Dry-run purity; fresh install adds the repo, installs `dnf5-plugins` and `tailscale`, enables `tailscaled`, never runs `tailscale up` or `--advertise*`, writes state, prints the manual login hint; rerun re-adds nothing; verify distinguishes not-installed / not-running / NeedsLogin / Running; no credential-shaped literals in 6 scripts | real scripts; fake `tailscale` with `MOCK_TAILSCALE_*`; repo-file-creating fake `dnf`; unit-state files; `grep -E` source scan | yes | repository |
| `tests/test-wsl-interop.sh` | `render_ini_section_keys` handles 6 cases (empty, unrelated section, in-place correction, unrelated key, comments/spacing, idempotence); `configure-interop.sh` dry-run purity, creates a missing wsl.conf, preserves `[boot]`/`[wsl2]`, is a true no-op on rerun, refuses non-WSL; `windows_interop_works`/`_binfmt_hint`; verify.sh emits the repair advice | pure functions in `bash -c` subshells with exact string equality; real script runs; fake `cmd.exe`; fake `zsh` emitting sentinel PATH lines | yes | repository |
| `tests/test-fedora-wsl.sh` | ~30 dry-run strings and 6 rejected option combinations (incl. `--tailscale` unsupported); non-WSL host rejected; installer bootstraps mise+starship from fake curl payloads, sets login shell once, deploys exactly the WSL Stow set and never ghostty/sway/waybar; `wsl-copy`/`wsl-paste`/`wsl-open` behave; `theme` calls the Windows helper; a full mocked bootstrap runs twice, and `--latex` adds the TeX packages | real installers; two mock-bin generations (~40 shims), fake Windows `.exe` scripts, fake `curl` producing working installers, fake `zsh` with ANSI noise, local Git tmux-theme origin; log greps and sha256 | yes | repository |
| `tests/test-parrot-ctf.sh` | Parrot dry-run strings; Fedora-only options rejected; APT install line, mise bootstrap idempotent, login shell set; guest integration writes state idempotently and enables the agent; Stow deploys the CTF set and no workstation packages; no duplicated offensive-tool catalogue; refuses Fedora and bare metal without mutation | real scripts; fake `apt-get`/`dpkg-query`/`systemd-detect-virt`/`usermod`/`curl`/`stow` shims; log sha256 tripwire | yes | repository |
| `tests/test-windows-bootstrap.sh` | ~40 required literals in `install.ps1` (wsl invocation, distribution discovery, elevation retry + transcript, Scoop/Noctty, Ghostty config wiring) and in `set-noctty-theme.ps1`; no `winget install`, no pinned `FedoraLinux-44`, no `+perform-action`; single `Start-Process -Verb RunAs` call site; shared Ghostty config keys | `grep -F`/`grep -Fc` over PowerShell source text; `awk` range extraction per function; **optional** `pwsh` AST parse only `if command -v pwsh` | yes | repository (grep only; pwsh absent in the Fedora container) |
| `tests/test-windows-bootstrap.ps1` | Both PowerShell files parse; `set-noctty-theme.ps1` writes `theme = catppuccin-<flavor>.conf` with CRLF, replaces it on rerun, leaves no `theme-*.tmp`, writes no UTF-8 BOM; helper has no `+perform-action` | `[Parser]::ParseFile`; **real execution** of the theme helper against redirected `LOCALAPPDATA`/`USERPROFILE`; byte inspection | no | windows |
| `tests/test-macos.sh` | macOS dry-run strings incl. `--no-defaults`/`--tailscale` gating; Brewfile owns 16 tools and none of the 5 mise-owned ones; no yabai/skhd/xdg-open anywhere; AeroSpace TOML parses and has ≥40 bindings and 10 specific ones; workspace-grid arithmetic (5 cases); `apply-defaults.sh` dry-run/restore plans; docs strings; `nvim-macos` override exists and is wired | real `install.sh --dry-run`; `grep`/`rg`; `python3` + `tomllib` structural check; fake `aerospace` PATH shim for the grid; real `apply-defaults.sh --dry-run` | yes | repository **and** macos |
| `tests/test-neovim-first-launch.lua` | `dotnet.lua` performs exactly one `get_pkg_path` lookup with `warn=false`; `mason.packages()` returns 16 incl./excl. specific entries; Markdown Mason/lint opts strip project tools without touching yaml; `mason.lua` mirrors the inventory and empties `ensure_installed` under `DOTFILES_MASON_BOOTSTRAP=1`; `bootstrap-mason.lua` calls `MasonInstall` with the inventory and registers the custom registry | headless `nvim -u NONE`; `dofile` of real plugin specs with `_G.LazyVim` and `package.loaded` stubbed | via `test-neovim-tool-ownership.sh` | repository |
| `tests/test-ocaml-dap.lua` | OCaml DAP config is inert without opam; `project_root`, `parse_rule_targets` (only unique `.bc`), `check_workspace_root`, `check_dune_project`, `discover_targets`, `build_target` (success/failure/missing artifact) and `dune_program`'s two abort paths behave | headless `nvim -l`; real module under test with injected callbacks; `vim.deep_equal`/pattern asserts; `vim.notify` and `package.loaded.dap` stubbed | via `test-neovim-tool-ownership.sh` | repository |
| `tests/fixtures/{angular,python,ocaml,latex}-smoke` | Not tests; project fixtures consumed by `scripts/test-dev-workflows.sh` (real builds) and grep-asserted by `test-neovim-tool-ownership.sh` / `test-latex-profile.sh` | n/a | n/a | fixtures grep-checked in repository; builds in no CI job |

### 2. Copy-pasted shell-test helper patterns

**`fail` + grep-based `assert_contains(file, needle)`** - `test-markdown-workflow.sh:7-17`, `test-latex-profile.sh:10-20`, `test-sftp-baseline.sh:6-16`, `test-neovim-tool-ownership.sh:7-18`. Identical bodies; only the failure prefix differs.

**String-based `assert_contains(haystack, needle)`** - `test-installer-options.sh:34-41`, `test-fedora-wsl.sh:8-15`, `test-macos.sh:12-19`, `test-ai-profile.sh:117-123`, `test-parrot-ctf.sh:8-13`. Drift: the same function name carries the **opposite first-argument meaning** (a file path in the grep family, a string in this one); `test-parrot-ctf.sh` drops the `local` declarations and uses `$1`/`$2` directly; `test-macos.sh` names the parameter `value`, `test-fedora-wsl.sh` names it `output`.

**`fail_with_context`** - `test-containers.sh:213-222`, `test-containers-wsl.sh:241-250`, `test-tailscale.sh:109-118`, `test-wsl-interop.sh:6-15` are byte-identical; `test-hardening.sh:286-295` is a nested copy that prefixes `[$scenario_name]`.

**`new_test_root` + `base_environment` factory pair** - `test-containers.sh:6-211`, `test-containers-wsl.sh:6-239`, `test-tailscale.sh:6-107`, `test-wsl-interop.sh:84-120`. Drift: containers-wsl adds `ps`/`ip` mocks and cgroup/userns/bus variables; tailscale omits `id`/`usermod`; wsl-interop keeps only `dnf`/`rpm`/`sudo`.

**Temp dir + EXIT trap** - `test_root="$(mktemp -d)"; trap 'rm -rf -- "$test_root"' EXIT` at `test-platform-boundary.sh:5-6`, `test-local-state.sh:5-6`, `test-theme.sh:5-6`, `test-kde-theme.sh:5-6`, `test-idempotency.sh:5-6`, `test-installer-options.sh:7-8`, `test-ocaml-profile.sh:5-6`, `test-mocked-installs.sh:5-6`, `test-asus-preflight.sh:5-6`, `test-asus-verification.sh:5-6`, `test-vm-host.sh:5-6`, `test-vm-guest.sh:5-6`, `test-desktop-tools.sh:5-6`, `test-ai-profile.sh:5-6`, `test-fedora-wsl.sh:5-6`, `test-parrot-ctf.sh:5-6`, `test-sway-config.sh:13-14`, `test-macos.sh:9-10`. Drift: `test-containers.sh`, `test-containers-wsl.sh`, `test-tailscale.sh`, `test-wsl-interop.sh` and `test-hardening.sh` register **no trap** and instead `rm -rf` per scenario, so an early failure leaks the directory.

**`test_environment=(env HOME=… XDG_CONFIG_HOME=… PATH=$mock_bin:$PATH …)` array** - `test-mocked-installs.sh:81-92`, `test-idempotency.sh:285-296`, `test-vm-host.sh:89-99`, `test-vm-guest.sh:65-75`, `test-desktop-tools.sh:74-83`, `test-ai-profile.sh:107-115`, `test-ocaml-profile.sh:54-61`, `test-fedora-wsl.sh:219-228`, `test-parrot-ctf.sh:95-106`, and as a function at `test-asus-verification.sh:69-76`. Drift: the four factory-style files instead emit bare `KEY=VALUE` lines through `printf`/`mapfile` and prepend `env` at each call site.

**Fake sudo** - five incompatible dialects:
- log-only, always succeed: `test-power-profiles.sh:44-46` (shell function), `test-kde-theme.sh:29-32`, `test-fedora-wsl.sh:154-161`, `test-mocked-installs.sh:41-48`.
- log-nothing, side-effect only: `test-idempotency.sh:153-159` (records the shell but writes no command log).
- log then `exec "$@"`: `test-tailscale.sh:35-39`, `test-wsl-interop.sh:100-104`, `test-vm-guest.sh:41-45`, `test-parrot-ctf.sh:64-68`; the `dnf`-shortcircuit variant at `test-containers.sh:74-81`, `test-containers-wsl.sh:87-94`, `test-desktop-tools.sh:39-46`, `test-vm-host.sh:28-35` (also short-circuits `usermod`).
- mutation tripwire: `test-asus-preflight.sh:23-27` logs and `exit 97`; the same idea as `test-installer-options.sh:13-23`'s `mutation-guard`.
- root-filesystem emulator: `test-hardening.sh:177-232` rewrites `/etc`/`/var` into `$FAKE_ROOT` and re-implements `install` flag parsing.

**Fake dnf** - identical logger at `test-mocked-installs.sh:14-17`, `test-vm-host.sh:12-15`, `test-vm-guest.sh:16-19`, `test-desktop-tools.sh:23-26`, `test-hardening.sh:39-42`, `test-containers.sh:18-21`, `test-containers-wsl.sh:21-24`; silent `exit 0` variant at `test-asus-preflight.sh:11-14`, `test-fedora-wsl.sh:146-149`, `test-wsl-interop.sh:92-95`; repo-creating variant at `test-tailscale.sh:16-24`.

**Fake rpm** - `$RPM_PRESENT` table at `test-kde-theme.sh:18-27` (quoted heredoc) and `test-desktop-tools.sh:28-37` (unquoted heredoc with `\$` escapes - same logic, drifted quoting); case-list variants at `test-mocked-installs.sh:18-24`, `test-idempotency.sh:145-151`, `test-vm-guest.sh:21-27`, `test-asus-verification.sh:11-31`; blanket `exit 0` at `test-vm-host.sh:17-20`, `test-hardening.sh:44-47`, `test-containers.sh:23-26`, `test-asus-preflight.sh:15-18`, `test-fedora-wsl.sh:150-153`.

**Fake stow printing its last argument** - identical three lines at `test-platform-boundary.sh:51-55`, `test-fedora-wsl.sh:213-216`, `test-parrot-ctf.sh:89-92`.

**Fake `id`/`getent` pair** - `test-mocked-installs.sh:49-65`, `test-idempotency.sh:161-178`, `test-fedora-wsl.sh:162-178` **and again** `test-fedora-wsl.sh:375-391`, `test-parrot-ctf.sh:69-76`. Drift: the Parrot `getent` ignores its arguments entirely and always prints the `parrot-test` row.

**Fake systemctl unit-state store** - `test-hardening.sh:102-127`, `test-tailscale.sh:41-70`, `test-containers.sh:83-116`, `test-containers-wsl.sh:96-129`. Drift: two different "last argument" idioms for the same job (`"${args[-1]}"` vs `"${*: -1}"`).

**Fake `nvim` Mason provisioner** - full version with hang/fail knobs at `test-neovim-bootstrap.sh:12-31`; reduced copies of the same loop at `test-idempotency.sh:238-247` and `test-fedora-wsl.sh:413-422`.

**KDE mock set** (`lookandfeeltool`, `kwriteconfig6`, `plasma-apply-*`, `qdbus6`) duplicated between `test-theme.sh:54-82` and `test-kde-theme.sh:47-80`; drift: the `qdbus6` in `test-theme.sh` also emulates capture/restore JSON, the one in `test-kde-theme.sh` only logs.

**Minimal-PATH sandbox builder** - the identical `for command in bash basename cat chmod dirname mkdir mktemp mv readlink` loop at `test-theme.sh:84-86` and `test-idempotency.sh:88-90`.

**Fake `curl` installer emitter** - three mutually incompatible versions: `test-fedora-wsl.sh:183-212` (writes to `--output`), `test-parrot-ctf.sh:77-88` (heredoc to `--output`), `test-ai-profile.sh:73-92` (prints to stdout for `| sh`).

**Local Git origin fixture** (`init`, commit, `tag v2.3.0`) duplicated at `test-idempotency.sh:268-279` and `test-fedora-wsl.sh:439-448`.

### 3. Install steps → test / verify

| Install step | Test that executes it | Verify that checks its result |
|---|---|---|
| `platforms/fedora/scripts/install-system.sh` | test-mocked-installs, test-idempotency | fedora `verify.sh` (Core commands, SFTP, login shell) |
| `.../install-terra.sh` | test-mocked-installs | none |
| `.../install-ocaml.sh` (Fedora opam deps) | test-mocked-installs | `common/verify-ocaml.sh` (indirect) |
| `.../install-asus-hardware.sh` | test-asus-preflight, test-mocked-installs | `verify-asus-hardware.sh` |
| `.../install-sway.sh` | test-mocked-installs | fedora `verify.sh` Sway section |
| `.../install-vm-host.sh` | test-vm-host | `verify-vm-host.sh` |
| `.../install-vm-guest.sh` | test-vm-guest, test-idempotency | `verify-vm-guest.sh` |
| `.../install-hardening.sh` | test-hardening | `verify-hardening.sh` |
| `.../install-desktop-tools.sh` | test-desktop-tools | `verify-desktop-tools.sh` |
| `.../install-containers.sh` | test-containers | `verify-containers.sh` |
| `.../install-tailscale.sh` | test-tailscale | `verify-tailscale.sh` |
| `.../install-kde-theme.sh` | test-kde-theme | fedora `verify.sh` (`kio-extras` only) |
| `.../apply-kde-theme.sh` | test-kde-theme | none |
| `.../install-latex.sh` | test-mocked-installs, test-fedora-wsl | none on Fedora; fedora-wsl `verify.sh --latex` |
| `.../setup-local.sh`, `stow.sh` | test-local-state, test-sway-config, test-idempotency, test-platform-boundary | fedora `verify.sh` (Stow links, Theme, Git local) |
| `common/install-mise.sh` | only inside the mocked bootstraps (test-idempotency, test-fedora-wsl, test-parrot-ctf) | fedora/wsl `verify.sh` mise section |
| `common/install-neovim-tools.sh` | test-neovim-bootstrap | fedora/wsl `verify.sh` Neovim tooling |
| `common/install-tmux-theme.sh` | mocked bootstraps only | fedora `verify.sh` Catppuccin tmux |
| `common/install-ocaml.sh` | test-ocaml-profile | `common/verify-ocaml.sh` |
| `common/install-ai.sh` | test-ai-profile | `common/verify-ai.sh` |
| `common/setup-local.sh`, `common/stow.sh` | test-fedora-wsl, test-parrot-ctf, test-platform-boundary | wsl/macos/parrot `verify.sh` |
| `bin/.local/bin/theme` | test-theme, test-idempotency, test-fedora-wsl | fedora `verify.sh` Theme section |
| `platforms/fedora-wsl/scripts/install-system.sh` | test-fedora-wsl | wsl `verify.sh` |
| `.../configure-interop.sh` | test-wsl-interop, test-fedora-wsl | wsl `verify.sh` interop section |
| `.../install-containers.sh` (WSL) | test-containers-wsl | wsl `verify-containers.sh` |
| `.../stow.sh` (WSL) | test-fedora-wsl | wsl `verify.sh` Configuration links |
| `platforms/macos/scripts/install-system.sh` | none (text grep only) | macos `verify.sh` |
| `platforms/macos/scripts/install-containers.sh` | none | macos `verify.sh --containers` |
| `platforms/macos/scripts/install-tailscale.sh` | none (text grep only) | macos `verify.sh --tailscale` |
| `platforms/macos/scripts/apply-defaults.sh` | test-macos (`--dry-run` only) | macos `verify.sh --defaults` |
| `platforms/macos/scripts/stow.sh` | test-platform-boundary | macos `verify.sh` |
| `platforms/parrot-ctf/scripts/install-system.sh`, `install-guest-integration.sh`, `stow.sh` | test-parrot-ctf | parrot `verify.sh` |
| `platforms/windows/set-noctty-theme.ps1` | test-windows-bootstrap.ps1 (real run) | none |

**Steps with NO test and NO verify:**
- `platforms/macos/scripts/install-ocaml.sh` - never executed by a test; macOS `verify.sh` has no OCaml section and does not call `common/verify-ocaml.sh` (that only happens via `scripts/test-dev-workflows.sh --ocaml`, which `install.sh` runs only when `--workflows` is also passed).
- `platforms/windows/install.ps1` - grep- and AST-checked only; no execution test, no verify counterpart.
- `scripts/update-starship-themes.sh` - no test file references it; no verify check.
- `docs/cheatsheets/generate.sh` - only its existence and executable bit are asserted (`test-cheatsheet-bindings.sh:137-143`); never executed, no verify check.
- `platforms/fedora/stow/sway/.local/bin/sway-screenshot` - `bash -n` only (`test-sway-config.sh:175`).
- `platforms/fedora/scripts/install-terra.sh` and `install-latex.sh` (Fedora) - tested but not verified.
- `platforms/fedora/scripts/apply-kde-theme.sh` - tested but not verified.

### 4. Verify scripts

| Verify script | Checks | Produced by | Automatic? |
|---|---|---|---|
| `platforms/fedora/scripts/verify.sh` (780 L) | core commands, `openssh-clients`/`ssh -V`, Dolphin+`kio-extras`, SELinux/firewalld/Secure Boot, Zsh login shell, 11 Stow links, theme state and assets, Sway session, machine-local Git config, mise, Neovim+Mason inventory, tmux theme pin, repository hygiene; dispatches to 8 sub-verifiers gated on `$XDG_CONFIG_HOME/dotfiles/<profile>.conf` | the whole Fedora install | yes, `platforms/fedora/install.sh:884` |
| `platforms/fedora-wsl/scripts/verify.sh` (450 L) | WSL runtime, Linux-native commands, Zsh PATH/starship sentinels, Windows `.exe` interop + binfmt hint, runtimes, Neovim tooling, config links; optional `--latex`, AI, OCaml, containers, `--smoke-test` | Fedora WSL install | yes, `platforms/fedora-wsl/install.sh:452` |
| `platforms/macos/scripts/verify.sh` (255 L) | SIP/Gatekeeper/arm64, ~30 commands, config links incl. `nvim-macos`; `--defaults`, `--containers`, `--tailscale` | macOS install | yes, `platforms/macos/install.sh:201` |
| `platforms/parrot-ctf/scripts/verify.sh` (96 L) | KVM guest channels, APT-owned packages, commands, mise `uv`, agent units, Stow links, CTF safety state | Parrot install | yes, `platforms/parrot-ctf/install.sh:111` |
| `common/verify-ai.sh` (331 L) | `mise/conf.d/ai.toml` ownership, core agents, AGENTS.md links, GNHF, FirstMate + toolchain, `lavish-axi`, Treehouse, No Mistakes, backpass | `--ai` (+ `--codex/--firstmate/--gnhf/--backpass`) | yes, via `install-ai.sh:393` and both `verify.sh` |
| `common/verify-ocaml.sh` (36 L) | `opam` present, switch compiler version, opam-managed tools | `--ocaml` | yes on Fedora/WSL `verify.sh`; not on macOS |
| `verify-asus-hardware.sh` (247 L) | `hardware.conf`, DMI match, packages, `asusd`/`asus-shutdown`, masked profile daemons, Armoury, Secure Boot, NVIDIA module + MOK enrolment, AMD dual-GPU + `amdgpu`, Mesa VA-API capability, charge limit | `--hardware`/`--secure-boot`/`--charge-limit` | via `verify.sh:581` when `hardware.conf` exists; not from its installer |
| `verify-vm-host.sh` (165 L) | commands, KVM/libvirt/net/pool, advisory WARN handling, optional `--smoke-test` `virt-install --dry-run` | `--vm-host` | yes (`install-vm-host.sh:126/203`) and `verify.sh:597` |
| `verify-vm-guest.sh` (115 L) | hypervisor type, packages, virtio channels, agent units, rejected clipboard bridge, default route | `--vm-guest` | yes (`install-vm-guest.sh:160`) and `verify.sh:613` |
| `verify-hardening.sh` (318 L) | SELinux, firewalld, Secure Boot, faillock, sudo logging, auditd, 3 sysctls, SSH posture, dnf-automatic, mount options and service watch-list (report only), credential permissions | `--hardening` | yes (`install-hardening.sh:186`) and `verify.sh:629` |
| `verify-desktop-tools.sh` (96 L) | 8 commands; 24 MIME→desktop defaults (mismatch = warning, not failure) | `--desktop-tools` | via `verify.sh:645` only |
| `verify-containers.sh` (Fedora, 312 L) | podman version, rootless, network backend, subuid/subgid, API socket, full smoke test unless `--skip-smoke-test` | `--containers`, `--containers-api-socket` | yes (`install-containers.sh:165`, full smoke) and `verify.sh:665` with `--skip-smoke-test` |
| `verify-containers.sh` (WSL, 78 L) | systemd PID 1, `--user` session, cgroup v2, userns, networking hint, Linux filesystem, then delegates to the Fedora verifier | `--containers` on WSL | yes (`install-containers.sh:67` via `--validate`) and wsl `verify.sh:411` |
| `verify-tailscale.sh` (107 L) | `tailscale` present, `tailscaled` enabled/active, version, backend state (Running / NeedsLogin both pass) | `--tailscale` | yes (`install-tailscale.sh:120`) and `verify.sh:682` |

### 5. CI platform coverage

- **Fedora 44**: all 32 `tests/*.sh` plus both Lua tests execute here, but inside a `fedora:44` **container** with no systemd, KDE, Sway, GPU or real DNF transactions - every system mutation is mocked. `lint.sh` covers all tracked `.sh`.
- **macOS 26 arm64**: only `tests/test-macos.sh` and `lint.sh`. That file executes no macOS install script; its only real execution is `install.sh --platform macos --dry-run`, `apply-defaults.sh --dry-run`, and the `aerospace-workspace-grid` mock. No Lua test, no `test-dev-workflows.sh`.
- **Windows**: only `tests/test-windows-bootstrap.ps1`. `install.ps1` is parsed, never run. `tests/test-windows-bootstrap.sh` runs on Fedora, where `pwsh` is absent, so its AST-parse block (lines 114-132) is skipped there.
- **Not covered by any CI runner**: Fedora WSL (all WSL coverage is mocked on the Fedora container), Parrot Security 7.3 (mocked on Fedora), KDE Plasma/Wayland and Sway sessions, `scripts/test-dev-workflows.sh` and all four `tests/fixtures/*` builds, `docs/cheatsheets/generate.sh`, ShellCheck/`bash -n` on `.ps1` and `.lua` files.

### 6. Assertions structurally incapable of failing

- `tests/test-sftp-baseline.sh:73-75` - `for interactive_command in ls cd lcd pwd lpwd get put mget mput mkdir rm exit; do assert_contains "$readme" "$interactive_command"`. These are unanchored `grep -Fq` substring searches over the 4462-line README. `ls` and `rm` each match 281 lines, `get` 36, `put` 25, `cd` 11, `exit` 7 - as substrings of ordinary words ("tools", "form", "target", "included"). Deleting the entire SFTP section from the README would not fail these members of the loop.
- `tests/test-containers.sh:232` - `grep -Fq 'podman' <<<"$dry_run_output"`. The dry-run plan hard-codes `podman` in fixed prose (`platforms/fedora/scripts/install-containers.sh:94` "crun (installed as a podman dependency)", `:98` "no concrete value beyond podman here", `:127`), independent of the `container_packages` array the assertion is meant to cover.
- `tests/test-containers.sh:233` - `grep -Fq 'podman-compose' <<<"$dry_run_output"`. Same cause: `install-containers.sh:97` prints `Compose:  podman-compose, used automatically by 'podman compose'` unconditionally.
- `tests/test-latex-profile.sh:45-50` - six `assert_contains` calls against `tests/fixtures/latex-smoke/*`. The test greps its own fixture; no change to `install-latex.sh`, the VimTeX config or any verify script can make these fail.
- `tests/test-latex-profile.sh:52-56` - three `assert_contains` calls against `scripts/test-dev-workflows.sh`. This asserts the text of a sibling test harness, not any implementation; and that harness runs in no CI job.
- `tests/test-neovim-tool-ownership.sh:176-185` - ten `assert_contains` calls against `tests/fixtures/angular-smoke/{package.json,angular.json,.vscode/launch.json}`.
- `tests/test-neovim-tool-ownership.sh:188-190` - three `assert_contains` calls against `tests/fixtures/python-smoke/{pyproject.toml,.vscode/launch.json}`. Both blocks grep the test's own fixtures.
---

## Appendix D: keybinding and cheat-sheet coverage inventory


All line numbers are as tracked in `/home/user/dotfiles`. "Rendered" means a `.tex` file inherits content through `\input{common-workflow}`.

---

### 1. Per-source repo-defined bindings and commands

### `platforms/fedora/stow/sway/.config/sway/config` (139 lines)
Modifiers: `$mod=Mod4` (Super), `$alt=Mod1`, `$left/$down/$up/$right = h/j/k/l` (L2-7).

| Line | Binding | Action |
|---|---|---|
| 17 | `floating_modifier $mod normal` | Super + mouse drag moves/resizes floating windows |
| 38 | `$mod+Return` | exec ghostty |
| 39 | `$mod+p` | exec fuzzel (launcher) |
| 40 | `$mod+Shift+c` | kill |
| 41 | `$mod+f` | fullscreen toggle |
| 42 | `$mod+Shift+x` | swaylock -f |
| 43 | `$mod+n` | makoctl dismiss |
| 44 | `$mod+Shift+n` | makoctl restore |
| 45 | `$mod+Shift+e` | swaynag exit confirmation |
| 46 | `$mod+Shift+r` | reload |
| 47 | `$mod+$alt+k` | xkb_switch_layout next |
| 50-53 | `$mod+h/j/k/l` | focus left/down/up/right |
| 54-57 | `$mod+Shift+h/j/k/l` | move container |
| 58 | `$mod+b` | splith |
| 59 | `$mod+v` | splitv |
| 60 | `$mod+s` | layout stacking |
| 61 | `$mod+w` | layout tabbed |
| 62 | `$mod+e` | layout toggle split |
| 63 | `$mod+Shift+space` | floating toggle |
| 64 | `$mod+space` | focus mode_toggle |
| 65 | `$mod+a` | focus parent |
| 78-86 | `$mod+1..9` | workspace number 1-9 |
| 87-95 | `$mod+Shift+1..9` | move container to workspace 1-9 |
| 96-99 | `$mod+Ctrl+h/j/k/l` | `sway-workspace-grid left/down/up/right` |
| 102-104 | `XF86AudioRaise/Lower/Mute` | wpctl sink volume 5% / mute toggle |
| 105 | `XF86AudioMicMute` | wpctl source mute toggle |
| 106-107 | `XF86MonBrightnessUp/Down` | brightnessctl 5% |
| 108-110 | `XF86AudioPlay/Next/Prev` | playerctl |
| 111 | `Print` | `sway-screenshot region` |
| 112 | `$mod+Shift+s` | `sway-screenshot region` |
| 113 | `Shift+Print` | `sway-screenshot output` |
| 114 | `$mod+Shift+v` | cliphist list \| fuzzel \| cliphist decode \| wl-copy |
| 129-134 | resize mode `h/j/k/l`, `Return`, `Escape` | shrink width / grow height / shrink height / grow width, exit |
| 136 | `$mod+r` | mode "resize" |

Total: 31 `bindsym` statements plus one `floating_modifier`.

### `platforms/fedora/stow/sway/.local/bin/*`
- `sway-workspace-grid {left|right|up|down}` (L4-33): wrapping 3x3 modular arithmetic over workspaces 1-9; non-1-9 focus falls back to 1.
- `sway-screenshot {region|output}` (L4-22): `region` = slurp + grim + `swappy -f -` (no file written directly); `output` = grim to `${XDG_PICTURES_DIR:-$HOME/Pictures}/Screenshots/<timestamp>.png` plus notify-send.
- `sway-session-start` (no keybinding): sway-systemd session bootstrap, portal restart, `dex-autostart`. Invoked at L117 of the config.
- `power-profile-status` (no keybinding): prints `Power <profile>` from `/sys/firmware/acpi/platform_profile`, then `asusctl`, then `powerprofilesctl`.

### `platforms/fedora/stow/waybar/.config/waybar/config.jsonc`
Mouse bindings only:

| Line | Binding | Action |
|---|---|---|
| 9 | `"disable-scroll": true` | scroll over workspaces deliberately unbound |
| 33 | `sway/language` on-click | `swaymsg input type:keyboard xkb_switch_layout next` |
| 40 | `network` on-click | `nm-connection-editor` |
| 48 | `bluetooth` on-click | `blueman-manager` |
| 53 | `pulseaudio` on-click | `pavucontrol` |
| 27 | `custom/power-profile` exec | `power-profile-status`, 15 s interval |

### `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml`
| Line | Binding | Action |
|---|---|---|
| 30 | `ctrl-alt-enter` | `open -na Ghostty` |
| 33-36 | `ctrl-alt-h/j/k/l` | focus, `--boundaries all-monitors-outer-frame` |
| 37-40 | `ctrl-alt-shift-h/j/k/l` | move, same boundaries |
| 43-46 | `ctrl-alt-cmd-h/j/k/l` | `aerospace-workspace-grid` |
| 48-56 | `ctrl-alt-1..9` | workspace 1-9 |
| 57-65 | `ctrl-alt-shift-1..9` | move-node-to-workspace |
| 68 | `ctrl-alt-b` | layout tiles horizontal |
| 69 | `ctrl-alt-v` | layout tiles vertical |
| 70 | `ctrl-alt-s` | layout accordion vertical |
| 71 | `ctrl-alt-w` | layout accordion horizontal |
| 72 | `ctrl-alt-e` | layout tiles horizontal vertical |
| 73 | `ctrl-alt-shift-space` | layout floating tiling |
| 74 | `ctrl-alt-f` | fullscreen |
| 75 | `ctrl-alt-shift-c` | close |
| 76 | `ctrl-alt-shift-r` | reload-config |
| 77 | `ctrl-alt-r` | mode resize |
| 80 | `ctrl-alt-tab` | focus-monitor next, wrap |
| 81 | `ctrl-alt-shift-tab` | move-node-to-monitor next, focus follows |
| 82 | `ctrl-alt-cmd-tab` | move-workspace-to-monitor next |
| 85-90 | resize mode `h/j/k/l`, `enter`, `esc` | width -50 / height +50 / height -50 / width +50, exit |

`aerospace-workspace-grid` (L13-30) mirrors the Sway grid but exits 1 rather than falling back when focus is outside 1-9.

### `tmux/.tmux.conf`
**Zero keybindings.** Prefix unchanged (`Ctrl+B`). Only options: `base-index 1`, `pane-base-index 1`, `renumber-windows on`, `default-terminal tmux-256color`, `terminal-features xterm-ghostty:RGB`, `history-limit 50000`, `escape-time 10`, `mouse on`, `remain-on-exit off`, `status-interval 5`, Catppuccin flavour/style, optional `~/.config/dotfiles/tmux-theme.conf`.

### Neovim
- `lua/config/keymaps.lua`: **empty** (3 comment lines only).
- `lua/config/options.lua`: no mappings; `maplocalleader` is left at LazyVim's `\`.
- `plugins/latex.lua` L26-33, the only `keys =` spec in the repo: `<localleader>ll` compile, `lv` view/forward-search, `le` errors, `lo` compiler output, `lt` TOC, `li` info, all `ft = "tex"`.
- `plugins/markdown.lua` L34-49 (table-nvim `mappings`): `<M-l>` next cell, `<M-h>` prev cell, `<leader>mK` insert row up, `<leader>mr` insert row down, `<leader>mk` move row up, `<leader>mj` move row down, `<leader>mC` insert column left, `<leader>mc` insert column right, `<leader>mh` move column left, `<leader>ml` move column right, `<leader>mt` insert table, `insert_table_alt = false`, `<leader>md` delete column. L58 registers the `<leader>m` WhichKey group.
- `plugins/dotnet.lua` L98-113: `<leader>tr` Run Nearest, `<leader>tt` Run File, `<leader>td` Debug Nearest; `csproj_mappings = false`, `fsproj_mappings = false` (L82-83) deliberately suppress EasyDotnet's project-file mappings.
- `plugins/ocaml.lua`, `plugins/formatting.lua`, `plugins/colorscheme.lua`, `plugins/mason.lua`, `config/ocaml_dune.lua`: no keymaps. OCaml contributes two named DAP configurations, not keys.
- `platforms/fedora-wsl/.../nvim-wsl/plugins/wsl.lua`: no keys. Rebinds behaviour behind existing keys - `vim.ui.open` (so `gx`) to `wsl-open` (L8-10), `mkdp_browserfunc` (L12, L21-25), VimTeX viewer to `wsl-open` (L17-19), and clipboard `+`/`*` to `wsl-copy`/`wsl-paste` (L32-43).
- `platforms/macos/.../nvim-macos/plugins/macos.lua`: no keys. VimTeX viewer set to `open` (L9-11).

### Ghostty
`ghostty/.config/ghostty/config` (8 lines) and `shared.conf` (8 lines): **no `keybind =` anywhere**. Only `config-file`, `theme`, `shell-integration = zsh`, `shell-integration-features`.

### `lazygit/.config/lazygit/config.yml`
4 lines. `git.diffRenderers` = delta. **No keybindings.**

### Zsh
`zsh/.config/zsh/.zshrc`: **no `bindkey`, no ZLE widget, no `zle -N` anywhere in the repo** (verified by grep). Repo-defined interactive surface:
- Aliases L80-84: `ls`=eza, `ll`=eza -lah --git, `la`=eza -a, `tree`=eza --tree, `cat`=bat.
- Function L54-57: `theme()` wrapper that calls `command theme "$@"` then `exec zsh`.
- `FZF_CTRL_R_OPTS` L66-74 (preview pane only, no rebinding); `fzf --zsh` L77; `zoxide init zsh` L60; `mise activate` L87; `starship init` L99.

Four platform overlays define **no bindings at all**: `platforms/fedora/.../platform.zsh` and `platforms/fedora-wsl/.../platform.zsh` (identical, 3 lines each: autosuggestions + syntax-highlighting), `platforms/macos/.../platform.zsh` (Homebrew paths for the same two plugins), `platforms/parrot-ctf/.../platform.zsh` (guarded Debian paths). `platforms/fedora-wsl/.../platform-env.zsh` strips `/mnt/*` from PATH and sets `BROWSER=wsl-open`; `platforms/macos/.../platform-env.zsh` prepends gnubin/homebrew paths.

### `bin/.local/bin/theme`
`theme {latte|frappe|macchiato|mocha} [--preserve-wallpaper]`, `-h/--help`. Writes theme state, `tmux source-file ~/.tmux.conf` if a server is running, then sources every `~/.config/dotfiles/theme-hooks.d/*.sh`.

### WSL interop (`platforms/fedora-wsl/stow/interop/.local/bin/`)
`wsl-copy` (stdin to `clip.exe`), `wsl-open URL_OR_PATH` (exactly one argument, `explorer.exe`), `wsl-paste` (PowerShell `Get-Clipboard -Raw`, CR stripped). All honour `WINDOWS_SYSTEM_ROOT`.

### KDE theme scripts
`apply-kde-theme.sh` and `install-kde-theme.sh` set **no keyboard shortcuts**. `kwriteconfig6` is used only for `kwinrc` `BorderSizeAuto` (L106-109) and `kscreenlockerrc` wallpaper keys (L160-175). No `kglobalshortcut`, `kglobalaccel`, or `khotkeys` call exists anywhere in the repo.

---

### 2. Defined in the repo, documented in no cheat sheet and not in `keybindings.md`

| Binding | What it does | Defined at | Which cheat sheet should carry it |
|---|---|---|---|
| `Super + mouse drag` | Move/resize floating windows | `platforms/fedora/stow/sway/.config/sway/config:17` | fedora-sway |
| Waybar network click | `nm-connection-editor` | `.../waybar/config.jsonc:40` | fedora-sway |
| Waybar bluetooth click | `blueman-manager` | `.../waybar/config.jsonc:48` | fedora-sway |
| Waybar pulseaudio click | `pavucontrol` | `.../waybar/config.jsonc:53` | fedora-sway |
| Workspace scroll unbound | `disable-scroll: true` | `.../waybar/config.jsonc:9` | fedora-sway (note) |
| `power-profile-status` module | Waybar power-profile readout | `.../waybar/config.jsonc:25-29`, script `.../sway/.local/bin/power-profile-status:31` | fedora-sway |
| `Ctrl+Opt+E` | `layout tiles horizontal vertical` | `aerospace.toml:72` | macos (the Sway peer `Super+E` is documented) |
| `<leader>tr` | Run nearest test (EasyDotnet lhs) | `plugins/dotnet.lua:100` | common-workflow |
| `<leader>tt` | Run all tests in buffer | `plugins/dotnet.lua:105` | common-workflow |
| `<leader>td` | Debug nearest test | `plugins/dotnet.lua:110` | common-workflow |
| `<leader>mK` | Insert table row above | `plugins/markdown.lua:38` | common-workflow |
| `<leader>mk` | Move table row up | `plugins/markdown.lua:40` | common-workflow |
| `<leader>mj` | Move table row down | `plugins/markdown.lua:41` | common-workflow |
| `<leader>mC` | Insert table column left | `plugins/markdown.lua:42` | common-workflow |
| `<leader>mh` | Move table column left | `plugins/markdown.lua:44` | common-workflow |
| `<leader>ml` | Move table column right | `plugins/markdown.lua:45` | common-workflow |
| `<leader>md` | Delete table column | `plugins/markdown.lua:48` | common-workflow |
| `bat` shim | `exec batcat` | `platforms/parrot-ctf/stow/command-shims/.local/bin/bat:2` | no Parrot sheet exists |
| `fd` shim | `exec fdfind` | `platforms/parrot-ctf/.../fd:2` | no Parrot sheet exists |
| `sway-screenshot output` file destination | notify-send with saved path | `.../sway-screenshot:16` | fedora-sway (path is documented; the notification is not) |

Note on the LaTeX `<localleader>l*` set: it is in `keybindings.md` L161-169 but in **none** of the five `.tex` files, including `common-workflow.tex`, despite `docs/cheatsheets/README.md:20-22` asserting that `keybindings.md` is "the same shared content" as `common-workflow.tex`. The Markdown table-nvim block is in the same position. Nothing in Parrot Security is covered by any sheet.

---

### 3. Documented but not defined by the repo (and not an upstream default)

| Documented claim | Doc file:line | Why it looks wrong |
|---|---|---|
| `Ctrl+Shift+,` "Reload Noctty config" under a "Noctty" heading | `docs/cheatsheets/fedora-wsl.tex:26` | The repo sets no `keybind =` in `shared.conf` (its own Ghostty section says so at `common-workflow.tex:5`). This is an upstream Ghostty/Noctty default, and the only repo trace is a `Write-Host` hint at `platforms/windows/set-noctty-theme.ps1:42`. It is the one `\csrow` in the sheets presented without the "upstream default" label the sheets use elsewhere. |
| "ASUS screenshot key / `Print`" | `README.md:3243` | Only `bindsym Print` exists (`sway/config:111`). No ASUS-specific keysym, `XF86`, or `asusctl` hotkey is bound anywhere; the claim depends on the hardware emitting `Print`. |
| `Super+Alt+K` presented as the KDE shortcut in a table headed "Fedora KDE and Sway use the same two-layout workflow" | `README.md:3177-3179` | On KDE the actual shortcut is Plasma's `Meta+Alt+K`, and the repo scripts no KDE global shortcut. Same page later states this correctly at L3187. `fedora-kde.tex:16-18` gets it right; the README table does not. |
| "`keybindings.md` is the same shared content as `common-workflow.tex`" | `docs/cheatsheets/README.md:20-22` | `common-workflow.tex` omits the Markdown/table-nvim section (`keybindings.md:132-152`) and the whole LaTeX/VimTeX section (`keybindings.md:154-173`). No rendered sheet carries `\ll`, `\lv`, `\le`, `\lo`, `\lt`, `\li`. |
| "restarts the current shell" attributed to `theme` | `docs/keybindings.md:57-59` | `bin/.local/bin/theme` never re-execs a shell. The restart comes from the `theme()` wrapper in `.zshrc:54-57`, so the behaviour is absent for non-interactive or non-Zsh callers. |
| "Waybar's `sway/language` module ... switches layout when clicked" implied as the Sway-only indicator | `fedora-sway.tex:79` | Accurate for the module, but the sheet has no other Waybar content while the config defines three further click handlers (network, bluetooth, pulseaudio) and the `power-profile-status` module. Not wrong, incomplete. |

Everything else in the docs checks out against the code: fzf `Ctrl-R`/`Ctrl-T`/`Alt-C` are correctly flagged as upstream (`.zshrc` only sets `FZF_CTRL_R_OPTS`), tmux prefix `Ctrl+B` is genuinely unmodified, all LazyVim/dap/Lazygit rows are correctly attributed to upstream, `macos.tex:74`'s screenshot-destination claim is backed by `platforms/macos/scripts/apply-defaults.sh:49-55`, and `fedora-wsl.tex:14`'s `enabled=true` / `appendWindowsPath=false` is backed by `platforms/fedora-wsl/scripts/configure-interop.sh:70,87-89`.

---

### 4. Same logical action, different keys per platform

| Action | Sway key | AeroSpace key | KDE key | WSL key | Consistent? |
|---|---|---|---|---|---|
| Open terminal | `Super+Enter` | `Ctrl+Opt+Enter` | not repo-bound | n/a | Yes, by design (modifier family differs) |
| App launcher | `Super+P` | `Cmd+Space` (native Spotlight) | Plasma stock | n/a | No, deliberate |
| Focus left/down/up/right | `Super+H/J/K/L` | `Ctrl+Opt+H/J/K/L` | none | none | Yes |
| Move container | `Super+Shift+HJKL` | `Ctrl+Opt+Shift+HJKL` | none | none | Yes |
| Workspace 1-9 | `Super+1..9` | `Ctrl+Opt+1..9` | none | none | Yes |
| Send to workspace | `Super+Shift+1..9` | `Ctrl+Opt+Shift+1..9` | none | none | Yes |
| 3x3 grid navigation | `Super+Ctrl+HJKL` | `Ctrl+Opt+Cmd+HJKL` | none | none | **No.** Sway adds Ctrl to `$mod`; AeroSpace adds Cmd to its `$mod`. Different extra key for the same action |
| Split horizontal | `Super+B` | `Ctrl+Opt+B` | none | none | Yes |
| Split vertical | `Super+V` | `Ctrl+Opt+V` | none | none | Yes |
| Stacking / accordion-v | `Super+S` | `Ctrl+Opt+S` | none | none | Yes |
| Tabbed / accordion-h | `Super+W` | `Ctrl+Opt+W` | none | none | Yes |
| Toggle split layout | `Super+E` | `Ctrl+Opt+E` | none | none | Yes in code; **documented only on Sway** |
| Toggle floating | `Super+Shift+Space` | `Ctrl+Opt+Shift+Space` | none | none | Yes |
| Fullscreen | `Super+F` | `Ctrl+Opt+F` | none | none | Yes |
| Close window | `Super+Shift+C` | `Ctrl+Opt+Shift+C` | Plasma stock `Alt+F4` | n/a | Yes for the two tiling WMs |
| Reload WM config | `Super+Shift+R` | `Ctrl+Opt+Shift+R` | n/a | n/a | Yes |
| Resize mode | `Super+R`, then `H/J/K/L` | `Ctrl+Opt+R`, then `H/J/K/L` | none | none | Yes, including inner keys and `Enter`/`Esc` |
| Focus parent | `Super+A` | **unbound** | none | none | **No** |
| Tiling/floating focus toggle | `Super+Space` | **unbound** | none | none | **No** |
| Focus next display | via boundary `HJKL` only | `Ctrl+Opt+Tab` | none | none | **No.** AeroSpace has three explicit display bindings Sway lacks |
| Lock session | `Super+Shift+X` | unbound (macOS `Ctrl+Cmd+Q`) | Plasma stock | n/a | **No** |
| Exit session | `Super+Shift+E` | unbound | Plasma stock | n/a | **No** |
| Keyboard layout US/DK | `Super+Alt+K` | none (Option reserved for Danish entry) | `Meta+Alt+K` (Plasma default) | none, Windows owns input | **No.** Same chord shape, different modifier name; absent on two profiles |
| Dismiss / restore notification | `Super+N` / `Super+Shift+N` | unbound | Plasma stock | n/a | **No** |
| Screenshot region | `Print`, `Super+Shift+S` | `Cmd+Shift+4` (macOS default) | Plasma stock | n/a | **No** |
| Clipboard history | `Super+Shift+V` | unbound | Plasma Klipper stock | n/a | **No** |
| CLI clipboard copy | `wl-copy` | `pbcopy` | `wl-copy` | `wsl-copy` | **No**, three different command names for one action |
| Theme switch | `theme <f>` | `theme <f>` | `theme <f>` | `theme <f>` | Yes |

---

### 5. Where each custom script and alias appears among the five `.tex` files

`csrow` = an explicit key/command row. "Rendered" = present in the PDF only because the sheet `\input`s `common-workflow.tex`.

| Item | common-workflow | fedora-kde | fedora-sway | fedora-wsl | macos |
|---|---|---|---|---|---|
| `theme` | csrow L14 | csrow L23 (own Theme section) | rendered only, no own row | rendered + referenced L26 | rendered only |
| `sway-workspace-grid` | no | no | named L47 (note, not a csrow) | no | no |
| `aerospace-workspace-grid` | no | no | no | no | named L36 (note, not a csrow) |
| `sway-screenshot` | no | no | **never named**; its two modes appear as csrows L89-90 | no | no |
| `power-profile-status` | no | no | **absent** | no | no |
| `sway-session-start` | no | no | **absent** (internal) | no | no |
| `wsl-open` | no | no | no | csrow L18 + note L22 | no |
| `wsl-copy` | no | no | no | csrow L19 | no |
| `wsl-paste` | no | no | no | csrow L20 | no |
| Parrot `bat` shim | no | no | no | no | no |
| Parrot `fd` shim | no | no | no | no | no |
| alias `ls` / `ll` / `la` | csrow L11 | rendered | rendered | rendered | rendered |
| alias `tree` | csrow L12 | rendered | rendered | rendered | rendered |
| alias `cat` | csrow L13 | rendered | rendered | rendered | rendered |

Every alias reaches all four profile sheets through the single `common-workflow.tex` block. Of nine repo scripts, three (`power-profile-status`, `sway-session-start`, and both Parrot shims) appear in no sheet; `sway-screenshot` appears only by its effect.

---

### 6. `generate.sh`, `cheatsheet.sty`, and `tests/test-cheatsheet-bindings.sh`

**`docs/cheatsheets/generate.sh`** (45 lines): `cd`s to its own directory, defaults `sheets=(fedora-kde fedora-sway fedora-wsl macos)` and accepts sheet names as arguments (L18-21). Requires `latexmk` and exits 1 with Fedora install advice otherwise (L23-27). Pins `SOURCE_DATE_EPOCH=0` unless already set, so unchanged source reproduces identical PDF bytes (L32). Runs `latexmk -pdf -interaction=nonstopmode -halt-on-error -quiet` per sheet, then `latexmk -c` to clean aux files, ignoring cleanup failures (L43). PDFs are gitignored, never committed.

**`cheatsheet.sty`** (78 lines): a `ProvidesPackage{cheatsheet}[2026/09/08 ...]` layout package. Loads `fontenc T1`, `lmodern`, `geometry` (A4, 11 mm margins, 9 mm top/bottom), `multicol`, `xcolor`, `array`, `booktabs`, `enumitem`, `needspace`. Fixes `\parskip` to a non-stretchable 2 pt precisely so `multicol` cannot spread single-line sections. Defines Catppuccin Latte Mauve `cs@accent` (`#8839EF`, chosen to print as readable gray) and `cs@rule` (`#4C4F69`). Provides five macros: `\cssheettitle{title}{subtitle}`, `\cssection{heading}` (uppercase, accent-coloured, `\needspace{4\baselineskip}` so a heading is never stranded from its table), the `cskeys` environment (a two-column `tabular` with a caller-supplied key-column width and a monospaced left column), `\csrow{key}{action}`, `\csnote{...}` (small italic caveat line), `\cslegend{...}`, and `\csfoot{...}`. It carries no bindings and enforces no content.

**`tests/test-cheatsheet-bindings.sh`** (145 lines, run by `scripts/test.sh`). It is a pure `grep -Fq` fixed-string presence checker with `fail()` on the first miss.

What it **does** enforce:
1. Thirteen exact `bindsym` strings still exist in the Sway config: `$mod+Return exec ghostty`, `$mod+p exec fuzzel`, `$mod+$left focus left`, `$mod+Shift+$left move left`, `$mod+1 workspace number $ws1`, `$mod+Shift+1 move container to workspace number $ws1`, `$mod+Ctrl+$left exec sway-workspace-grid left`, `$mod+$alt+k input type:keyboard xkb_switch_layout next`, `$mod+Shift+x exec swaylock`, `$mod+Shift+r reload`, `$mod+r mode "resize"`, `Shift+Print exec sway-screenshot output`, `$mod+Shift+v exec cliphist list`.
2. Fifteen literal phrases appear in `fedora-sway.tex` (`Super+Enter`, `Open Ghostty`, `Super+P`, `Fuzzel`, `Super+H/J/K/L`, `Super+Shift+H/J/K/L`, `Super+1..9`, `Super+Shift+1..9`, `Super+Ctrl+H/J/K/L`, `Super+Alt+K`, `Switch US/Danish keyboard layout`, `Lock session`, `Reload Sway config`, `Enter resize mode`, `Save full output`, `Clipboard history`).
3. Waybar still has `"sway/language"`, `"format": "{short}"`, and the exact `on-click` layout-switch command, and the Sway sheet still mentions `sway/language` and the word `clicked`.
4. Nine exact AeroSpace assignment lines exist, and nine literal phrases appear in `macos.tex`.
5. `fedora-kde.tex` contains `Meta+Alt+K`, the string `Plasma 6's own default`, and a `not a dotfiles binding` disclaimer.
6. `fedora-wsl.tex` contains **neither** `Meta+Alt+K` nor `Super+Alt+K` (a negative assertion), and does contain `wsl-open`, `wsl-copy`, `wsl-paste`, `enabled=true`, `appendWindowsPath=false`.
7. `README.md` contains `Meta+Alt+K` somewhere.
8. `docs/keybindings.md` contains five discovery references: `ghostty +list-keybinds --default`, `WhichKey`, `Lazygit`, `<prefix> ?`, `System Settings`.
9. All four sheets plus `common-workflow.tex`, `cheatsheet.sty`, and `generate.sh` exist, and `generate.sh` is executable.

What it **does not** enforce:
- **Coverage in either direction.** It never enumerates the configs. A new `bindsym` or `ctrl-alt-*` line can be added, or a documented-but-now-unchecked one removed, with no failure. Of 31 Sway `bindsym` lines it pins 13; of 20 AeroSpace bindings it pins 9.
- **That a checked binding's key matches its documented key.** The two halves are independent existence greps. Rebinding `$mod+p` to `$mod+d` while leaving `Super+P` in the sheet fails only because the literal `bindsym $mod+p exec fuzzel` disappeared; changing `Super+Enter` in the sheet to `Super+Return` would pass the config half and fail only the phrase half by coincidence of wording. No pairing logic exists.
- **Any Neovim, tmux, Ghostty, Zsh, fzf, zoxide, Lazygit, or `theme` content.** `common-workflow.tex` is checked for existence only, never for a single row. The entire shared workflow block, the LaTeX `\l*` bindings, and all twelve table-nvim mappings are unverified.
- **KDE, Parrot, or Windows.** No `kwriteconfig6`/shortcut assertions, no Parrot sheet or shim checks, no `set-noctty-theme.ps1` cross-check for the `Ctrl+Shift+,` row.
- **Waybar's network, bluetooth, pulseaudio, and power-profile handlers**, and `floating_modifier`.
- **LaTeX validity.** Explicitly not a compile check (stated at L6-7 and in `cheatsheets/README.md:59-62`), so a sheet can be checked "accurate" and still fail `generate.sh`.
- **`keybindings.md` accuracy.** Only the five discovery strings are required; every binding table in that 206-line file is unchecked.
- **README-to-sheet consistency**, beyond `Meta+Alt+K` existing somewhere in a 4462-line file. It therefore cannot catch the `Super+Alt+K`-labelled KDE row at `README.md:3179`.
- **That the sheet set is complete.** Neither the test nor `generate.sh` knows a Parrot Security profile exists.