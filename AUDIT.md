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
| [F-06](#f-06) | high | `verify-tailscale.sh` aborts with exit 127 without `jq`, so a successful `--tailscale` install reports failure | Executed **(corrected)** |
| [F-07](#f-07) | high | macOS never sets the Zsh login shell, but its verifier hard-fails unless it is exactly `/bin/zsh`, and the README claims it does | Executed |
| [F-08](#f-08) | high | macOS installs the OCaml profile with no verification of it whatsoever | Read |
| [F-09](#f-09) | high | `docs/macos.md` documents a LaTeX workflow macOS cannot install | Read |
| [F-10](#f-10) | high | The Parrot CTF guest stows the full LazyVim and Mason config without provisioning it | Read |
| [F-11](#f-11) | high | `wsl-open` passes raw Linux paths to `explorer.exe` | Read |
| [F-12](#f-12) | high | Nothing installs a Nerd Font, but the Starship prompt is built from Nerd Font glyphs | Read |
| [F-13](#f-13) | high | `install_via_own_script` pipes `curl` into `sh`, recording a failed download as a successful install | Read |
| [F-14](#f-14) | high | Verify scripts' `mise` ownership check passes on any PATH hit | Read |
| [F-15](#f-15) | high | `common/lib/common.sh` silently forces `errexit` and `pipefail` onto 13 verify scripts that deliberately opted out | Executed **(raised)** |
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
**`verify-tailscale.sh` aborts with exit 127 when `jq` is absent, making a successful `--tailscale` install report failure**
*high, correctness. Support: executed.*

> **Corrected after publication.** The first version of this finding said the check
> degrades to a warning and the verifier exits 0. That was wrong. I analysed this file as
> though its declared `set -u` were the effective shell options, when F-15 (which I had
> already proven) means `errexit` is in force. The real outcome is worse, and the two
> findings interact. The corrected analysis and the proof are below.

**Evidence.** `platforms/fedora/scripts/verify-tailscale.sh:82`:
```bash
backend_state="$(printf '%s' "$status_json" | jq -r '.BackendState // "unknown"' 2>/dev/null)"
```
There is no `require_command jq` or `command_exists jq` guard anywhere in the file (verified
by grep). Per F-02, `jq` is not installed on Fedora unless `--sway` was selected, so
`./install.sh --tailscale` without `--sway` produces a machine where this line's `jq` does
not exist.

The file declares only `set -u` at `:2`, but sources `common/lib/common.sh` at `:6`, whose
line 3 `set -euo pipefail` then applies to everything after it (F-15). Under `errexit` and
`pipefail`, an assignment whose command substitution fails propagates that status and
terminates the script. `jq` missing means status 127. The `case` block at `:84-95` is never
reached.

**Proven by execution.** I ran the file's exact structure against a PATH with `jq` genuinely
absent, once with the library sourced and once without:

| Configuration | Result |
|---|---|
| `set -u` + `source common/lib/common.sh` (**the real code**) | dies at the assignment, **exit 127**, `case` never reached |
| `set -u` only (the semantics the file declares) | reaches the `*)` branch, warns, **exit 0** |

So the author's intent was indeed the warning path, and that is what my original analysis
described; but the shared library overrides the intent and the script hard-aborts instead.

**The downstream consequence, also verified.** `platforms/fedora/scripts/install-tailscale.sh:119-125`:
```bash
if "$DOTFILES_ROOT/platforms/fedora/scripts/verify-tailscale.sh"; then
  success "Fedora Tailscale profile installed"
else
  warn "Tailscale was installed, but validation reported problems"
  exit 1
fi
```
So `./install.sh --tailscale` on a stock Fedora installs Tailscale correctly, then reports
failure and exits 1, with a message that points at validation rather than at the missing
`jq`. Worse, that `exit 1` is *before* the heredoc at `:127` onwards which tells the user
"Tailscale is installed but not connected to a tailnet yet" and gives them the
`sudo tailscale up` command. A user following the documented profile gets a failed install
and no instructions for the step they still need to take.

This is the live manifestation of F-15: that finding is not latent, it is already costing a
user-visible failure on a documented option.

**Implementation brief.**
1. Fix the root cause by adding `jq` to the Fedora and Fedora WSL baselines per F-02.
2. Add an explicit dependency guard at the top of `verify-tailscale.sh` so this can never
   degrade again: `command_exists jq || { fail "jq is required to verify Tailscale state"; }`
   and skip the JSON section rather than proceeding into it. Note that with F-15 unfixed this
   guard is what converts a 127 abort into a reported failure, so it is worth adding even
   before F-15 lands.
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
*high, correctness. Support: executed.* (Raised from medium: F-06 is a live instance.)

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

**Why it matters. This is not latent: F-06 is a live instance of it.**

My first version of this finding called the problem latent, on the grounds that the checks
all happen to sit inside `if` or `||` guards where `errexit` does not apply, and that a live
run did produce "Verification failed: 4 failure(s), 3 warning(s)". Both observations are
true, but the conclusion was wrong. `platforms/fedora/scripts/verify-tailscale.sh:82` is a
bare assignment outside any guard, so on a machine without `jq` the imposed `errexit` kills
the script with exit 127, and `install-tailscale.sh` turns that into a failed install on a
documented option. See F-06, which I had to correct once I noticed the interaction.

So the accurate framing is: the imposed options already break one verifier today, and the
reason the rest survive is that their checks happen to be written inside guards. Every new
check added as a bare command is another instance waiting to happen, and it will present as
an unexplained abort with an exit status nobody attributes to the shared library.

There is a second-order lesson worth recording, because it applies to reading this whole
report: a finding about shell options changes the behaviour of every other finding in files
that source that library. I analysed F-06 in isolation and got it wrong despite having
already proven F-15.

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

> **Updated after the second pass.** All six of the dimensions listed below as gaps have
> since been audited; their findings are in the addendum at the end of this report, and the
> table there records which were adversarially verified and which are still single-source.
> The paragraphs below are kept as written so the record of what was and was not known at
> first publication stays intact, with a note under each saying how it was resolved. Two
> items closed differently than expected: the Neovim overlay question resolved in the
> repository's favour, and the security pass corrected F-06 against me.

**Covered but not exhaustively (at first publication):**

- **README accuracy.** The dedicated pass over 4462 lines did not complete. I verified the
  specific claims that other findings depend on, and every one I checked was wrong in the way
  the finding describes, which is itself a signal. A systematic sweep would very likely find
  more, and the mechanical high-value check I did not run is: confirm every repository path
  referenced anywhere in the README actually exists.
  *Resolved:* audited in the second pass. The path sweep was run. Five findings, verified by
  a second agent, including a high-severity one confirming that the README's generic
  Verification instructions always invoke the Fedora-only verifier, exactly the concern
  flagged for checking.
- **Neovim and Mason.** I established F-04 empirically and F-31, and Chapter B covers the
  ownership split from the package inventory. Not covered: whether the stow overlay mechanism
  (`nvim-wsl`, `nvim-macos` dropping files into `.config/nvim/lua/plugins/`) actually loads
  given `lua/config/lazy.lua`'s spec imports. That is a load-order question that deserves a
  direct answer, and if the overlays do not load, the platform-specific editor configuration
  is silently inert on two platforms.
  *Resolved, in the repository's favour:* the overlays **do** load. `lazy.lua:22` uses a
  directory import and every stow invocation passes `--no-folding`, so the mechanism is
  correct. The real defect turned out to be subtler: `init` is a scalar in lazy.nvim's
  fragment merge, so a platform overlay attaching `init` to the same `LazyVim/LazyVim` spec
  silently deletes the base theme-reload autocmd. See nvim-01.
- **Security and hardening.** I covered download trust (F-13, F-30), the hardening verify
  gap (F-20) and the absence of rollback (F-38). Not covered: a systematic review of every
  `sudo` call site for necessity and minimality; what `--containers-api-socket` actually
  exposes and whether the socket's permissions are right; whether the hardening profile
  conflicts with the containers, libvirt, Tailscale or portal profiles; and the AI profile's
  credential handling and the filesystem access the `--gnhf` and `--backpass` tools receive.
  That last item is the one I would prioritise, because the help text describes `--gnhf` as
  unattended and overnight, and the audit did not establish what it is authorised to do.
  *Resolved:* audited on Opus in the second pass, ten findings, all verified by a second
  agent. The most consequential is not the AI profile but SEC-01: the default Fedora path
  bootstraps the Terra repository with `--nogpgcheck`, the only such flag in the repository,
  establishing the trust root for `ghostty`, `mise` and `starship` from an unverified RPM,
  while `README.md:1621` asserts that DNF verifies signatures on all configured
  repositories. I verified that chain myself.
- **Windows and WSL.** F-11 and F-37 are solid. `install.ps1`'s 684 lines received a
  hygiene-level read, not a line-by-line audit: elevation handling, the WSL distro import,
  registry writes and per-step idempotency are unverified. The two-sided sequencing contract
  between `install.ps1` and the Linux installer is also unverified, and it is the kind of
  thing that is only wrong once, on a fresh machine.
  *Resolved:* audited in the second pass, four findings, including two high-severity ones: a
  mistyped `-FedoraDistribution` triggers a needless UAC elevation and WSL update before
  failing, and the Fedora-container leg of the Windows CI never actually parses or runs the
  PowerShell it greps.

**Method limitations:**

- I could not install Bash 3.2, so F-01 rests on the documented Bash 4.4 behaviour change
  plus the unguarded call sites and the CI evidence, not an observed crash.
- The container is Debian-based, not Fedora 44, so `scripts/test.sh` cannot complete here.
  Fifteen of 32 tests ran; the rest are unverified by execution, and CI is green on `main`
  as far as I could tell, so I am not claiming the suite fails in its intended environment.
- The adversarial verification stage was interrupted repeatedly by usage limits, across
  three separate runs. For the nine dimensions in the main report I substituted my own direct
  verification of the critical and high findings, which is why those carry "Executed" or an
  explicit note about what supports them. The medium and low findings marked "Read" remain
  single-source: their evidence is real and cited, but nobody challenged the reasoning or the
  fix. Treat those implementation briefs as strong proposals rather than settled conclusions.
  In the addendum, the security and README dimensions were adversarially verified; the other
  four had their verifier cut off, and I verified their highest-severity findings by hand.
- **The verification pass earned its cost, and the evidence is F-06.** A verifier caught that
  my own published analysis of `verify-tailscale.sh` was wrong: I described a silent pass
  where the real behaviour is an exit-127 abort that makes a successful install report
  failure. I had proven the cause (F-15) myself and still misread the consequence, because I
  analysed the file as though its declared `set -u` were the effective options. That is a
  strong argument for verifying findings rather than trusting a single careful pass, mine
  included.

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
---

# Addendum: the six dimensions completed in a second pass

The first audit run was interrupted by usage limits before six of its fourteen dimensions
ran. Those six were completed in a later pass. Because the interruption was a capacity limit
rather than anything about the work, the split below reflects only which agent got to run,
not any judgement about which findings matter.

**Model and verification status, stated per dimension**, because it determines how much to
trust each block:

| Dimension | Auditor | Adversarial verification | Findings |
|---|---|---|---|
| Security posture, hardening, and the AI profile | Opus | yes | 10 |
| Neovim, LazyVim and Mason | Opus | not yet (see below) | 9 |
| README accuracy and repository hygiene | Sonnet | yes | 5 |
| Cheat sheets and the macOS guide | Sonnet | not yet (see below) | 5 |
| Windows host bootstrap and WSL | Sonnet | not yet (see below) | 4 |
| Structural maintainability | Sonnet | not yet (see below) | 8 |

The four dimensions marked "not yet" had their auditor complete but their verifier cut off by
the same limit. I verified their highest-severity findings myself, noted per finding. The rest
are single-source and should be treated as strong proposals, exactly as section 13 says of the
"Read" findings in the main report.

Two findings from this pass changed the main report rather than adding to it: the security
audit's Tailscale finding corrected [F-06](#f-06) and forced [F-15](#f-15) up from medium to
high. That correction is recorded in place.


## Security posture, hardening, and the AI profile

### SEC-01: Terra repository trust root is bootstrapped with --nogpgcheck on the default Fedora path, contradicting the README's package-integrity claim
*high, security. verified by a second agent.*

**Locations.** `platforms/fedora/lib/fedora.sh:28`, `platforms/fedora/lib/fedora.sh:46`, `platforms/fedora/scripts/install-terra.sh:11`, `platforms/fedora/install.sh:734`, `README.md:1621`

**Evidence.** platforms/fedora/lib/fedora.sh:21-32, ensure_terra_repository: `sudo dnf install -y --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release`. This is the only --nogpgcheck in the repository, and it is not optional: platforms/fedora/install.sh:733-734 runs install-terra.sh unconditionally on every Fedora install, and install-terra.sh:13-17 then installs ghostty, mise and starship from Terra - three packages that execute in every login shell. The terra-release RPM is what installs Terra's repo definition and its signing key, so the entire trust root for those packages is established from an RPM whose signature is explicitly not checked; the only protection is TLS to repos.fyralabs.com. Nothing afterwards asserts that the installed /etc/yum.repos.d/terra*.repo actually carries gpgcheck=1 / repo_gpgcheck=1. ensure_rpm_fusion_repositories (lines 46-48) has the same shape without the explicit flag: `sudo dnf install -y "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_version}.noarch.rpm" ...` relies on dnf's default of not gpg-checking a local/remote package file. Meanwhile README.md:1621 states, in the hardening profile's own baseline table, "Package integrity | DNF verifies GPG signatures on all configured repositories | Not touched", and README.md:2705-2714 ("Terra RPM repository") says nothing about how Terra's key is trusted. The documented promise and the code disagree.

**Problem.** The default Fedora install path disables signature verification for the package that becomes the trust anchor for three shell-critical tools, and the README asserts the opposite. There is also no post-install verification that Terra's repo file has gpgcheck enabled, so a future upstream change to that repo file (or a repo file substituted in transit) would silently leave all later Terra installs unverified. A user reading the hardening section would reasonably believe every configured repo is signature-checked; it is not.

**Fix.** In platforms/fedora/lib/fedora.sh, replace the --nogpgcheck bootstrap in ensure_terra_repository with a fingerprint-pinned key import: (1) add a constant TERRA_GPG_KEY_URL (https://repos.fyralabs.com/terra$releasever/key.asc or whatever Fyra Labs currently publishes) and TERRA_GPG_KEY_FINGERPRINT with the full 40-hex fingerprint recorded in the source; (2) fetch the key with `curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 --output "$tmp"` (matching the pattern already used at platforms/macos/scripts/install-system.sh:34-36); (3) compare `gpg --show-keys --with-colons --fingerprint "$tmp"` against the pinned fingerprint and die on mismatch; (4) `sudo rpm --import "$tmp"`; (5) then run the same dnf command WITHOUT --nogpgcheck. Add a verify step to platforms/fedora/scripts/verify.sh next to its existing SELinux/firewalld checks that fails when any file matching /etc/yum.repos.d/terra*.repo lacks `gpgcheck=1`, and note the pinned fingerprint plus the rotation procedure in README.md's "Terra RPM repository" section (README.md:2705). Keep the --disablerepo="copr:copr.fedorainfracloud.org:jdxcode:mise" behavior in install-terra.sh:28-30 unchanged. If pinning is judged not worth the key-rotation maintenance, then the honest alternative is to correct README.md:1621 and add an explicit "Terra's key is trusted on first use over TLS" row to the baseline table - but do not leave the current claim standing.

**Acceptance.** Add a case to tests/test-mocked-installs.sh (or a new tests/test-terra-repo.sh registered in scripts/test.sh) that mocks dnf/rpm/curl/gpg and asserts: (a) the recorded dnf command line for terra-release contains no `--nogpgcheck`; (b) a mocked gpg reporting a fingerprint other than the pinned one makes ensure_terra_repository exit non-zero without invoking dnf; (c) `rpm --import` is invoked before the dnf install. Add a verify assertion that a terra repo file written with `gpgcheck=0` makes verify.sh exit 1.

**Verifier note.** Verified platforms/fedora/lib/fedora.sh:22-32 (ensure_terra_repository) runs `sudo dnf install -y --nogpgcheck --repofrompath ... terra-release` verbatim, and it is the ONLY --nogpgcheck in the repo (grep -rn nogpgcheck returns just this one hit). platforms/fedora/install.sh calls install-terra.sh unconditionally right after install-system.sh, with no --skip flag gating it, and install-terra.sh installs ghostty/mise/starship from Terra. README.md:1621 does state the unqualified 'DNF verifies GPG signatures on all configured repositories | Not touched' claim in the hardening baseline table, and the Terra section (README.md:2705 area) says nothing about the bootstrap being unverified. The trust-root gap is real and the documentation contradiction is real. ensure_rpm_fusion_repositories (line 46-48) also has no --nogpgcheck flag but relies on dnf's default local/remote-RPM behavior as described.

### SEC-02: verify-tailscale.sh aborts with exit 127 on any Fedora machine without jq, so --tailscale ends in a spurious failure
*high, correctness. verified by a second agent.*

**Locations.** `platforms/fedora/scripts/verify-tailscale.sh:82`, `platforms/fedora/scripts/install-tailscale.sh:120`, `.github/workflows/validate.yml:36`, `platforms/fedora/scripts/install-sway.sh:17`

**Evidence.** platforms/fedora/scripts/verify-tailscale.sh:82: `backend_state="$(printf '%s' "$status_json" | jq -r '.BackendState // "unknown"' 2>/dev/null)"`. jq is required and unguarded: install-tailscale.sh never calls `require_command jq`, and jq is not in the Fedora or Fedora-WSL baseline package list - on Fedora it appears only in platforms/fedora/scripts/install-sway.sh:17. verify-tailscale.sh declares only `set -u` (line 2) but sources common/lib/common.sh (line 6), whose line 3 `set -euo pipefail` then applies to everything after it. With jq absent the command substitution exits 127, the assignment inherits that status, and errexit kills the script mid-run. Reproduced: a script with `set -euo pipefail` and an assignment from a pipeline ending in a missing command exits 127 with no further output. The line 81 `if status_json="$(...)"` is exempt as an if-condition, so execution really does reach line 82. Consequence: install-tailscale.sh:120-125 sees a non-zero verify, prints "Tailscale was installed, but validation reported problems" and exits 1, on an install that actually succeeded - and the user never sees the summary or any explanation. CI does not catch it because .github/workflows/validate.yml:36 explicitly installs jq into the fedora:44 container, and tests/test-tailscale.sh mocks dnf/rpm/sudo/systemctl/tailscale but not jq.

**Problem.** A documented optional profile (README.md:2705+, "Optional Tailscale networking profile") reports failure on a correct install on the stock package set, with no diagnostic. The same latent dependency exists for anyone running ./scripts/verify-tailscale.sh standalone. The errexit leak turns a missing-optional-tool condition into an unexplained hard abort rather than the intended warning path at lines 92-94.

**Fix.** Two changes. (1) In platforms/fedora/scripts/verify-tailscale.sh, stop requiring jq for what is a single field read: replace lines 81-98 so the BackendState is extracted without jq, e.g. `status_output="$(tailscale status 2>/dev/null || true)"` plus `tailscale status --json` parsed with a guarded fallback - concretely, wrap the jq call as `if command_exists jq; then backend_state="$(... | jq -r ... || true)"; else backend_state="$(printf '%s' "$status_json" | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"; fi`, and always append `|| true` so no assignment can trip errexit. (2) Apply the same guard to platforms/macos/scripts/verify.sh:235, which has the identical line (macOS is currently safe only because platforms/macos/Brewfile:13 lists jq). Do not fix this by adding jq to the Fedora baseline: jq is not otherwise needed there and that would contradict the profile-scoped package ownership documented in README.md. Update README.md's Tailscale section only if you choose the require_command route instead.

**Acceptance.** In tests/test-tailscale.sh, add a scenario that runs verify-tailscale.sh with a PATH containing the existing mocks but with jq shadowed by a non-existent command (e.g. `PATH="$mock_bin"` only, and assert `! command -v jq`), and assert that (a) the script exits 0, (b) its output contains "Tailscale verification passed", and (c) it contains the NeedsLogin/Running branch text rather than "unrecognized BackendState". Mirror the assertion in tests/test-macos.sh for platforms/macos/scripts/verify.sh.

**Verifier note.** Verified platforms/fedora/scripts/verify-tailscale.sh:2 has only `set -u`, then sources common/lib/common.sh:3 which sets `set -euo pipefail` for the remainder of the sourcing script's execution. Line 82's `backend_state="$(... | jq -r ...)"` is a plain assignment (not an if-condition), so with jq absent (exit 127) and pipefail active, errexit kills the script. Confirmed jq is not in the Fedora baseline and appears only via install-sway.sh:17. Confirmed CI (.github/workflows/validate.yml:36) explicitly installs jq into the fedora:44 container, and tests/test-tailscale.sh:101 prepends its own mock bin to the *real* PATH (not an isolated one), so if the test runner's real PATH has jq (as it does in CI), the missing-jq path is never exercised. Confirmed macOS has the identical line at platforms/macos/scripts/verify.sh:235 but is safe because Brewfile:13 lists jq. This is a real, reachable defect.

### SEC-03: The AI profile's curl-pipe-sh installer discards curl's exit status, so a failed download is recorded as a successful install
*high, security. verified by a second agent.*

**Locations.** `common/install-ai.sh:313`, `common/install-ai.sh:319`, `common/install-ai.sh:341`, `common/install-ai.sh:344`, `tests/test-ai-profile.sh:72`

**Evidence.** common/install-ai.sh:307-320, install_via_own_script, is the profile's only remote-code-execution path:
```
PATH="$(dirname "$target"):$PATH" \
  sh -c "curl --fail --show-error --silent --location '$script_url' | sh"
```
The inner `sh -c` is a fresh POSIX shell with no pipefail, so the pipeline's status is the trailing `sh`, which exits 0 on empty stdin. Reproduced against a failing URL: curl printed `curl: (22) The requested URL returned error: 502` and the function still returned success. Callers at lines 341 and 344 therefore set `treehouse_state="installed"` and `no_mistakes_state="installed"`, which are written verbatim into $XDG_CONFIG_HOME/dotfiles/ai.conf at lines 361-362. Two remote scripts run this way: `${TREEHOUSE_INSTALL_SCRIPT_URL:-https://kunchenguid.github.io/treehouse/install.sh}` (line 18) and `${NO_MISTAKES_INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh}` (line 20) - both floating, unpinned, no checksum, and unlike the rest of the repo without `--proto '=https' --tlsv1.2`. The repository already has the safer pattern in two places: platforms/macos/scripts/install-system.sh:34-36 and platforms/parrot-ctf/scripts/install-system.sh:72-74 both do `curl --fail --location --proto '=https' --tlsv1.2 ... --output "$installer"` and then run the saved file, so curl's failure is a hard error. The URL is also interpolated into a `sh -c` string in single quotes, which is fragile for an env-overridable value. The comment at lines 307-312 asserts this "guarantee[s] a user-owned install with no unexpected privilege escalation" purely by prepending ~/.local/bin to PATH - a claim about the remote script's internals that this repository cannot enforce or detect. tests/test-ai-profile.sh:72-91 mocks curl with a script that always exits 0, so the failure path is untested.

**Problem.** A network or upstream failure is reported as a successful component install and persisted to the profile state file. verify-ai.sh:289-311 does catch the missing binary afterwards, so the run exits 1 - but with the message "AI tooling installed, but validation reported problems" rather than the real cause, and with ai.conf now containing `treehouse=installed` for a tool that does not exist. Combined with no checksum, no pin, and no `--proto '=https'`, this is the weakest download-trust path in the repo and it is inconsistent with the repo's own established pattern two platforms over.

**Fix.** Rewrite common/install-ai.sh's install_via_own_script to the pattern already used elsewhere in the repo: `script="$(mktemp)"; trap 'rm -f -- "$script"' RETURN; curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 "$script_url" --output "$script" || die "Failed to download the $name installer: $script_url"; [[ -s "$script" ]] || die "Downloaded an empty $name installer: $script_url"; PATH="$(dirname "$target"):$PATH" sh "$script"` - note the URL is now a normal argument, not interpolated into a shell string. Then make the caller state honest: after each install_via_own_script call at lines 341-345, assert `[[ -x "$target" ]] || die "..."` before setting treehouse_state/no_mistakes_state to "installed". Soften the comment at lines 307-312 so it states what is actually enforced (PATH prepend so the vendor script prefers a user-owned prefix) and what is not (the repo cannot prove where a third-party script writes); README.md's FirstMate table (README.md:2334-2338, "own install script, to ~/.local/bin/treehouse") should gain one sentence saying these two tools are the only unpinned, unchecksummed downloads in the profile.

**Acceptance.** In tests/test-ai-profile.sh, extend the mock curl (line 72) so a URL containing a sentinel token makes it print nothing and `exit 22`, then add a scenario running `install-ai.sh --firstmate` with TREEHOUSE_INSTALL_SCRIPT_URL pointing at that token, asserting: (a) install-ai.sh exits non-zero, (b) its log contains "Failed to download the Treehouse installer", and (c) $XDG_CONFIG_HOME/dotfiles/ai.conf does NOT contain `treehouse=installed`.

**Verifier note.** Verified common/install-ai.sh's install_via_own_script (~line 313-320) runs `sh -c "curl ... '$script_url' | sh"`. The inner `sh -c` is a separate shell process that does not inherit the outer script's pipefail, so if curl fails, the inner sh receives empty stdin and exits 0, making the whole construct report success regardless of curl's exit status. Confirmed the caller unconditionally sets treehouse_state="installed"/no_mistakes_state="installed" immediately after the call with no existence/exit-status check. Confirmed via grep that this curl|sh pattern is unique to install-ai.sh -- macOS (install-system.sh:34-36) and Parrot (install-system.sh:72-74) both download to a file first with --proto '=https' --tlsv1.2 and check curl's exit status before executing. Confirmed tests/test-ai-profile.sh's mock curl (~line 72-91) has no failure branch and always exits 0 implicitly, so the failure path is genuinely untested.

### SEC-04: Agent instruction symlinks point into the tracked repo, and verify-ai.sh cannot tell a later clobber from a user's own pre-existing file
*medium, security. partially confirmed, reduced.*

**Locations.** `common/install-ai.sh:298`, `common/install-ai.sh:302`, `common/verify-ai.sh:129`, `common/verify-ai.sh:29`, `common/assets/AGENTS.md:17`, `README.md:2272`

**Evidence.** common/install-ai.sh:22-26 and 302-305 link three global agent-instruction paths at `$DOTFILES_ROOT/common/assets/AGENTS.md` with `ln -s "$agents_source" "$target"` (line 298): `$HOME/.claude/CLAUDE.md`, `${CODEX_HOME:-$HOME/.codex}/AGENTS.md`, and `$XDG_CONFIG_HOME/opencode/AGENTS.md`. Those three paths are per-tool correct, and pre-existing content is never clobbered: lines 284-296 warn and return for an existing symlink pointing elsewhere or any existing file. The target is a git-tracked file in the dotfiles working tree, and two installed things are expected to write to it: common/assets/AGENTS.md:17-22 has a "## Maintaining this file" section instructing agents to "Prefer rewriting or pruning existing entries", and `--backpass` installs a tool whose documented sole write action is editing exactly these files (README.md:2442-2449: "proposes evidence-backed edits to your AGENTS.md/CLAUDE.md" and "backpass apply is the only command that writes anything"). Neither README.md:2260-2286 ("Shared agent instructions: AGENTS.md") nor the backpass section mentions that a write through ~/.claude/CLAUDE.md lands in the tracked repository. Separately, verify-ai.sh cannot detect the failure mode where a tool replaces the symlink with a regular file (a rename-over-write): check_symlink_owned uses `warning` for a plain file (line 130) and for a symlink pointing elsewhere (line 137), and `warning()` at lines 29-31 only prints - it never increments `failures`, which is the only thing the summary at lines 325-329 checks. tests/test-ai-profile.sh:361-372 pins this behavior by asserting verify-ai.sh SUCCEEDS while reporting "is a plain file".

**Problem.** verify-ai.sh cannot distinguish a symlink target that was a user's pre-existing file at install time (intentionally left alone, correctly a warning) from one that was successfully linked by this profile and later replaced by something else (e.g. a tool doing an atomic rename-over-write) -- both look identical to check_symlink_owned and both only produce a non-failing warning, so the 'one edit updates every harness' guarantee can silently break with verify-ai.sh still exiting 0 and printing 'AI profile verification passed.' The claim that the symlink-into-the-tracked-repo relationship itself is undocumented is not accurate -- README.md's 'Shared agent instructions: AGENTS.md' section already states it plainly.

**Fix.** Have link_agent_instructions record a per-target linked/kept-existing state into ai.conf, and have check_symlink_owned read that state to decide whether a plain-file/wrong-symlink target should be `fail` (was linked, now drifted) or the current `warning` (was kept-existing by design) -- as originally proposed. Drop the README documentation-gap portion of the fix; the existing section already covers it adequately.

**Acceptance.** In tests/test-ai-profile.sh: (1) after the core install, replace $HOME/.claude/CLAUDE.md with a plain file (`rm` then `printf ... >`) and assert verify-ai.sh now exits non-zero and prints a failure naming that path; (2) keep the existing pre-existing-file scenario (lines 330-372) passing, and additionally assert `$XDG_CONFIG_HOME/dotfiles/ai.conf` contains `claude_md=kept-existing` there and `claude_md=linked` in the clean-home scenario. Add a tests/test-ai-profile.sh assertion that all three keys are present in ai.conf.

**Verifier note.** Evidence checks out mechanically: link_agent_instructions links three global paths to $DOTFILES_ROOT/common/assets/AGENTS.md (a tracked file) and never overwrites a pre-existing file/symlink (common/install-ai.sh ~284-300). check_symlink_owned in verify-ai.sh (~120-139) does use `warning` (not `fail`) both for 'plain file' and 'symlink pointing elsewhere', and warning() never increments `failures`, so verify-ai.sh exits 0 in both cases; tests/test-ai-profile.sh:361-372 pins exactly this ('is a plain file' + exit 0). However, part (1) of the 'problem' is overstated: README.md's own 'Shared agent instructions' section (starting ~line 2260, not far from the cited 2272) already explicitly documents these three paths as symlinks into common/assets/AGENTS.md and tells the user to 'Edit common/assets/AGENTS.md in this repository to change it for every harness at once' -- so the fact that an edit through ~/.claude/CLAUDE.md lands in the tracked repo is a directly stated consequence, not a hidden one, even though the exact phrase 'this will show up as a dirty working tree' isn't spelled out. The real, sharper defect is part (2): verify-ai.sh has no way to distinguish a user's legitimate pre-existing file (which correctly should stay a warning) from post-install drift where a tool clobbered the symlink after a successful link -- both currently produce identical 'warning, exit 0' output. That gap, and its fix (recording linked/kept-existing state and escalating only the drift case to `fail`), is the part worth keeping.

### SEC-05: install-hardening.sh prints success when the account-lockout, sudo-audit and auditd controls it claims to apply were not applied
*medium, correctness. partially confirmed, reduced.*

**Locations.** `platforms/fedora/scripts/install-hardening.sh:186`, `platforms/fedora/scripts/verify-hardening.sh:120`, `platforms/fedora/scripts/verify-hardening.sh:132`, `platforms/fedora/scripts/verify-hardening.sh:150`, `platforms/fedora/scripts/verify-hardening.sh:313`, `platforms/fedora/lib/hardening.sh:105`

**Evidence.** platforms/fedora/lib/hardening.sh:105-124, apply_pam_faillock, returns 1 (without writing its drop-in, which is at lines 126-131 after the enable branch) when authselect is missing, has no active profile, or refuses `sudo authselect enable-feature with-faillock` because of local PAM modifications. install-hardening.sh:144-147 records that as `state_faillock="false"` in $XDG_CONFIG_HOME/dotfiles/hardening.conf (line 175) and then keeps going. verify-hardening.sh then reports the same three security controls as warnings, not failures: line 113 `warning "authselect does not report with-faillock enabled"`, line 120 `warning "faillock policy drop-in missing"`, line 132 `warning "sudo logfile drop-in missing"`, line 150 `warning "auditd is not active"`. The summary at lines 307-318 exits 1 only when `failures > 0`; with warnings it prints "Hardening verification passed with warnings" and exits 0. install-hardening.sh:186-190 therefore reaches `success "Fedora hardening profile installed"`. tests/test-hardening.sh:362-377 asserts only the SELinux, firewalld, sysctl and sshd lines, so nothing pins the severity of these three.

**Problem.** install-hardening.sh can print 'Fedora hardening profile installed' when pam_faillock account-lockout was not actually enabled (apply_pam_faillock failed and returned 1), because verify-hardening.sh only ever demotes an unenabled/missing faillock policy to a warning, which does not fail the overall verification. The sudo-audit-log and auditd drop-ins are written unconditionally with a die-on-failure guard, so they are much less likely to be silently skipped during a fresh install; the warning-vs-fail asymmetry for those two is still a real inconsistency worth tightening for the standalone re-verification case, but is not demonstrated to produce the same false-success-on-install outcome that pam_faillock does.

**Fix.** Two coordinated changes. (1) In platforms/fedora/scripts/install-hardening.sh, after the verify call at line 186, stop treating a warning-only verify as unqualified success: gate the `success` at line 187 on the recorded state, e.g. `if [[ "$state_faillock" != "true" ]]; then warn "Hardening installed, but pam_faillock was not enabled (see 'authselect current'); rerun after resolving it"; fi` and exit non-zero when any control the installer intended to apply is not recorded as applied. (2) In platforms/fedora/scripts/verify-hardening.sh, escalate the three checks from `warning` to `fail` when a prior install is on record - read `$XDG_CONFIG_HOME/dotfiles/hardening.conf` near the top (next to the existing sources at lines 4-10) into a `hardening_installed` flag and a `state_faillock` value, then: line 117-121 and line 110-114 use `fail` when state_faillock=true; line 129-133 uses `fail` when hardening_installed; line 141-151 uses `fail` for an inactive auditd when hardening_installed. Keep them as warnings when no state file exists, so the documented "re-run verification any time" use on a never-hardened machine stays informational (README.md:1603-1605). Update README.md's rollback/verify table rows for faillock, the sudo logfile and auditd to say the check is a hard failure once the profile is installed.

**Acceptance.** In tests/test-hardening.sh, add a third scenario whose authselect mock exits non-zero for `enable-feature with-faillock` and assert: (a) install-hardening.sh exits non-zero, (b) its output does not contain "Fedora hardening profile installed", (c) hardening.conf contains `faillock=false`. Add a fourth scenario that deletes $fake_root/etc/sudoers.d/90-dotfiles-hardening after install and asserts verify-hardening.sh exits 1 with "sudo logfile drop-in missing".

**Verifier note.** The pam_faillock claim is fully confirmed: apply_pam_faillock (platforms/fedora/lib/hardening.sh:105-124) returns 1 without writing its drop-in when authselect enable-feature fails; install-hardening.sh:145-146 leaves state_faillock="false" in that case and does NOT die (it's an if-condition); verify-hardening.sh:110/117 only 'warning's an unenabled/missing faillock policy; the summary (~line 307) exits 0 on warnings-only; install-hardening.sh:186-188 then prints 'Fedora hardening profile installed' -- a real false-success path. However, the finding overstates the sudo-audit-log and auditd portions: apply_sudo_audit_log (lines 134-148) writes its drop-in unconditionally and `die`s the whole script (install-hardening.sh has `set -euo pipefail`) on a visudo syntax failure, so it cannot silently skip the drop-in and still reach the success line the way faillock can. apply_auditd_rules similarly calls `sudo systemctl enable --now auditd.service` directly inside an if-body (not a condition), so a failure there also trips errexit and aborts the whole script before reaching 'success'. So 'three of seven changes... may not be in place' while still printing success is only demonstrably true for pam_faillock; sudo_logfile/auditd would need a narrower failure mode (e.g. the unit enabling successfully but the daemon later going inactive) to reach the same false-success outcome, which the finding doesn't establish. The SELinux/firewalld-vs-faillock/sudo-logfile/auditd severity asymmetry (fail vs warning) is real and confirmed as described.

### SEC-06: verify-containers.sh passes whether or not the API socket is enabled and never checks the socket's owner or permission bits
*medium, testing. verified by a second agent.*

**Locations.** `platforms/fedora/scripts/verify-containers.sh:110`, `platforms/fedora/scripts/verify-containers.sh:116`, `platforms/fedora/scripts/install-containers.sh:160`, `README.md:1945`

**Evidence.** platforms/fedora/scripts/verify-containers.sh:108-117 is the whole API-socket check:
```
if systemctl --user is-enabled --quiet podman.socket 2>/dev/null; then
  pass "podman.socket is enabled (socket-activated, user-scoped)"
  if systemctl --user is-active --quiet podman.socket 2>/dev/null; then
    pass "podman.socket is active"
  fi
else
  pass "podman.socket is not enabled (default; enable with --api-socket if needed)"
fi
```
Both branches call `pass`, so the check can never contribute a failure. It never reads the `api_socket=` line that install-containers.sh:160 writes into $XDG_CONFIG_HOME/dotfiles/containers.conf, so it cannot notice that a socket the user opted into is no longer enabled. Confirmed as the audit suspected: there is no `stat` of `$XDG_RUNTIME_DIR/podman/podman.sock` anywhere in the file - no owner check and no mode check - even though README.md:1945-1950 makes exactly that the user's responsibility: "anything that can write to that socket path can control every container your rootless user can - equivalent to shell access as that user ... Do not add other local users to your primary group or otherwise widen access to $XDG_RUNTIME_DIR if you enable this." tests/test-containers.sh:365-390 asserts only that install writes `api_socket=enabled` and that verify prints "podman.socket is enabled".

**Problem.** The one check that covers the profile's only opt-in privilege expansion is unfalsifiable, and the documented security caveat has no mechanical counterpart. A machine where the socket was enabled and then disabled (or never successfully enabled on a rerun) still reports "Containers verification passed" while containers.conf claims api_socket=enabled. And the README tells the user the socket's access is the whole security boundary, while the verifier that exists specifically to check "the API socket's state" (README.md:1996) never looks at the socket's permissions. Note this is a verification gap only: the socket exposure itself is off by default and its tradeoff is documented thoroughly and accurately.

**Fix.** In platforms/fedora/scripts/verify-containers.sh, read the recorded state before the section: `containers_conf="$XDG_CONFIG_HOME/dotfiles/containers.conf"` and `recorded_api_socket="$(awk -F= '$1 == "api_socket" { print $2 }' "$containers_conf" 2>/dev/null || true)"`. Then replace lines 108-117 with three cases: recorded `enabled` and unit enabled -> pass; recorded `enabled` and unit not enabled -> `fail "containers.conf records api_socket=enabled but podman.socket is not enabled"`; recorded `disabled`/absent -> keep the current informational pass, but if the unit IS enabled emit `warning` about the drift. When the unit is active, add a permission check next to it, guarded so it never trips errexit: `socket_path="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"`; if it exists, `stat -c '%U %a' "$socket_path"` and `fail` unless the owner is `$(id -un)` and the mode has no group/other bits (reuse the octal-mask idiom already in platforms/fedora/scripts/verify-hardening.sh:277, `((8#$mode & 8#077))`). Add the new check to the list in README.md:1994-1998 and to the API-socket section at README.md:1926 so the documented warning and the verifier agree.

**Acceptance.** In tests/test-containers.sh, extend the existing --api-socket scenario (line 365) to: (a) remove `podman.socket` from $test_root/user-enabled-units after install and assert verify-containers.sh --skip-smoke-test now exits 1 with "records api_socket=enabled"; (b) create a fake socket file at $XDG_RUNTIME_DIR/podman/podman.sock with mode 0666 and assert verify fails naming the mode; (c) with mode 0600 and the correct owner, assert verify passes.

**Verifier note.** Verified platforms/fedora/scripts/verify-containers.sh:108-117 (the API-socket section) matches the quoted code exactly -- both the enabled and not-enabled branches call `pass`, so the check can never fail. Confirmed it never reads the `api_socket=` line install-containers.sh:160 writes to containers.conf, and there is no stat/owner/mode check of $XDG_RUNTIME_DIR/podman/podman.sock anywhere in the file. Confirmed README.md:1945-1950 documents the socket's security implication in exactly the terms quoted. This is a real, narrow verification gap, honestly scoped by the finding itself as 'a verification gap only.'

### SEC-07: The VM-host profile adds the user to the libvirt group while the README promises it "never grants broad administrator permissions"
*medium, documentation. verified by a second agent.*

**Locations.** `platforms/fedora/scripts/install-vm-host.sh:147`, `README.md:1383`, `platforms/fedora/scripts/install-vm-host.sh:104`

**Evidence.** platforms/fedora/scripts/install-vm-host.sh:144-154:
```
if getent group libvirt >/dev/null 2>&1; then
  if ! id -nG "$target_user" | tr ' ' '\n' | grep -Fxq libvirt; then
    info "Adding $target_user to the standard libvirt group"
    sudo usermod -aG libvirt "$target_user"
```
README.md:1381-1384 describes this as: "Normal users use Fedora's upstream libvirt/polkit policy and, where Fedora provides it, the standard `libvirt` group. The installer never makes the libvirt socket world-writable and never grants broad administrator permissions." The dry-run plan says the same thing more briefly (install-vm-host.sh:104: "Host access: standard Fedora libvirt/polkit policy and libvirt group"). On Fedora, membership of the `libvirt` group is what grants unauthenticated read-write access to the `qemu:///system` daemon - which is why line 148 warns "Log out and back in before using qemu:///system". Read-write access to the system libvirt daemon lets a member define a domain that attaches a raw host block device or a host filesystem passthrough and boots it, i.e. read and write arbitrary host files with root's privileges. The profile records `user=$target_user` in vm-host.conf (line 199) but the group addition itself has no rollback note anywhere in README.md's VM-host section, and `grep -n "libvirt group\|wheel\|polkit" README.md` returns only line 1381 and one unrelated sway line.

**Problem.** The change itself is the standard, necessary Fedora path for this feature and is not a defect. The documentation is: "never grants broad administrator permissions" is the one sentence a reader would rely on to conclude that this optional profile does not hand the account a root-equivalent capability, and it does. Nothing tells the user what the group buys, that it is a persistent grant surviving profile removal, or how to undo it - and unlike every other privileged change in this repo (the hardening drop-ins each have a Rollback column at README.md:1628+), this one has no documented reversal.

**Fix.** Correct the documentation and give the grant a rollback. In README.md, replace the sentence at line 1383 with an accurate statement: the profile adds the invoking user to Fedora's `libvirt` group, which grants read-write access to `qemu:///system`; because a domain definition can attach raw host devices, that access is effectively equivalent to root on this host, so it should only be granted on a machine where the user already has sudo. Add a rollback line: `sudo gpasswd -d "$USER" libvirt` (then log out and back in), and note that Fedora's polkit rules also allow one-off authenticated access without group membership for users who prefer to be prompted. Mirror the wording into the dry-run plan text at install-vm-host.sh:104 and into the `usage()` block at lines 47-49, and add one line to docs/cheatsheets/fedora-kde.tex only if that sheet already covers the VM-host profile. Leave the code at lines 144-154 unchanged - the guard, the message and the log-out warning are correct.

**Acceptance.** In tests/test-vm-host.sh, add an assertion that the README section contains both the corrected privilege statement and the `gpasswd -d` rollback command (the repo already uses this style of documentation assertion in tests/test-sftp-baseline.sh:71-79), and assert the install-vm-host.sh --dry-run output mentions the libvirt group's privilege implication.

**Verifier note.** Verified platforms/fedora/scripts/install-vm-host.sh:144-154 adds the user to the `libvirt` group via `sudo usermod -aG libvirt` with a log-out warning, exactly as quoted. Verified README.md:1381-1384 states 'Normal users use Fedora's upstream libvirt/polkit policy and, where Fedora provides it, the standard libvirt group. The installer never makes the libvirt socket world-writable and never grants broad administrator permissions.' Membership in the libvirt group granting effectively root-equivalent access via qemu:///system domain XML (raw device/filesystem passthrough) is an accurate, well-documented characteristic of libvirt's system-mode socket policy on Fedora, so the README's 'never grants broad administrator permissions' sentence is materially misleading for this specific optional profile. Confirmed via grep that README.md has no `gpasswd`/rollback text anywhere and the hardening section's Rollback column pattern (README.md:1628) is not mirrored for this group grant.

### SEC-08: apply_dnf_automatic_notify enables the update timer without reading apply_updates, and asserts "installs nothing automatically" while doing so
*low, correctness. verified by a second agent.*

**Locations.** `platforms/fedora/lib/hardening.sh:257`, `platforms/fedora/lib/hardening.sh:260`, `platforms/fedora/scripts/verify-hardening.sh:216`, `platforms/fedora/scripts/install-hardening.sh:182`

**Evidence.** platforms/fedora/lib/hardening.sh:251-263 checks only whether the timer unit is enabled: `if systemctl is-enabled --quiet dnf5-automatic.timer` ... `else info "Enabling dnf5-automatic.timer (downloads and reports updates; apply_updates=no by default installs nothing automatically)"; sudo systemctl enable --now dnf5-automatic.timer`. It never inspects /etc/dnf/automatic.conf. The comment at lines 244-250 and README.md's table row both rest entirely on the packaged default. On a machine where the user had set `apply_updates = yes` but left the timer disabled, this unattended step turns on automatic installation of updates while printing that it will not, and install-hardening.sh:182 then records `dnf_automatic=notifyonly`. verify-hardening.sh:213-220 sees the discrepancy and only downgrades it to a `note`: "apply_updates=yes in $automatic_conf (this system auto-installs updates, not this profile's default)" - notes contribute to neither failures nor warnings. README.md's dnf5-automatic row correctly documents the other direction ("If the timer is already enabled ... it's left alone rather than reconfigured") but not this one.

**Problem.** A hardening profile whose stated update policy is "report and download, never auto-install" (lib/hardening.sh:248-250) can, in one specific pre-existing configuration, switch a workstation to unattended package installation and reboots-adjacent behaviour, tell the user the opposite in its own log line, and record a state value that is false. The verifier that would catch it treats the mismatch as neutral prose.

**Fix.** In platforms/fedora/lib/hardening.sh, read the effective config before enabling. Add a small helper `dnf_automatic_apply_updates()` that resolves the first existing candidate of /etc/dnf/automatic.conf and /etc/dnf/dnf5-plugins/automatic.conf (the same candidate list verify-hardening.sh:206 already uses, so factor it into the shared lib and have the verifier call it) and prints the last `apply_updates` value or empty. In apply_dnf_automatic_notify, when the timer is not enabled and that value is `yes`, do not enable the timer: `warn` that the machine is configured to auto-install updates, which this profile's notify-only policy will not turn on, and return 1 so install-hardening.sh:166-168 records `dnf_automatic=skipped` rather than `notifyonly`. Otherwise enable as today. In verify-hardening.sh, change the `apply_updates == yes` branch (line 216) from `note` to `warning`. Add a sentence to README.md's dnf5-automatic table row covering the "apply_updates=yes with the timer disabled" case.

**Acceptance.** In tests/test-hardening.sh, seed $fake_root/etc/dnf/automatic.conf with `apply_updates = yes` in a new scenario and assert: (a) the command log contains no `systemctl enable --now dnf5-automatic.timer`, (b) the state file contains `dnf_automatic=skipped`, (c) verify-hardening.sh output contains the warning marker for the apply_updates line.

**Verifier note.** Verified apply_dnf_automatic_notify (platforms/fedora/lib/hardening.sh:251-263) only checks `systemctl is-enabled dnf5-automatic.timer` before enabling it -- it never reads /etc/dnf/automatic.conf's apply_updates value, so a machine with apply_updates=yes already set but the timer disabled gets the timer turned on by this 'notify-only' hardening step, while its own info log claims 'installs nothing automatically.' Verified verify-hardening.sh:213-220 downgrades exactly this mismatch to a `note` (not `warning` or `fail`), which contributes to neither the failures nor warnings counters used by the summary. This is a real, if narrow, correctness/security-relevant gap.

### SEC-09: /etc/wsl.conf is replaced wholesale with no backup, the only vendor /etc file this repo rewrites
*low, security. partially confirmed, reduced.*

**Locations.** `platforms/fedora-wsl/scripts/configure-interop.sh:115`, `platforms/fedora-wsl/scripts/configure-interop.sh:112`, `platforms/fedora/lib/hardening.sh:3`

**Evidence.** platforms/fedora-wsl/scripts/configure-interop.sh:111-115:
```
temp_file="$(mktemp)"
trap 'rm -f -- "$temp_file"' EXIT
printf '%s\n' "$new_content" >"$temp_file"
sudo install -m 0644 "$temp_file" "$wsl_conf_file"
```
$new_content is the entire file regenerated by render_ini_section_keys (platforms/fedora-wsl/lib/wsl.sh:70+), so the write replaces every byte of /etc/wsl.conf - including a user's `[boot] systemd=true`, `[network]`, `[user]` and `[automount]` sections - and no copy of the previous content is kept. Every other privileged write in the repo is a dotfiles-owned drop-in: platforms/fedora/lib/hardening.sh:3-6 states the policy explicitly, "only ever touches a single dotfiles-owned drop-in file per subsystem, never a vendor config file, so unrelated user configuration is never overwritten". The renderer is a pure function with unit coverage in tests/test-wsl-interop.sh (5 references), and the script no-ops when the content already matches (lines 105-108), so the risk is bounded - but wsl.conf has no drop-in mechanism, so there is no recovery path if the render is ever wrong for an input shape the tests do not cover.

**Problem.** configure-interop.sh writes /etc/wsl.conf with no backup of the prior file, which is a real gap for a script that touches a vendor config file directly (unlike the drop-in-only pattern used on Fedora) -- but the risk is limited to recovering from an unanticipated bug in render_ini_section_keys or undoing the interop change itself, not general data loss: the renderer is designed and tested to preserve every other section (including [boot] systemd=true) byte-for-byte, and does so.

**Fix.** In platforms/fedora-wsl/scripts/configure-interop.sh, take a one-time backup immediately before the write at line 115: `if [[ -f "$wsl_conf_file" ]] && ! sudo test -f "${wsl_conf_file}.dotfiles-backup"; then sudo cp -p -- "$wsl_conf_file" "${wsl_conf_file}.dotfiles-backup"; info "Saved the previous $wsl_conf_file to ${wsl_conf_file}.dotfiles-backup"; fi`, guarded by the same `-f` test so a machine with no wsl.conf does not get an empty backup, and written only once so a rerun never overwrites the pristine original with an already-modified copy. Mention the backup path and the restore command (`sudo mv ${wsl_conf_file}.dotfiles-backup $wsl_conf_file` then `wsl --shutdown`) in the script's usage() text (lines 31-34) and in the README's Fedora-WSL interop section, and include it in the --dry-run plan output at lines 71-95.

**Acceptance.** In tests/test-wsl-interop.sh, seed a WSL_CONF_FILE containing `[boot]\nsystemd=true` plus a custom `[user]` section, run configure-interop.sh, and assert (a) `${WSL_CONF_FILE}.dotfiles-backup` exists and is byte-identical to the seeded content, (b) a second run does not modify the backup, (c) --dry-run creates no backup file.

**Verifier note.** The mechanical write is confirmed: configure-interop.sh:111-115 does `sudo install -m 0644` of a freshly rendered temp file over /etc/wsl.conf with no backup taken, and it is the only vendor /etc file this repo edits in place (hardening.sh:3-6 states the drop-in-only policy for the Fedora side). But the finding's central risk claim -- that the write 'replaces every byte... including a user's [boot] systemd=true, [network], [user] and [automount] sections' -- is not accurate as a description of what actually happens. render_ini_section_keys (platforms/fedora-wsl/lib/wsl.sh:70+) is explicitly documented and written to update only the [interop] section's two keys while preserving 'every other section, key, comment, and blank line... byte-for-byte and in its original position'; configure-interop.sh's own usage() text repeats this guarantee verbatim ('Every other section and key already in /etc/wsl.conf, including an existing [boot] systemd=true, is preserved untouched'). So under normal operation no other section is lost -- the auditor's own notes concede the renderer is well-unit-tested and 'the risk is bounded.' The narrower, legitimate point is that there is no backup/rollback for the rare case where the renderer mis-handles an input shape its tests don't cover, or where a user wants to revert the interop change itself.

### SEC-10: The machine-local Git identities the repo now gitignores are still in the published history, and setup-local.sh depends on them being there
*low, hygiene. verified by a second agent.*

**Locations.** `.gitignore:1`, `common/setup-local.sh:43`, `README.md:1074`

**Evidence.** .gitignore lines 1-2 exclude `/git/.config/git/local` and `/git/.config/git/drdk`, and README.md:1074 states the rule: "Do not commit signing keys or user-specific signing configuration to this repository." Both files were nonetheless committed and are still reachable in this public repository's history: `git show 2309ad0:git/.config/git/local` yields `[user] name = KasperElbo`, `email = kasper.elbo@gmail.com`, `signingkey = ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...`, `[gpg "ssh"] program = "/opt/1Password/op-ssh-sign"`, `[commit] gpgsign = true`; `git show 2309ad0:git/.config/git/drdk` yields `[user] name = Kasper Elbo`, `email = ekel@dr.dk`. They were deleted in 485186f ("Keep Git identities machine-local"). No private key is exposed - the signingkey value is an SSH public key - and the personal email already appears in all 259 commits' authorship. The corporate address ekel@dr.dk does not: `git log --all --format='%ae' | sort -u` returns only kasper.elbo@gmail.com and noreply@anthropic.com, so that blob is its only occurrence. common/setup-local.sh:36-52 (restore_former_git_config) deliberately reads these blobs back out of history as a migration fallback: `git -C "$DOTFILES_ROOT" show "${revision}:${repo_relative_path}" >"$destination"`, driven by `git log --all --format='%H' -- "$repo_relative_path"`. It does chmod 600 the result (line 54).

**Problem.** Two small things, both factual rather than alarming. The .gitignore and the README rule only bind future commits; the content the rule exists to keep out is still in the public history, and the one address that is not otherwise public is a corporate one. And the repository's own migration code is coupled to that history: if the history is ever rewritten to remove those blobs, common/setup-local.sh's fallback silently stops restoring anything (it warns and writes an empty file at line 119), so cleanup and code have to move together.

**Fix.** Decide explicitly and record the decision. If the exposure is acceptable, add one line to README.md near line 1074 saying that git/.config/git/{local,drdk} existed in history before commit 485186f and that the values there are a public SSH signing key plus two email addresses, so no rewrite is planned - this stops the question recurring. If it is not acceptable, purge with `git filter-repo --path git/.config/git/local --path git/.config/git/drdk --invert-paths`, force-push, and in the same change simplify common/setup-local.sh: drop the history-search branch at lines 40-51 and keep only the `[[ -f "$former_stow_path" ]]` branch plus the existing empty-file warning path at line 119, since after a rewrite the history fallback can never succeed. Either way keep the chmod 600 at line 54 and the migration behaviour for users whose files are still stow-symlinked.

**Acceptance.** If purged: `git log --all -- 'git/.config/git/local' 'git/.config/git/drdk'` returns nothing, `git grep -I 'ekel@dr.dk' $(git rev-list --all)` returns nothing, and tests/test-local-state.sh still passes with the history branch removed (add an assertion that a stow-symlinked identity file is migrated and ends up mode 600, and that a missing source produces the documented empty-file warning). If accepted: add a documentation assertion in tests/test-local-state.sh that README.md contains the recorded decision.

**Verifier note.** Verified .gitignore:1-2 excludes git/.config/git/{local,drdk}, README.md:1074 states the no-commit rule, and both files were nonetheless committed in 2309ad0 and removed in 485186f ('Keep Git identities machine-local'), still reachable via `git show 2309ad0:<path>`. Verified the exact content: local has an SSH public signing key (not a private key) plus kasper.elbo@gmail.com; drdk has 'Kasper Elbo' / ekel@dr.dk. Verified `git log --all --format='%ae' | sort -u` returns only kasper.elbo@gmail.com and noreply@anthropic.com, confirming ekel@dr.dk is not otherwise present in commit authorship and this history blob is its only occurrence in the repo. Verified common/setup-local.sh's restore_former_git_config (lines 29-55) does fall back to `git ... show <revision>:<path>` when the former stow path is absent, so the migration code is genuinely coupled to that history staying intact, exactly as claimed.


**Auditor notes for this dimension.** Scope: read in full every file listed in the brief, plus platforms/fedora/lib/fedora.sh, platforms/fedora/scripts/install-asus-hardware.sh (MOK path), platforms/fedora-wsl/scripts/configure-interop.sh, platforms/fedora-wsl/lib/wsl.sh, common/lib/common.sh, common/setup-local.sh, mise/.config/mise/config.toml, .github/workflows/validate.yml, and the relevant README sections (1600-1700, 1780-2000, 2200-2560, 2705-2745).

Suspicions the code disproved, so not reported:

- atomic_write_file's blanket chmod 600 (common/lib/common.sh:64) does not break anything. All 21 call sites write user-owned state/config under $XDG_CONFIG_HOME (dotfiles/*.conf, mise/conf.d/ai.toml, theme-state's ghostty.conf / sway-theme.conf / waybar-theme.css / fuzzel.ini / mako.conf / swaylock.conf); every consumer runs as the same user. mktemp already creates the temp file 0600, so there is no widen-then-narrow race either.

- The AI installer writes no credential or token anywhere. The only two files it creates are ~/.config/mise/conf.d/ai.toml (tool declarations only) and ~/.config/dotfiles/ai.conf (state words like mise-npm/cloned/disabled), both mode 600. Authentication for every tool is left to an interactive step (install-ai.sh:400-418), it never passes GNHF's --push, and it never runs `gh-axi setup hooks`, `lavish-axi setup hooks`, `no-mistakes init`, `backpass init` or `backpass apply`. That matches the help text at lines 64-81 exactly.

- What the agents are AUTHORISED to do is not determined by this repository at all, and that is worth stating plainly rather than as a finding: common/assets/AGENTS.md is 22 lines of style and engineering-standard guidance with no tool allowlist, no filesystem or network restriction and no destructive-command rule; there is no tracked ~/.claude/settings.json, no permissions block, and `grep -rl "allowedTools\|permissions\|dangerously"` finds nothing outside README/AUDIT prose. Every installed agent therefore runs with the full ambient authority of the login user - shell, the whole of $HOME, the dotfiles working tree, gh's authenticated token, and (if --containers-api-socket was used) the rootless Podman API. The repo cannot know or constrain what the tools do internally; what it does determine is that it adds no constraint of its own. README.md:2393-2429 (GNHF) and 2431-2467 (backpass) do document the behavioural risks honestly, including "many unsupervised commits before you look" and backpass's non-Claude default routing and network exposure.

- Version pinning: all AI tools are declared `"latest"` (install-ai.sh:230-252) with no mise lockfile setting, so `mise install`/`mise upgrade` float 11 npm packages. This is not an anomaly - the tracked mise/.config/mise/config.toml uses `latest` for 8 of its 12 entries, so it is the repo's consistent convention rather than an AI-profile-specific weakness, and README's per-tool ownership tables state the update command for each. Not reported as a defect; worth a conscious decision if the maintainer ever wants `settings.lockfile = true`.

- Hardening cross-profile conflicts: I looked for real breakage and found none that is undocumented. The profile touches no firewalld zone, no rp_filter and no unprivileged_bpf (README.md's rejected-ideas table explains each, including the explicit Tailscale split-tunnel rationale), so tailscale, libvirt's virbr0 NAT, avahi, KDE/sway portals and rootless podman are all unaffected. ptrace_scope=1 and dmesg_restrict=1 have accurate Compatibility columns at README.md:1631-1633. The sshd drop-in cannot affect the sftp baseline, which is client-side only (scp/sftp/ssh in the verify command lists). WSL never runs the hardening profile.

- `visudo -cf` at platforms/fedora/lib/hardening.sh:140 is called without sudo, which I initially suspected would fail for a non-root user; on Fedora 42+ visudo lives in the unified /usr/bin and `visudo -c -f <file>` checks only that file, so this is fine. The failure branch also correctly dies without installing anything.

- Secure Boot / MOK: `sudo kmodgenca -a` and `sudo mokutil --import` (install-asus-hardware.sh:277, 301) do extend the machine's boot trust, but they are the standard Fedora akmods flow, gated behind an explicit confirm at line 299, only reached when Secure Boot is already enabled, and probe_mok_key handles the blocked/pending/not-enrolled states distinctly. Not a defect.

- verify-hardening.sh survives the errexit leak from common/lib/common.sh:3 because every risky construct is an if-condition (including `((8#$mode & 8#077))` at line 277, which returns 1 for a correctly-private key). verify-tailscale.sh:82 is the one place in the security-relevant set where the leak is actually reachable - that is SEC-02.

- One small documentation inaccuracy outside this dimension, noted in passing: README.md:2296 says Herdr is installed "via `mise use -g herdr`", but install-ai.sh:231 writes `herdr = "latest"` into the untracked conf.d file. `mise use -g` would write to ~/.config/mise/config.toml, which is the tracked stow package, contradicting the profile's own stated ownership rule at install-ai.sh:64-69. Code is right, README is wrong; too minor and too far from security to spend a finding on.


## Neovim, LazyVim and Mason

### nvim-01: Platform overlays load, but their `init` on the shared LazyVim spec silently kills the documented FocusGained theme reload on macOS and Fedora WSL
*high, correctness. single-source.*

**Locations.** `nvim-lazyvim/.config/nvim/lua/plugins/colorscheme.lua:43`, `platforms/macos/stow/nvim-macos/.config/nvim/lua/plugins/macos.lua:4`, `platforms/fedora-wsl/stow/nvim-wsl/.config/nvim/lua/plugins/wsl.lua:4`, `nvim-lazyvim/.config/nvim/lua/config/lazy.lua:19`, `README.md:3050`, `README.md:4294`

**Evidence.** THE PRIORITY QUESTION, answered empirically: the overlays DO load. `lua/config/lazy.lua:22` declares a directory import, `{ import = "plugins" }`, and every stow invocation in the repo passes `--no-folding` (`common/stow.sh:60`, `platforms/macos/scripts/stow.sh:17`, `platforms/fedora-wsl/scripts/stow.sh:22`), so `~/.config/nvim/lua/plugins/` is a real directory holding one symlink per file rather than a folded package symlink. I stowed both trees into temporary HOMEs and ran lazy.nvim's own discovery function against them: `Util.lsmod("plugins", ...)` returned 8 modules including `plugins.macos` and `plugins.wsl`. lazy's `lsmod` explicitly accepts symlinks (`(type == "file" or type == "link") and name:sub(-4) == ".lua"`). For contrast, stowing WITHOUT `--no-folding` does fail: `stow: existing target is not owned by stow: .config`, exit 1. So folding is correctly avoided.

The real defect is what the overlays do once loaded. Three files declare `init` on the SAME plugin, `LazyVim/LazyVim`: `colorscheme.lua:43-53` (`init = function() vim.api.nvim_create_autocmd("FocusGained", ...)` re-reading `~/.config/dotfiles/theme` and re-applying the Catppuccin flavour), `macos.lua:4-12`, and `wsl.lua:4-26`. lazy.nvim merges multiple fragments of one plugin by chaining them with `__index` metatables in import order (`lazy/core/meta.lua` `_rebuild`: `super = setmetatable(fragment.spec, super and { __index = super } or nil)`), and `lazy/core/loader.lua:112` runs the single resolved value: `if plugin.init then plugin.init(plugin) end`. Only the LAST fragment's `init` survives.

I resolved the real specs through lazy's own `Spec`/`Plugin.values` machinery and then ran the resolved `init`, exactly as the loader does. Results:
  base nvim-lazyvim only (Fedora):  FocusGained autocmds registered: 1
  + nvim-macos overlay (macOS):     FocusGained autocmds registered: 0
  + nvim-wsl overlay (Fedora WSL):  FocusGained autocmds registered: 0
The probe also confirmed `p._.frags` carries two init-bearing fragments and `p.init == last fragment's init` is `true`, `== first fragment's init` is `false`. Import order came back `colorscheme.lua dotnet.lua formatting.lua latex.lua macos.lua markdown.lua mason.lua ocaml.lua`, i.e. `macos.lua`/`wsl.lua` always sort after `colorscheme.lua`, so the platform init deterministically wins and the theme autocmd is deterministically lost.

This breaks two explicit documented promises. README.md:3050: "Neovim reads the machine-local theme state on startup and checks it again on `FocusGained`." README.md:4294, under the troubleshooting heading "Neovim does not update immediately after a theme switch": "Refocus the Neovim window. The Catppuccin config checks the machine-local theme on `FocusGained`." On macOS and Fedora WSL that advice is actively wrong - refocusing does nothing, and the user must restart Neovim to pick up a theme switch.

Separately verified NOT broken, so the fix must preserve it: the overlays' VimTeX viewer override works and is order-independent. Running LazyVim's and vimtex's inits in both orders yields `viewer=open options=@pdf` on macOS and `viewer=wsl-open options=@pdf` on WSL, because `latex.lua:16` guards with `if not vim.g.vimtex_view_general_viewer`. Also verified NOT broken: `opts` fragments DO chain (unlike `init`), so `colorscheme.lua`'s `colorscheme` opt and `wsl.lua:27-44`'s clipboard function both survive - `Plugin.values(p, "opts")` returned `colorscheme` present in both trees.

**Problem.** `init` is a scalar field in lazy.nvim's fragment merge, not a merged/extended one. The repo's overlay pattern assumes every fragment's `init` runs, which is false. Because `colorscheme.lua` already occupies `LazyVim/LazyVim`'s `init` slot in the shared base package, any platform overlay that also attaches `init` to `LazyVim/LazyVim` silently deletes the shared theme-reload behaviour on that platform. Nothing warns: lazy reports no conflict, no test catches it (see nvim-08), and both verify scripts only check that the symlink exists.

**Fix.** Free the `LazyVim/LazyVim` `init` slot in the shared base package so overlays can use it, and stop the shared config from competing for it.

1. In `nvim-lazyvim/.config/nvim/lua/plugins/colorscheme.lua`, delete the `init = function() ... end` block (lines 43-53) from the `LazyVim/LazyVim` spec. Keep the `opts.colorscheme` function (lines 37-41) as is - `opts` fragments chain correctly and this is what applies the flavour at startup.
2. Move the autocmd to `nvim-lazyvim/.config/nvim/lua/config/autocmds.lua`, which LazyVim sources directly rather than as a plugin fragment, so it can never collide. It needs the flavour resolver, so extract `catppuccin_flavour()`/`colorscheme()` from `colorscheme.lua:1-26` into a new module `nvim-lazyvim/.config/nvim/lua/config/theme.lua` returning `M.colorscheme()`, have `colorscheme.lua` require it, and in `autocmds.lua` add:
     vim.api.nvim_create_autocmd("FocusGained", { callback = function()
       local wanted = require("config.theme").colorscheme()
       if vim.g.colors_name ~= wanted then vim.cmd.colorscheme(wanted) end
     end })
   Startup application still comes from the `opts.colorscheme` function, so the VeryLazy timing of `config.autocmds` is harmless.
3. Leave `macos.lua` and `wsl.lua` untouched - once the base package stops using the slot they are the only `init` on `LazyVim/LazyVim` and keep working. Preserve `latex.lua:16`'s `if not vim.g.vimtex_view_general_viewer` guard so the viewer stays order-independent.
4. Add a house rule so this cannot recur: a comment at the top of `lua/config/lazy.lua` and a note in the README's Neovim section stating that platform overlays own `init` on `LazyVim/LazyVim` and the shared packages must not declare it, because lazy.nvim resolves `init` to the last fragment only.
5. Update README.md:3050 and README.md:4294 only if you choose a different mechanism; with this fix both statements become true on all four platforms and need no edit.

**Acceptance.** Add a spec-resolution assertion (see nvim-08 for the shared harness) to `tests/test-neovim-tool-ownership.sh` that, for each of the base tree and the base+nvim-macos and base+nvim-wsl stowed trees, resolves the plugin specs through lazy.nvim and asserts `#vim.api.nvim_get_autocmds({ event = "FocusGained" }) >= 1` after running every resolved `init`. The macOS and WSL cases must go from 0 to 1. Add a cheap textual guard too: assert that `grep -c 'init = function' nvim-lazyvim/.config/nvim/lua/plugins/*.lua` finds no `init` on a `LazyVim/LazyVim` spec in the base package. Manually: on macOS, run `theme mocha` in one terminal, click into Neovim, and confirm the colorscheme changes without a restart.

**My independent check of this one.** I verified the mechanical claims directly: all three
files do declare `"LazyVim/LazyVim"` and each contains exactly one `init = function`
(`colorscheme.lua:36`, `macos.lua:3`, `wsl.lua:3`); `lua/config/lazy.lua:22` is the directory
import `{ import = "plugins" }`; and `--no-folding` is present in all five stow invocations
(`common/stow.sh:63`, and each `platforms/*/scripts/stow.sh`). I also confirmed the agent's
empirical claim is genuine rather than recalled: its transcript shows it cloning
`folke/lazy.nvim` at `--branch=stable` and `LazyVim/LazyVim`, then reading
`lua/lazy/core/util.lua` and running against the real sources across 57 shell invocations.
lazy.nvim is not installed on this machine, so without that clone the claim would not have
been checkable, and I would have downgraded it.

**This also resolves the open question from section 13 of the main report.** I had flagged as
unverified whether the platform overlays load at all, and warned that if they did not, the
platform editor configuration would be silently inert on two platforms. They do load. The
real defect is narrower and more interesting, and the good news is that the mechanism the
repository chose (directory import plus `--no-folding`) is correct.

### nvim-02: No Neovim version floor is asserted at install time, and the pinned LazyVim's version gate turns a too-old Neovim into a 20-minute headless hang with a misleading error
*high, correctness. single-source.*

**Locations.** `common/install-neovim-tools.sh:59`, `common/install-neovim-tools.sh:23`, `common/install-neovim-tools.sh:44`, `common/install-neovim-tools.sh:51`, `platforms/fedora/scripts/verify.sh:516`, `platforms/parrot-ctf/scripts/install-system.sh:28`, `nvim-lazyvim/.config/nvim/lazy-lock.json`

**Evidence.** `lazy-lock.json` pins `"LazyVim": { "branch": "main", "commit": "c10948c5..." }`. I fetched that exact commit (LazyVim 16.0.0) and its `lua/lazyvim/plugins/init.lua:1-10` is a hard gate:
    if vim.fn.has("nvim-0.11.2") == 0 then
      vim.api.nvim_echo({{ "LazyVim requires Neovim >= 0.11.2\n", "ErrorMsg" }, ..., { "Press any key to exit", "MoreMsg" }}, true, {})
      vim.fn.getchar()
      vim.cmd([[quit]])
      return {}
    end
I reproduced the failure mode end to end. With the base package stowed into a temp HOME, lazy.nvim and the pinned LazyVim placed in `$XDG_DATA_HOME/nvim/lazy/`, and Neovim 0.9.5 (this container's `/usr/bin/nvim`), running the installer's own phase-1 command with stdin closed:
    timeout 25s nvim --headless '+Lazy! restore' +qa </dev/null  ->  exit=124
    stdout: "LazyVim requires Neovim >= 0.11.2 ... Press any key to exit" then "Vim: Caught deadly signal 'SIGTERM'"
`vim.fn.getchar()` blocks indefinitely even headless with `/dev/null` on stdin. `common/install-neovim-tools.sh:59` runs exactly that command through `run_nvim_phase`, whose timeout defaults to 20 minutes (`:23` `bootstrap_timeout="${NEOVIM_BOOTSTRAP_TIMEOUT:-20m}"`, `:44-45` `timeout --kill-after=30s "$bootstrap_timeout"`). On exit 124 it reports `:52` `die "$description timed out after $bootstrap_timeout"`, i.e. "Restoring LazyVim plugins timed out after 20m" - naming a timeout, not the version.

No platform asserts a floor before that point. The only Neovim version check in the whole repo is post-hoc and on one platform: `platforms/fedora/scripts/verify.sh:516-521` runs `nvim --headless '+lua assert(vim.fn.has("nvim-0.12") == 1)' +qa` and reports `pass "Neovim >= 0.12"`. `grep -rn 'nvim-0\.' --include=*.sh --include=*.lua .` returns that line and nothing else: `platforms/fedora-wsl/scripts/verify.sh`, `platforms/macos/scripts/verify.sh` and `platforms/parrot-ctf/scripts/verify.sh` have no version check at all. All four platforms take Neovim from a distro/brew package with no version constraint (`platforms/fedora/scripts/install-system.sh:20`, `platforms/fedora-wsl/scripts/install-system.sh:27`, `platforms/parrot-ctf/scripts/install-system.sh:28` all list bare `neovim`; `platforms/macos/Brewfile:15` is `brew "neovim"`). Parrot is the sharpest case: it never runs `install-neovim-tools.sh` at all (`platforms/parrot-ctf/install.sh:101-106`), so the gate is first hit interactively by the user, while `platforms/parrot-ctf/scripts/verify.sh:36` only does `check_command nvim` and `:70` only checks the `init.lua` symlink - verify can report all green on a Neovim that cannot start the config.

Also note the numbers disagree with no stated rationale: Fedora demands 0.12 while the pinned LazyVim's own floor is 0.11.2, and no README text states any Neovim version requirement (`grep -n 'Neovim >=' README.md` finds nothing).

**Problem.** The config has a hard runtime floor inherited from the pinned LazyVim, and that floor is enforced by upstream in the one way that is worst for an automated installer: a blocking `getchar()` that ignores headless mode. Nothing in the repo checks the floor before invoking Neovim headlessly, so a platform whose packaged Neovim is too old produces a 20-minute silent hang followed by a diagnosis that points at the timeout rather than the cause. On Parrot the check is skipped entirely and verify still passes.

**Fix.** Assert the floor once, early, in the shared helper, and make the platform verifiers agree on it.

1. In `common/lib/common.sh`, add `require_neovim_version()` that parses `nvim --version | head -1` (or better, runs `nvim --headless -u NONE --clean '+lua io.stdout:write(vim.fn.has("nvim-0.11.2"))' +qa` with a short `timeout 30s` so a broken binary cannot hang) and calls `die "Neovim >= 0.11.2 is required by the pinned LazyVim (lazy-lock.json); found $version"` when unmet. Define the floor once as a constant, e.g. `DOTFILES_NVIM_MIN="0.11.2"`, in `common/lib/common.sh`.
2. Call it in `common/install-neovim-tools.sh` immediately after `require_command nvim` (line 7), before `run_nvim_phase` ever runs, so the failure is a one-line message instead of a 20-minute timeout.
3. Harden `run_nvim_phase` so a future blocking prompt cannot hang either: pass `</dev/null` is not enough (proven above), so also add `-n` is irrelevant - instead reduce the blast radius by keeping the explicit `require_neovim_version` gate and lowering the message ambiguity: in the `((status == 124 || status == 137))` branch at `:51`, append a hint naming the version floor as the most common cause.
4. Add the same check to the three verifiers that lack it - `platforms/fedora-wsl/scripts/verify.sh`, `platforms/macos/scripts/verify.sh`, `platforms/parrot-ctf/scripts/verify.sh` - reusing `require_neovim_version` or a `check_*` wrapper so they report pass/fail in the normal style. Reconcile `platforms/fedora/scripts/verify.sh:516-521` to the same constant, or document in the README why Fedora deliberately demands 0.12 while the config's floor is 0.11.2.
5. Since Parrot skips `install-neovim-tools.sh`, put the gate in `platforms/parrot-ctf/scripts/stow.sh` (or in its `install-system.sh` after the `neovim` install) so the profile refuses to stow a config its Neovim cannot load, or - if the APT Neovim is genuinely too old - stop stowing `nvim-lazyvim` there (see nvim-05) and say so in the README's "Parrot / APT" section at README.md:2734.
6. State the Neovim floor in the README's Neovim/Mason section next to the lazy-lock discussion, so bumping the pin is a two-file change.

**Acceptance.** Add to `tests/test-neovim-bootstrap.sh` a case using the existing mock-`nvim` harness: have the mock print `NVIM v0.10.4` for `--version` and return 1 from the version probe, then assert `common/install-neovim-tools.sh` exits non-zero within seconds and its output contains `Neovim >= 0.11.2 is required`, and assert the command log contains NO `<+Lazy! restore>` entry for that run (proving the gate fires before the 20m phase). Extend the existing per-platform verify tests (`tests/test-fedora-wsl.sh`, `tests/test-macos.sh`, `tests/test-parrot-ctf.sh`) with `assert_contains` on the new version check in each verify script. Manually: `nvim --version` on each target must report >= the constant, and `platforms/*/scripts/verify.sh` must fail on a deliberately downgraded Neovim.

### nvim-03: macOS verify never checks the Mason inventory, contradicting the README's explicit promise and leaving 15 of 16 editor tools unverified
*high, parity. single-source.*

**Locations.** `platforms/macos/scripts/verify.sh:111`, `platforms/fedora/scripts/verify.sh:476`, `platforms/fedora-wsl/scripts/verify.sh:336`, `README.md:2850`, `nvim-lazyvim/.config/nvim/mason-packages.txt:1`

**Evidence.** README.md:2850-2853 promises, in the shared Mason section that introduces `mason-packages.txt` as "the complete expected inventory": "`scripts/verify.sh` fails when an intended package is missing and warns about additional Mason packages so stale or manually installed tools can be reviewed instead of silently acquiring a second owner."

Fedora implements exactly that. `platforms/fedora/scripts/verify.sh:475-494`:
    mason_root="${XDG_DATA_HOME}/nvim/mason/packages"
    mason_inventory="$DOTFILES_ROOT/nvim-lazyvim/.config/nvim/mason-packages.txt"
    mapfile -t mason_packages < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$mason_inventory")
    for package in "${mason_packages[@]}"; do
      if [[ -d "$mason_root/$package" ]]; then pass "Mason: $package"; else fail "Mason package not installed: $package"; fi
    done
followed by the extra-package loop that emits `warning "Unexpected Mason package (review ownership): $package"` (`:511`). `platforms/fedora-wsl/scripts/verify.sh:336` has the same `mason_inventory` block.

macOS has neither. `grep -n -i 'mason' platforms/macos/scripts/verify.sh` returns exactly two lines:
    111: netcoredbg="$XDG_DATA_HOME/nvim/mason/packages/netcoredbg/libexec/netcoredbg/netcoredbg"
    112: check_arm64_file "Mason netcoredbg" "$netcoredbg"
So of the 16 packages in `mason-packages.txt` (angular-language-server, debugpy, eslint-lsp, js-debug-adapter, json-lsp, lua-language-server, marksman, netcoredbg, pyright, roslyn, ruff, shfmt, stylua, texlab, vtsls, yaml-language-server) macOS verifies one, and there is no unexpected-package warning. macOS does run the provisioner (`platforms/macos/install.sh:171` `"$DOTFILES_ROOT/common/install-neovim-tools.sh"`), so the inventory is expected to be present and this is a pure verification gap, not a scope decision. The macOS `commands=(...)` list at `platforms/macos/scripts/verify.sh:95` contains no Mason binaries either.

The repo's own tests encode the asymmetry rather than catching it: `tests/test-neovim-tool-ownership.sh:134-141` asserts the inventory loop and the `fail "Mason package not installed: $package"` string in the fedora and fedora-wsl verify scripts, and asserts nothing of the sort for macOS. `tests/test-macos.sh:182` only checks that `nvim-macos` is mentioned in the macOS verify script.

**Problem.** A documented verification guarantee is honoured on two of the three platforms that provision Mason. On macOS, `platforms/macos/scripts/verify.sh` reports a fully green run even when 15 of the 16 Mason packages are missing - for example after a partial or interrupted `install-neovim-tools.sh`, or after a user manually uninstalled a package - so the platform is silently degraded and the verifier gives a false pass on the very inventory the README calls canonical.

**Fix.** Lift the inventory check into shared code and call it from all three provisioning platforms.

1. Create `common/verify-mason.sh` (matching the existing `common/verify-ai.sh` / `common/verify-ocaml.sh` pattern) containing the loop currently duplicated at `platforms/fedora/scripts/verify.sh:475-513`: read `$DOTFILES_ROOT/nvim-lazyvim/.config/nvim/mason-packages.txt` with the same `sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d'` filter, `fail "Mason package not installed: $package"` for each missing entry, and `warning "Unexpected Mason package (review ownership): $package"` for each extra directory under `$XDG_DATA_HOME/nvim/mason/packages`. Keep the existing `pass`/`fail`/`warning` helpers so output style is unchanged. Note the established fact that `common/lib/common.sh:3` imposes `set -euo pipefail` on sourced verify code - keep the loop tolerant of a missing `mason_root` directory as the Fedora version already is (`if [[ -d "$mason_root" ]]`).
2. Replace the inline blocks in `platforms/fedora/scripts/verify.sh` and `platforms/fedora-wsl/scripts/verify.sh` with a call to it, and add the same call to `platforms/macos/scripts/verify.sh` in its "Configuration links"/tooling area, keeping the existing `check_arm64_file "Mason netcoredbg"` check at `:111-112` since arm64-ness is a genuinely macOS-specific extra assertion.
3. Do not add it to `platforms/parrot-ctf/scripts/verify.sh` - Parrot deliberately never provisions Mason; handle that profile per nvim-05 instead.
4. Update README.md:2850 to name the shared script (`common/verify-mason.sh`, invoked by each platform's `scripts/verify.sh`) so the promise points at one implementation.

**Acceptance.** In `tests/test-neovim-tool-ownership.sh`, generalise the existing assertions at lines 134-141 to loop over all three verify scripts - `platforms/fedora/scripts/verify.sh`, `platforms/fedora-wsl/scripts/verify.sh`, `platforms/macos/scripts/verify.sh` - asserting each references `common/verify-mason.sh`, and add `assert_contains "$repo_root/common/verify-mason.sh"` for both `mason-packages.txt` and `fail "Mason package not installed: $package"`. In `tests/test-macos.sh`, add a `grep -Fq 'verify-mason.sh' "$macos_root/scripts/verify.sh"` assertion next to the existing `nvim-macos` check at line 182. Manually: on macOS, `rm -rf ~/.local/share/nvim/mason/packages/stylua` and confirm `platforms/macos/scripts/verify.sh` now fails with `Mason package not installed: stylua`.

### nvim-04: macOS documents and offers a LaTeX editing workflow, but the macOS profile installs no TeX distribution at all
*high, completeness. single-source.*

**Locations.** `docs/macos.md:114`, `docs/macos.md:125`, `platforms/macos/Brewfile:1`, `platforms/macos/install.sh:44`, `platforms/macos/stow/nvim-macos/.config/nvim/lua/plugins/macos.lua:9`, `scripts/test-dev-workflows.sh:237`, `docs/keybindings.md:163`, `nvim-lazyvim/.config/nvim/mason-packages.txt:14`

**Evidence.** The macOS docs present LaTeX as a supported workflow. `docs/macos.md:107-114` lists, under "Or run them separately", four validation commands, the last being `./scripts/test-dev-workflows.sh --latex`. `docs/macos.md:125-130` then describes it: "LaTeX uses the shared VimTeX/texlab setup. The shared editor configuration only falls back to Okular or `xdg-open` for the PDF viewer, neither of which exists on macOS, so a small `platforms/macos/stow/nvim-macos` package overrides `vimtex_view_general_viewer` to macOS's native `open`...". `docs/keybindings.md:163-169` documents the bindings without any platform caveat - `\ll` -> `:VimtexCompile` "start/stop continuous `latexmk`" and `<leader>cf` -> "format via TexLab + `latexindent`" - and `docs/keybindings.md:176-178` explicitly says `\lv` uses "macOS's `open` (no SyncTeX)". The overlay is real and I verified it works: `platforms/macos/stow/nvim-macos/.config/nvim/lua/plugins/macos.lua:9-11` sets `vim.g.vimtex_view_general_viewer = "open"`, and resolving the specs through lazy.nvim yields `viewer=open options=@pdf` regardless of init order. `texlab` is also genuinely installed on macOS - `mason-packages.txt:14` lists it, `lazyvim.json:8` enables `lazyvim.plugins.extras.lang.tex`, and `platforms/macos/install.sh:171` runs `common/install-neovim-tools.sh`.

But nothing installs TeX. `grep -n -i tex platforms/macos/Brewfile platforms/macos/scripts/install-system.sh` returns nothing; the complete 27-line `platforms/macos/Brewfile` is bash, bat, coreutils, eza, fd, fzf, gh, git, git-delta, jq, mise, neovim, ripgrep, shellcheck, sqlite, starship, stow, tmux, zsh-autosuggestions, zsh-syntax-highlighting, plus the ghostty and aerospace casks - no mactex, no basictex, no latexmk, no latexindent. `platforms/macos/install.sh`'s option parser (lines 44-61) has `--ocaml`, `--containers`, `--tailscale`, `--defaults`, `--workflows` and no `--latex`, unlike Fedora and Fedora-WSL which provide an optional LaTeX profile: `platforms/fedora/scripts/install-latex.sh:15` installs `texlive-latexindent` and `platforms/fedora-wsl/install.sh:276` advertises "latexmk, latexindent, Biber and the medium TeX Live scheme". README.md:4052 and README.md:4063 correspondingly scope formatting to "Fedora's `latexindent`" and "DNF-owned `latexindent`", and `latex.lua:55-57`'s own comment says "Fedora supplies latexindent".

Consequences on macOS: `\ll` cannot compile (no `latexmk`), `<leader>cf` on a `.tex` buffer cannot format (no `latexindent` for texlab's `latexFormatter = "latexindent"` at `latex.lua:58`), and the documented `./scripts/test-dev-workflows.sh --latex` dies immediately at `scripts/test-dev-workflows.sh:237-239` `require_command latexindent` / `latexmk` / `pdflatex`. Only texlab-side completion and navigation work.

**Problem.** A documented, platform-specific feature has editor configuration and a Mason language server behind it but no toolchain. The macOS docs point the reader at a `--latex` validation command that cannot succeed there, and `docs/keybindings.md` presents the compile and format bindings as universal when two of the three LaTeX pillars are Fedora-only. This is not the deliberate optional-profile design either - Fedora and Fedora-WSL gate LaTeX behind an explicit `--latex` install option, and macOS simply has no such option to turn on.

**Fix.** Pick one of two coherent positions and make code and docs agree.

Preferred - give macOS the same optional profile it has for OCaml/containers/Tailscale:
1. Add `platforms/macos/scripts/install-latex.sh` mirroring `platforms/fedora/scripts/install-latex.sh`: install the TeX toolchain via Homebrew (`brew install --cask basictex` plus `tlmgr install latexmk latexindent biber biblatex`, or `brew install --cask mactex-no-gui` for the full scheme) and print the same confirmation lines the Fedora script does at `:27`.
2. Add `--latex` / `--no-latex` to `platforms/macos/install.sh`'s option parser (lines 44-61) defaulting to false, invoke `install-latex.sh` from the step list around line 159-175 next to the existing optional `install-ocaml.sh` call, and add `--latex` to the `verify_args` propagation at lines 196-198.
3. Extend `platforms/macos/scripts/verify.sh` with the LaTeX command loop that `platforms/fedora-wsl/scripts/verify.sh:205` already has: `for command_name in biber latex latexindent latexmk lualatex pdflatex xelatex; do ... done`, gated on the same `$XDG_CONFIG_HOME/dotfiles/*.conf` state marker pattern the OCaml profile uses.
4. Update `docs/macos.md:100-130` to show `./install.sh --platform macos --latex` before offering `test-dev-workflows.sh --latex`, and update the README's LaTeX section (around README.md:4029, 4052, 4063) so "Fedora's `latexindent`" becomes "the platform's `latexindent` (DNF on Fedora, Homebrew/TeX Live on macOS)". Amend `latex.lua:55`'s "Fedora supplies latexindent" comment accordingly.

Alternative - if macOS LaTeX is deliberately out of scope: remove `./scripts/test-dev-workflows.sh --latex` from `docs/macos.md:114`, replace the `docs/macos.md:125-130` paragraph with an explicit statement that the macOS profile installs no TeX distribution and that the `nvim-macos` viewer override exists only for users who bring their own, and add a platform note to the LaTeX table in `docs/keybindings.md:160-178` saying `\ll` and `<leader>cf` require the Fedora/Fedora-WSL `--latex` profile.

**Acceptance.** If adding the profile: extend `tests/test-latex-profile.sh` - which today only inspects `nvim-lazyvim/.../latex.lua` and the Fedora package list - with assertions that `platforms/macos/scripts/install-latex.sh` exists and names `latexmk`, `latexindent` and `biber`, that `platforms/macos/install.sh` parses `--latex`, and that `platforms/macos/scripts/verify.sh` checks the `latexindent latexmk pdflatex` commands; add a `--latex` dry-run assertion to `tests/test-macos.sh` alongside its existing `nvim-macos` checks. Then run `./install.sh --platform macos --latex` on the target and confirm `./scripts/test-dev-workflows.sh --latex` passes and `\ll` produces a PDF that `\lv` opens. If choosing the alternative: add a `tests/test-macos.sh` assertion that `docs/macos.md` does NOT contain `test-dev-workflows.sh --latex`, and that `docs/keybindings.md` contains the platform caveat string.

### nvim-05: The Parrot CTF guest stows the full LazyVim config, whose non-lazy Mason spec tries to install all 16 editor tools on first launch with no node or dotnet provisioned
*medium, completeness. single-source.*

**Locations.** `common/stow.sh:34`, `platforms/parrot-ctf/install.sh:101`, `platforms/parrot-ctf/stow/mise-ctf/.config/mise/config.toml:1`, `nvim-lazyvim/.config/nvim/lua/plugins/mason.lua:4`, `nvim-lazyvim/.config/nvim/lua/plugins/mason.lua:13`, `platforms/parrot-ctf/scripts/verify.sh:36`, `README.md:2736`

**Evidence.** `common/stow.sh:34` lists `nvim-lazyvim` in the portable package set, and `platforms/parrot-ctf/scripts/stow.sh:12` calls `"$DOTFILES_ROOT/common/stow.sh" --headless --without-mise`, so Parrot receives the complete LazyVim configuration - `lazyvim.json`'s nine extras, `mason-packages.txt`'s 16 packages, and `lua/plugins/{dotnet,formatting,latex,markdown,mason,ocaml}.lua`.

Parrot then provisions none of it. `platforms/parrot-ctf/install.sh:101-106` runs `install-system.sh`, `install-guest-integration.sh`, `common/setup-local.sh`, `scripts/stow.sh`, `common/install-mise.sh`, `common/install-tmux-theme.sh` - and never `common/install-neovim-tools.sh`, unlike Fedora (`platforms/fedora/install.sh:826`), Fedora-WSL (`platforms/fedora-wsl/install.sh:399`) and macOS (`platforms/macos/install.sh:171`). The Parrot mise manifest is deliberately narrow: `platforms/parrot-ctf/stow/mise-ctf/.config/mise/config.toml` is `[tools]` / `uv = "latest"` with the comment "Add challenge-specific runtimes in the challenge repository instead of turning this VM profile into the general workstation manifest." No node, no dotnet - and `grep -n 'node\|dotnet\|npm' platforms/parrot-ctf/scripts/install-system.sh` returns nothing.

So Mason's work lands on the user's first interactive launch, unbounded. `nvim-lazyvim/.config/nvim/lua/plugins/mason.lua:4` sets `lazy = false` on `mason-org/mason.nvim`, overriding LazyVim's own lazy-loading (`cmd = "Mason"`, `keys = { { "<leader>cm", ... } }` in LazyVim's `lua/lazyvim/plugins/lsp/init.lua:283-285`), and `:13-18` appends every entry of `require("config.mason").packages()` to `ensure_installed`. LazyVim's mason `config` then does a network registry refresh and an install loop with no error handling:
    mr.refresh(function()
      for _, tool in ipairs(opts.ensure_installed) do
        local p = mr.get_package(tool)
        if not p:is_installed() then p:install() end
      end
    end)
On Parrot that means, on every startup until it succeeds, a registry refresh against both `github:mason-org/mason-registry` and `github:Crashdummyy/mason-registry` (added by `dotnet.lua:10-12`) plus install attempts for the npm-backed packages (angular-language-server, eslint-lsp, js-debug-adapter, json-lsp, pyright, vtsls, yaml-language-server) with no `npm` present, and for `roslyn`/`netcoredbg` with no `dotnet` present.

Nothing documents or verifies this. `platforms/parrot-ctf/scripts/verify.sh:36` only lists `nvim` among `commands=(...)` and `:70` only checks the `$XDG_CONFIG_HOME/nvim/init.lua` symlink. README.md:2734-2742 ("Parrot / APT") explains the narrowed mise manifest, the `bat`/`fd` shims and APT-owned Starship, but says nothing about the editor tooling. The README does write out comparable exclusions elsewhere - README.md:2025-2029 for desktop tools, README.md:2618-2619 for AI tooling - so the omission is an inconsistency, not a stated position.

**Problem.** A profile that deliberately narrows every other tool manifest inherits the workstation editor manifest wholesale. The result is a disposable CTF guest whose editor tries and fails to fetch a .NET/Angular/Python toolchain from the network on every launch, with failures visible only as Mason notifications, no provisioning step to surface them, and a verify script that passes regardless. It also contradicts design principle 5 in spirit: shared configuration is tracked, but this shared configuration encodes workstation-only tool ownership.

**Fix.** Make the Mason inventory opt-in per platform instead of unconditional, matching how the mise manifest is already narrowed.

1. Add a `--without-nvim-tooling` style switch to `common/stow.sh`'s option parser (lines 11-27, next to the existing `--headless` and `--without-mise`) that stows a second, narrow package instead of the full inventory - or, simpler and preferred, keep stowing `nvim-lazyvim` and gate the inventory at read time.
2. Preferred shape: make `nvim-lazyvim/.config/nvim/lua/config/mason.lua` `M.packages()` return `{}` when a machine-local opt-out marker is present, reusing the existing machine-local state convention (`$XDG_CONFIG_HOME/dotfiles/...`, the same directory `colorscheme.lua:4` reads `dotfiles/theme` from and that `common/setup-local.sh` writes). Then in `nvim-lazyvim/.config/nvim/lua/plugins/mason.lua`, when the returned list is empty, leave `opts.ensure_installed` untouched and drop `lazy = false` so mason reverts to LazyVim's `cmd = "Mason"` lazy-loading and never refreshes registries unprompted. `config/mason.lua:14-16` currently `error()`s on an empty inventory - that guard must move to the callers that genuinely require a non-empty list (`common/install-neovim-tools.sh` already dies at `:16`).
3. Have `common/setup-local.sh` write that marker when invoked from the Parrot profile, or have `platforms/parrot-ctf/scripts/stow.sh` write it explicitly after calling `common/stow.sh`, with a comment mirroring the existing "The normal workstation mise manifest is deliberately not part of this profile" comment at `platforms/parrot-ctf/scripts/stow.sh:9-10`.
4. Add a paragraph to README.md's "Parrot / APT" section at 2734 stating that the guest stows the shared LazyVim configuration but not the Mason editor-tool inventory, that Neovim there is a text editor with Treesitter and no language servers, and that challenge-specific language servers belong in the challenge repository - the same boundary README.md:945-948 already draws for Python packages.
5. Extend `platforms/parrot-ctf/scripts/verify.sh` with an assertion that the opt-out marker exists and that `$XDG_DATA_HOME/nvim/mason/packages` is absent or empty, so the boundary is enforced rather than assumed.

**Acceptance.** Add to `tests/test-parrot-ctf.sh` (which already checks the stow package list at line 135): an assertion that `platforms/parrot-ctf/scripts/stow.sh` or `install.sh` writes the opt-out marker, and an assertion that `platforms/parrot-ctf/scripts/verify.sh` checks for an empty Mason root. Add a lua assertion to `tests/test-neovim-first-launch.lua` next to the existing `DOTFILES_MASON_BOOTSTRAP` cases at lines 82-85: with the opt-out marker present, `mason_plugins[1].opts(nil, { ensure_installed = { "stylua" } })` must leave `ensure_installed` as `{ "stylua" }` and the spec must not set `lazy = false`. Manually: in a fresh Parrot guest, run the installer then `nvim --headless '+lua print(vim.fn.isdirectory(vim.fn.stdpath("data").."/mason/packages"))' +qa` and confirm `0`, and open `nvim` interactively confirming no Mason install notifications.

### nvim-06: The Mason registry list is declared twice with nothing keeping the two copies in sync
*medium, maintainability. single-source.*

**Locations.** `common/bootstrap-mason.lua:12`, `nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua:6`, `tests/test-neovim-first-launch.lua:116`

**Evidence.** Two independent declarations of the same list. `common/bootstrap-mason.lua:12-17`, used by the headless provisioning phase:
    require("mason").setup({
      registries = {
        "github:mason-org/mason-registry",
        "github:Crashdummyy/mason-registry",
      },
    })
and `nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua:5-12`, used by every interactive session:
    opts = function(_, opts)
      opts.registries = opts.registries or {
        "github:mason-org/mason-registry",
      }
      if not vim.tbl_contains(opts.registries, "github:Crashdummyy/mason-registry") then
        table.insert(opts.registries, "github:Crashdummyy/mason-registry")
      end
I confirmed these are the only two occurrences: `grep -rn Crashdummyy .` returns `dotnet.lua:10`, `dotnet.lua:11`, `bootstrap-mason.lua:15` and `tests/test-neovim-first-launch.lua:117` - no shared constant, no cross-check. The shapes even differ: the plugin spec is written defensively (idempotent append, preserves any pre-existing `opts.registries`), the bootstrap script is a flat literal that overwrites whatever mason would otherwise default to.

The test suite checks presence but not equality. `tests/test-neovim-first-launch.lua:116-119` asserts only:
    assert(vim.tbl_contains(mason_setup_opts.registries, "github:Crashdummyy/mason-registry"),
      "headless bootstrap omitted the custom .NET Mason registry")
It never compares the bootstrap list against the list `dotnet.lua` builds, and `tests/test-neovim-tool-ownership.sh:128-129` only asserts that `bootstrap-mason.lua` contains the string `require("mason.api.command").MasonInstall`. So adding a third registry to `dotnet.lua` - the natural place, since that is where plugin-facing Mason configuration lives - leaves `bootstrap-mason.lua` unaware, and the whole point of that file is that it refreshes the configured registries before installing (its comment at `:19-20`: "MasonInstall blocks in headless mode, exits non-zero for an invalid package or failed install, and refreshes the configured registries before installing").

**Problem.** The provisioning path and the interactive path each carry their own copy of the registry list, so they can silently diverge. The concrete failure: a package added to `mason-packages.txt` that resolves only through a registry declared in `dotnet.lua` but missing from `bootstrap-mason.lua` will fail during `common/install-neovim-tools.sh` (as an unhelpful `MasonInstall` non-zero exit inside "Installing Mason editor tools failed with exit status N"), while working fine interactively - or vice versa. Nothing in lint or tests detects the divergence.

**Fix.** Give the registry list one owner, the way `mason-packages.txt` already owns the package list.

1. Add a tracked inventory file next to it: `nvim-lazyvim/.config/nvim/mason-registries.txt`, one registry per line, `#` comments and blank lines allowed - identical format to `mason-packages.txt`.
2. Extend `nvim-lazyvim/.config/nvim/lua/config/mason.lua` with `M.registries(path)` alongside the existing `M.packages(path)` (lines 3-19), reusing the same `vim.fn.readfile` / `vim.trim` / `vim.startswith(package, "#")` filtering and the same empty-inventory `error()`.
3. Rewrite `nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua:5-12` to set `opts.registries = require("config.mason").registries()` (keeping the `DOTFILES_MASON_BOOTSTRAP == "1"` early return at `:14-16` intact, since `mason.lua` and this file both need it).
4. Rewrite `common/bootstrap-mason.lua:12-17` to read the same file. It runs with `-u NONE` and only prepends the mason plugin to the rtp (`:10`), so it cannot `require("config.mason")`; pass the list in from the shell instead, mirroring the existing `DOTFILES_MASON_PACKAGES` mechanism: have `common/install-neovim-tools.sh` read `mason-registries.txt` with the same `sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d'` filter it already uses for packages at `:13-15`, validate each entry against a `^github:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$` pattern the way it validates package names at `:18-21`, and export `DOTFILES_MASON_REGISTRIES` next to `DOTFILES_MASON_PACKAGES` at `:70-71`. `bootstrap-mason.lua` then splits it with the same `vim.split(..., " ", { trimempty = true })` call it already uses at `:21`, and asserts it is non-empty like `:8` does for packages.
5. Update README.md's Mason section (around 2822-2857, which today only names `mason-packages.txt` as canonical) to describe `mason-registries.txt` as the single source for registries and to explain why the Crashdummyy registry is needed for `roslyn`/`netcoredbg`.

**Acceptance.** In `tests/test-neovim-first-launch.lua`, replace the presence-only assertion at lines 116-119 with an equality assertion: read `mason-registries.txt` via `require("config.mason").registries()`, and assert `vim.deep_equal(mason_setup_opts.registries, registries)` for the bootstrap path and `vim.deep_equal(dotnet_mason_opts.registries, registries)` after invoking `dotnet.lua`'s mason `opts` function with `DOTFILES_MASON_BOOTSTRAP` unset - so the two paths are asserted identical, not merely both non-empty. In `tests/test-neovim-tool-ownership.sh`, add `assert_contains` for `DOTFILES_MASON_REGISTRIES` in both `common/install-neovim-tools.sh` and `common/bootstrap-mason.lua`, and assert `github:Crashdummyy/mason-registry` appears in `mason-registries.txt` and in neither .lua file. Run `bash scripts/test.sh` and confirm both new assertions fail if a registry is added to only one place.

### nvim-07: No shell language server and no in-editor ShellCheck, in a repository that is almost entirely shell
*medium, completeness. single-source.*

**Locations.** `nvim-lazyvim/.config/nvim/mason-packages.txt:12`, `nvim-lazyvim/.config/nvim/lazyvim.json:2`, `README.md:2839`, `scripts/lint.sh`

**Evidence.** The repository is 143 tracked shell files and ships its own `scripts/lint.sh` shell pipeline, yet the editor configuration provides no shell language intelligence.

Against the pinned LazyVim (`lazy-lock.json` commit `c10948c5`, LazyVim 16.0.0) I checked where shell support comes from:
  - `bashls` is declared only in `lua/lazyvim/plugins/extras/util/dot.lua:16` (`bashls = {}`), together with `opts = { ensure_installed = { "shellcheck" } }` at `:22`. `nvim-lazyvim/.config/nvim/lazyvim.json:2-12` enables nine extras - `dap.core`, `lang.angular`, `lang.json`, `lang.markdown`, `lang.python`, `lang.tex`, `lang.yaml`, `linting.eslint`, `test.core` - and `util.dot` is not among them. So there is no shell LSP.
  - `nvim-lint`'s only default is fish: `lua/lazyvim/plugins/linting.lua` has `linters_by_ft = { fish = { "fish" } }`, and the repo's only `nvim-lint` customisation is `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua:19-26`, which *removes* an entry (`opts.linters_by_ft.markdown = nil`) and adds none. So there are no in-editor ShellCheck diagnostics.
  - What does work: `shfmt` as a formatter (LazyVim `lua/lazyvim/plugins/formatting.lua:76` `sh = { "shfmt" }`, with the binary in `mason-packages.txt:12`), and the `bash` Treesitter parser (LazyVim `lua/lazyvim/plugins/treesitter.lua` default `ensure_installed` includes `"bash"`).

ShellCheck itself is installed system-wide on the platforms that matter - `tests/test-neovim-tool-ownership.sh:92` asserts `'  ShellCheck'` in `platforms/fedora/scripts/install-system.sh`, `platforms/macos/Brewfile` has `brew "shellcheck"`, and `platforms/macos/scripts/verify.sh:95` lists `shellcheck` among verified commands - so the binary is present and only the editor wiring is missing. README.md:2839 lists shell tooling as exactly one row, `| `shfmt` | LazyVim core | Editor formatting for shell files |`, and `grep -n -i 'shell language server\|bash language' README.md` returns nothing: the absence is neither stated nor justified anywhere.

For completeness, the rest of the matrix is coherent. Lua: `lua-language-server` + `stylua` (with `stylua.toml` tracked) + `bash`/`lua` parsers. C#: `roslyn` via `roslyn.nvim` (`dotnet.lua:32-35`), `netcoredbg` DAP via EasyDotnet (`dotnet.lua:72-79`), `c_sharp` parser added at `dotnet.lua:43-46`, formatter `csharpier` deliberately project-owned (README.md:33, README.md:3631). OCaml: entirely opam-owned and gated on `vim.fn.executable("opam") == 1` (`ocaml.lua:1`), with `mason = false` on `ocamllsp` (`ocaml.lua:29`) and the earlybird DAP adapter at `:59-63`. Python, TypeScript/Angular, JSON, YAML, Markdown, LaTeX all have LSP plus formatter or DAP as documented. The one other hole is TOML: `grep -rn 'taplo\|lang.toml' .` returns nothing, so the repo's own `mise/.config/mise/config.toml`, `stylua.toml`, `aerospace.toml` and Starship theme TOMLs get the Treesitter parser and no language server.

**Problem.** The editor is configured for every language the author writes except the one the repository is written in. Editing any of the 143 tracked shell scripts in the repo's own Neovim gives no hover, no go-to-definition, no rename, and - despite ShellCheck being installed on Fedora and macOS - no diagnostics until the author separately runs `scripts/lint.sh`. Nothing in the README records this as a decision, so it reads as an oversight rather than the deliberate exclusions the README documents elsewhere.

**Fix.** Wire up the shell tooling that is already installed, keeping ShellCheck native rather than Mason-owned so design principle 1 holds.

1. Create `nvim-lazyvim/.config/nvim/lua/plugins/shell.lua`, following the shape of the existing `ocaml.lua`:
   - A `neovim/nvim-lspconfig` fragment with `optional = true` and an `opts` function setting `opts.servers.bashls = {}`. Add `bash-language-server` to `nvim-lazyvim/.config/nvim/mason-packages.txt` in sorted position (between `angular-language-server` and `debugpy`) so Mason owns the editor-only server, consistent with how `pyright` and `vtsls` are handled.
   - An `mfussenegger/nvim-lint` fragment with `optional = true` whose `opts` function sets `opts.linters_by_ft.sh = { "shellcheck" }` and `opts.linters_by_ft.bash = { "shellcheck" }`. Do NOT add `shellcheck` to `mason-packages.txt`: it is DNF-owned on Fedora and Brew-owned on macOS, and `tests/test-neovim-tool-ownership.sh:92` and `platforms/macos/scripts/verify.sh:95` already assert those. Guard the fragment on `vim.fn.executable("shellcheck") == 1`, the same pattern `ocaml.lua:1` uses for opam, so the Parrot guest and any host without ShellCheck stay inert.
2. Do not enable `lazyvim.plugins.extras.util.dot` to get this: it would also pull `shellcheck` into Mason's `ensure_installed` (its `:22`), creating the second owner that README.md:2850-2853 explicitly warns against.
3. Consider `taplo` for TOML in the same file if you want the config-file gap closed; it is Mason-appropriate and would need a `mason-packages.txt` entry plus `opts.servers.taplo = {}`.
4. Update the Mason table in README.md around 2822-2842 with the new `bash-language-server` row ("Declared by: `lua/plugins/shell.lua`"), and add a sentence stating that ShellCheck stays native package-manager-owned and is reached through `nvim-lint` rather than Mason. Add a `### Shell` subsection to `docs/keybindings.md` after the LaTeX section at 154-178 noting that `]d`/`[d` and `<leader>xx` now surface ShellCheck findings in `.sh` buffers.

**Acceptance.** Add to `tests/test-neovim-tool-ownership.sh`: `assert_contains` for `opts.servers.bashls` and `linters_by_ft.sh = { "shellcheck" }` and `vim.fn.executable("shellcheck") == 1` in the new `nvim-lazyvim/.config/nvim/lua/plugins/shell.lua`; extend the `expected_mason_packages` array at lines 97-114 with `bash-language-server` (the array is compared for exact equality at line 116, so this must be updated in lockstep); and add `shellcheck` to the `project_tools` style negative check so it can never appear in `mason-packages.txt`. Add a lua assertion to `tests/test-neovim-first-launch.lua` that `dofile`ing `shell.lua` with `vim.fn.executable` stubbed to return 0 leaves `linters_by_ft` untouched. Manually: open `common/install-neovim-tools.sh` in Neovim, confirm `K` shows hover from bash-language-server and that a deliberate `$foo` unquoted-expansion produces an SC2086 diagnostic in `<leader>xx`.

### nvim-08: Every Neovim test is a textual grep; nothing resolves the config through lazy.nvim, which is why the init collision is invisible
*medium, testing. single-source.*

**Locations.** `tests/test-neovim-tool-ownership.sh:12`, `tests/test-neovim-first-launch.lua:10`, `tests/test-markdown-workflow.sh:12`, `tests/test-latex-profile.sh:6`, `tests/test-neovim-bootstrap.sh:12`

**Evidence.** The editor test suite never constructs the merged plugin spec, so no test can observe how lazy.nvim actually combines fragments - which is exactly the class of bug in nvim-01.

`tests/test-neovim-tool-ownership.sh:12-18` defines `assert_contains() { grep -Fq -- "$value" "$file"; }` and then makes ~60 such assertions on literal source strings: `assert_contains "$dotnet_config" 'lsp = {'`, `assert_contains "$ocaml_config" 'mason = false'`, `assert_contains "$formatting_config" 'cs = { "csharpier" }'`. `tests/test-markdown-workflow.sh:12-17` and `tests/test-latex-profile.sh` use an identical helper. These assert that text exists in a file, not that the resulting configuration has any particular value.

`tests/test-neovim-first-launch.lua` gets closer - it `dofile`s individual plugin files and invokes single `opts` functions with hand-built tables (`:52` `markdown_mason.opts(nil, markdown_mason_opts)`, `:72` `mason_plugins[1].opts(nil, mason_opts)`) - but it examines one file at a time in isolation. It never loads lazy.nvim, never parses a spec list, and therefore never exercises fragment merging, so it cannot see that three files claim `init` on `LazyVim/LazyVim` and only one survives. It also never loads the platform overlays at all: `grep -rn 'nvim-wsl\|nvim-macos' tests/` shows the overlays are referenced only by `tests/test-macos.sh:171-182`, `tests/test-fedora-wsl.sh:289-293` and `tests/test-latex-profile.sh:7`, every one of them a `grep`/`assert_contains` on file text or a stow-package-name check.

`tests/test-neovim-bootstrap.sh` does run a real process, but it is a mock: `:12-31` writes a fake `nvim` shell script that logs its arguments and `mkdir -p`s package directories. It validates the installer's control flow well (convergence, the exit-23 failure path at `:64-77`, the timeout path at `:79-91`) and nothing about the config.

A working harness is straightforward - I built one for this audit. Stow the base package plus one overlay into a temp HOME with `stow --no-folding`, prepend a lazy.nvim checkout to the rtp, then use lazy's own API: `require("lazy.core.plugin").Spec.new()`, `spec:parse(...)`, `require("lazy.core.plugin").values(plugin, "opts", false)`. `require("lazy.core.util").ls(dir, fn)` enumerates the plugin directory the same way lazy does. That harness reported `FocusGained autocmds registered: 1` for the base tree and `0` for both overlay trees - the finding in nvim-01 - in a single assertion.

**Problem.** Textual assertions cannot detect semantic breakage from spec merging, and spec merging is where this configuration's genuine complexity lives: three files contribute fragments to `LazyVim/LazyVim`, four contribute to `mason-org/mason.nvim`, and two platform overlays are injected into the same import directory. The suite is therefore blind to the whole category of defect that the overlay design makes likely, and blind to a related fragility: lazy discovers plugin modules with `vim.uv.fs_scandir` (`lazy/core/util.lua` `M.ls`) and does not sort, so the merge order of `markdown.lua`'s Mason filter versus `mason.lua`'s Mason additions is filesystem-dependent and untested. (I verified the current outcome is in fact correct - the filter removes `markdown-toc` and `markdownlint-cli2`, which `mason.lua` never adds, so it is order-insensitive - but nothing asserts that it stays so.)

**Fix.** Add one spec-resolution harness and reuse it for the assertions the grep tests cannot make.

1. Add `tests/lib/nvim-spec.sh` exposing `build_stowed_tree <dest> [overlay-package...]`: `stow --dir="$repo_root" --target="$dest" --restow --no-folding nvim-lazyvim` followed by `stow --dir="$repo_root/platforms/<p>/stow" --target="$dest" --restow --no-folding <overlay>` for each argument, mirroring `common/stow.sh:53-60` and `platforms/macos/scripts/stow.sh:14-20` exactly so the test exercises the real flags.
2. Add `tests/test-neovim-spec.lua`, run as `nvim --headless -u NONE -l tests/test-neovim-spec.lua`, which takes the tree path and a lazy.nvim path from the environment, does `vim.opt.rtp:prepend(lazypath)`, `require("lazy.core.config").setup({ spec = {}, install = { missing = false }, checker = { enabled = false } })`, enumerates `<tree>/.config/nvim/lua/plugins` with `require("lazy.core.util").ls`, `spec:parse()`s each file's return value, and then asserts on the resolved plugins. Initial assertions: (a) running every resolved `init` leaves at least one `FocusGained` autocmd registered, for the base tree and for both overlay trees; (b) `Plugin.values(spec.plugins["mason.nvim"], "opts", false).ensure_installed` contains all 16 entries of `mason-packages.txt` plus `roslyn`/`netcoredbg` and contains neither `markdown-toc` nor `markdownlint-cli2`, independent of import order - assert this twice, once with the files parsed in `Util.ls` order and once in reverse, to pin the order-insensitivity; (c) `vim.g.vimtex_view_general_viewer` resolves to `open` for the macOS tree and `wsl-open` for the WSL tree, with vimtex's and LazyVim's inits run in both orders.
3. Source lazy.nvim for the test the same way the config does: check for `$XDG_DATA_HOME/nvim/lazy/lazy.nvim` and skip with a clear message when absent, so `scripts/test.sh` stays runnable in the `fedora:44` CI container without network. Note the container's Neovim must satisfy the floor from nvim-02 for LazyVim's own extras to parse; assert only on the repo's own `lua/plugins/*.lua` fragments, which need no LazyVim present (I confirmed they parse against bare lazy.nvim with `_G.LazyVim` stubbed to supply `get_pkg_path`, exactly as `tests/test-neovim-first-launch.lua:3-8` already stubs it).
4. Register the new test in `scripts/test.sh` alongside the existing 32, and fix the separate known defect while you are in that file: `tests/test-neovim-tool-ownership.sh:54-56` runs the first-launch lua test as `-c 'lua dofile(...)'`, which exits 0 even on a lua error, so that test currently cannot fail. Change it to the `-l` form already used correctly on line 58: `nvim --headless -u NONE -i NONE -l tests/test-neovim-first-launch.lua`.
5. Update the README's testing section to describe the new harness as the place where cross-file spec behaviour and platform overlays are asserted, so future overlays get an assertion rather than another `grep`.

**Acceptance.** `bash scripts/test.sh` runs `tests/test-neovim-spec.lua` and it passes. Prove each assertion bites: temporarily re-add `init = function() end` to the `LazyVim/LazyVim` spec in `nvim-lazyvim/.config/nvim/lua/plugins/colorscheme.lua` and confirm the macOS and WSL FocusGained assertions fail; temporarily add `markdown-toc` to `mason-packages.txt` and confirm the Mason assertion fails in both orderings. Prove the `-l` fix bites: add `error("boom")` to the top of `tests/test-neovim-first-launch.lua` and confirm `tests/test-neovim-tool-ownership.sh` now exits non-zero, where before the fix it exited 0.

### nvim-09: EasyDotnet's C# test bindings shadow LazyVim's neotest defaults but are absent from docs/keybindings.md, whose Neovim section claims the bindings listed are LazyVim's own
*low, documentation. single-source.*

**Locations.** `docs/keybindings.md:103`, `nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua:98`, `README.md:3603`

**Evidence.** `docs/keybindings.md:103-107`, opening the "LazyVim / Neovim" section, states: "`nvim-lazyvim/.config/nvim/lua/config/keymaps.lua` adds no repository keymaps of its own; the bindings below are LazyVim's own defaults (verified against the pinned LazyVim commit in `lazy-lock.json`), which is why `Space` + WhichKey is the primary way to discover the rest." The first clause is literally true - `lua/config/keymaps.lua` is three comment lines and nothing else.

But plugin specs do rebind LazyVim defaults. `nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua:97-113` replaces the `test.core` extra's neotest bindings inside C# buffers:
    -- Preserve LazyVim's normal test semantics in C# buffers.
    mappings = {
      run_test_from_buffer = { lhs = "<leader>tr", desc = "Run Nearest" },
      run_all_tests_from_buffer = { lhs = "<leader>tt", desc = "Run File" },
      debug_test_from_buffer = { lhs = "<leader>td", desc = "Debug Nearest" },
    },
`lazyvim.json:11` enables `lazyvim.plugins.extras.test.core`, which owns those same three lhs values, and `dotnet.lua:88` sets `neotest_integration = false`, so in a `.cs` buffer these keys drive EasyDotnet's runner rather than neotest.

README.md:3603-3607 does document them, in a fenced block under the EasyDotnet section:
    <leader>tr    Run Nearest
    <leader>tt    Run File
    <leader>td    Debug Nearest
So the information exists - it is only missing from the file that presents itself as the keyboard reference. `grep -n '^##' docs/keybindings.md` lists Ghostty, Zsh, fzf, zoxide, tmux, LazyVim / Neovim, Markdown, LaTeX, Lazygit, Theme command, Profile cheat sheets: there is no C#/.NET subsection, even though Markdown (`:132`) and LaTeX (`:154`) both get one for exactly this purpose. The Neovim table at `:110-127` lists no `<leader>t*` binding at all, so a reader is not misled about a specific key - but the section's framing ("the bindings below are LazyVim's own defaults") does not survive contact with `dotnet.lua`.

**Problem.** The keyboard reference asserts that the repository adds no keymaps, on the strength of `keymaps.lua` being empty, while a plugin spec rebinds three LazyVim test bindings in C# buffers. A reader who trusts `docs/keybindings.md` will not learn that `<leader>tt` means something different in a `.cs` buffer than in a `.py` one, and the file's two comparable filetype subsections establish that per-language sections are the intended home for this.

**Fix.** Narrow the claim and add the missing subsection, matching the existing Markdown and LaTeX pattern.

1. In `docs/keybindings.md:103-107`, change the framing from "adds no repository keymaps of its own" to something accurate, e.g. "`lua/config/keymaps.lua` adds no repository keymaps of its own; the bindings below are LazyVim's own defaults (verified against the pinned LazyVim commit in `lazy-lock.json`). Individual plugin specs do rebind a few defaults per filetype - see the C#, Markdown and LaTeX subsections."
2. Add a `### C# / .NET` subsection after the Neovim table at `:127` and before `### Markdown` at `:132`, with the three-column table style used by the LaTeX section: `<leader>tr` Run Nearest, `<leader>tt` Run File, `<leader>td` Debug Nearest, each noting "EasyDotnet's runner in `cs` buffers, replacing neotest (`neotest_integration = false`)". Include `:Dotnet` (the `cmd` declared at `dotnet.lua:59`) and a line that the test explorer opens in a 45-column right vsplit (`dotnet.lua:94-95`), then cross-reference the README's EasyDotnet section at 3575-3624 the way the LaTeX subsection cross-references the README at `docs/keybindings.md:179-180`.
3. While editing, add the `bash`/shell note if nvim-07 is implemented, so the per-filetype sections stay complete.

**Acceptance.** Add to `tests/test-neovim-tool-ownership.sh`, next to the existing `dotnet_config` assertions at lines 39-49, three `assert_contains "$repo_root/docs/keybindings.md"` checks for `<leader>tr`, `<leader>tt` and `<leader>td`, so the C# bindings cannot be changed in `dotnet.lua` without the reference being updated - mirroring how `tests/test-markdown-workflow.sh:24` already pins `insert_table = "<leader>mt"`. Also assert that `docs/keybindings.md` no longer contains the unqualified phrase `adds no repository keymaps of its own` followed by the old absolute claim. Run `bash scripts/test.sh` and confirm the new assertions fail against the current `docs/keybindings.md`.


**Auditor notes for this dimension.** PRIORITY QUESTION - ANSWERED EMPIRICALLY, AND THE ANSWER IS "YES, THEY LOAD".

Both `platforms/fedora-wsl/stow/nvim-wsl/.../plugins/wsl.lua` and `platforms/macos/stow/nvim-macos/.../plugins/macos.lua` are discovered and parsed by LazyVim. Three independent reasons, all verified by execution rather than reading:

1. `lua/config/lazy.lua:22` uses a DIRECTORY import, `{ import = "plugins" }`, not an explicit file list. lazy.nvim resolves that with `Util.lsmod("plugins", fn)`, which finds one root and enumerates every `*.lua` in it, explicitly accepting symlinks: `(type == "file" or type == "link") and name:sub(-4) == ".lua"`.
2. Stow's directory-folding hazard is real but avoided. Every stow call in the repo passes `--no-folding` (`common/stow.sh:60`, `platforms/macos/scripts/stow.sh:17`, `platforms/fedora-wsl/scripts/stow.sh:22`, `platforms/parrot-ctf/scripts/stow.sh:25`), so `~/.config/nvim/lua/plugins/` is a real directory of per-file symlinks and the overlay file drops in cleanly. I confirmed the counterfactual: stowing the base package WITHOUT `--no-folding` folds `.config` to a single symlink and the overlay then fails with `stow: existing target is not owned by stow: .config`, exit 1. The `--no-folding` flag is load-bearing for this design and is applied consistently.
3. Direct probe. I stowed each platform's real package set into a temporary HOME and ran lazy.nvim's own `Util.lsmod("plugins", ...)` against it. macOS tree returned 8 modules including `plugins.macos`; WSL tree returned 8 including `plugins.wsl`.

So the platform editor configuration is NOT inert. But resolving the merged spec turned up a different, real defect in the same area, which is finding nvim-01: `colorscheme.lua`, `macos.lua` and `wsl.lua` all declare `init` on the `LazyVim/LazyVim` plugin, lazy.nvim resolves `init` to the LAST fragment only (`lazy/core/meta.lua` `_rebuild` chains fragments with `__index`; `lazy/core/loader.lua:112` calls the single resolved `plugin.init`), and `macos`/`wsl` sort after `colorscheme`. Measured: FocusGained autocmds registered = 1 on the Fedora base tree, 0 on both overlay trees. The documented live theme reload (README.md:3050, README.md:4294) is dead on two platforms.

THINGS I SUSPECTED AND THE CODE DISPROVED - not reported as findings:

- VimTeX viewer override ordering. `docs/macos.md:128` claims the overlay sets the viewer "before that fallback runs", which is not how lazy sequences inits, so I expected a latent order bug. There is none: `latex.lua:16` guards with `if not vim.g.vimtex_view_general_viewer`, and running LazyVim's and vimtex's inits in both orders yields `viewer=open options=@pdf` (macOS) and `viewer=wsl-open options=@pdf` (WSL). The doc's mechanism description is loose; the behaviour is correct and order-independent.
- `opts` fragments colliding like `init` does. They do not. `Plugin.values` recurses the `__index` chain and threads the accumulator through each fragment, so `colorscheme.lua`'s `opts.colorscheme` function survives alongside `wsl.lua:27-44`'s clipboard function. Verified: resolved opts contains `colorscheme` on both overlay trees.
- WSL clipboard being set from `opts` rather than `init`. Works, and correctly guarded: `wsl.lua:28` early-returns unless `vim.fn.has("wsl") == 1`, which is why my probe on this non-WSL host reported `vim.g.clipboard set: false`. Clipboard per platform is otherwise sound - `wl-clipboard` is installed on Fedora (`platforms/fedora/scripts/install-system.sh:29`) and `wl-copy` verified (`platforms/fedora/scripts/verify.sh:88`); macOS relies on Neovim's built-in pbcopy provider and needs no config; WSL routes through the `wsl-copy`/`wsl-paste` shims in `platforms/fedora-wsl/stow/interop/.local/bin/`.
- Mason `ensure_installed` ordering between `markdown.lua`'s filter and `mason.lua`'s additions. lazy discovers plugin modules with unsorted `vim.uv.fs_scandir` (`Util.ls`), and `opts_extend` list-extension only applies to fragments declaring `opts` as a table, so I expected an order-dependent bug. There is none: `markdown.lua:13-15` filters only `markdown-toc` and `markdownlint-cli2`, which `mason.lua` never adds (they are absent from `mason-packages.txt`), so the outcome is order-insensitive. Nothing asserts it stays so - folded into nvim-08's fix rather than reported separately.
- `test-dev-workflows.sh --all` pulling in the LaTeX fixture on macOS, which would have broken `install.sh --platform macos --workflows`. It does not: `scripts/test-dev-workflows.sh:24` initialises `run_latex=false` and `:32` `--all) ;;` leaves it false. Only the explicit `--latex` invocation that `docs/macos.md:114` advertises fails there, which is finding nvim-04.
- `lazy-lock.json` being defeated by the installer. It is not. `common/install-neovim-tools.sh:59` runs `'+Lazy! restore'`, which is the correct pin-respecting command (`restore`, not `update`/`sync`), and `lazy.lua:36-39`'s `checker = { enabled = true, notify = false }` only checks for updates without applying them. The 48 pinned entries cover every plugin the nine enabled extras pull in. One genuine but minor gap I chose not to report: if all Mason packages already exist, `install-neovim-tools.sh` takes the `else` branch at `:74-76` and a failed `Lazy! restore` is only caught by nvim's exit status, which lazy does not set on per-plugin clone failures - the subsequent `mason_root` re-check at `:78-85` cannot see it. It is bounded by the fact that the first-run path does exercise `bootstrap-mason.lua`'s `assert` on the mason.nvim directory.
- Mason double-ownership of tools. Reconciled cleanly. `mason-packages.txt` is the single inventory; `config/mason.lua:3-19` is its only reader; `mason.lua:13-18` and `dotnet.lua:18-27` both append idempotently via `vim.tbl_contains` guards; `DOTFILES_MASON_BOOTSTRAP=1` correctly suppresses the async ensure loop in both (`mason.lua:8-11`, `dotnet.lua:14-16`) so the blocking headless `MasonInstall` cannot race it; OCaml is held out of Mason entirely (`ocaml.lua:29` `mason = false`, asserted at `tests/test-neovim-tool-ownership.sh:143-146`). Ownership order is: `install-neovim-tools.sh` phase 1 restores plugins, phase 2 runs a blocking `MasonInstall` for missing packages only, and interactive launches then converge via `ensure_installed`. Failure IS visible on the provisioning path (`:83-85` `die "Mason provisioning incomplete; missing: ..."`), which is why nvim-05 is scoped to Parrot, the one platform that never runs it.

ONE PRE-ESTABLISHED FACT CONFIRMED AND FOLDED IN: `tests/test-neovim-tool-ownership.sh:54-56` runs the first-launch lua test via `-c 'lua dofile(...)'` and so cannot fail. I did not report it as its own finding since it was given to me as established; the one-line fix (use the `-l` form already correct on line 58) is written into nvim-08's fix and acceptance.

HARNESS CAVEAT, stated so nothing here is over-claimed. This container has Neovim 0.9.5, below the pinned LazyVim 16.0.0's 0.11.2 floor. Every empirical claim above was made against bare lazy.nvim with the repo's own `lua/plugins/*.lua` fragments and `_G.LazyVim` stubbed for `get_pkg_path` - a configuration that parses cleanly and is what the assertions depend on. I also attempted a full resolution with real LazyVim plus all nine extras; that run produced obvious garbage (`stylua` and `oxfmt` appearing as LSP *servers*, a 17th Mason package) because LazyVim's `Config.spec` is not initialised outside a real `lazy.setup`, so `has_extra` errored and its defaults registry mis-populated. I discarded that run entirely and derived the language-completeness matrix in nvim-07 by reading LazyVim's extras at the pinned commit `c10948c5` instead. The Neovim floor itself is finding nvim-02, and it is the reason a CI-runnable version of the nvim-08 harness must assert only on the repo's own fragments.


## README accuracy and repository hygiene

### readme-verify-not-platform-scoped: README's generic 'Verification' instructions always run the Fedora-only verifier, unscoped for macOS/WSL/Parrot
*high, correctness. verified by a second agent.*

**Locations.** `README.md:4134-4139`, `README.md:4407-4409`, `scripts/verify.sh:1-5`, `platforms/fedora/scripts/verify.sh:1-10`

**Evidence.** README.md's top-level '# Verification' section (line 4134) says only 'Run: ./scripts/verify.sh' with no platform qualifier, then lists checks that are explicitly Fedora-specific (SELinux/firewalld/Secure Boot, Mason, 'optional ASUS hardware profile', 'optional Fedora VM-host backend', 'optional Fedora security-hardening profile'). The generic '# Manual post-install checklist' (line 4388) repeats the same bare instruction at step 8 (line 4407-4409): 'Run: ./scripts/verify.sh'. Neither passage says 'Fedora only' or points macOS/WSL/Parrot users elsewhere. But scripts/verify.sh is a 5-line shim: `exec "$repo_root/platforms/fedora/scripts/verify.sh" "$@"` -- it always execs the Fedora verifier, regardless of which platform's install.sh the user actually ran. platforms/fedora/scripts/verify.sh in turn calls Fedora-only checks (SELinux, firewalld, DNF/Mason ownership, hardware) with no platform guard. macOS and Parrot each have their own dedicated verifiers that ARE correctly referenced elsewhere in README (docs/macos.md:417 'platforms/macos/scripts/verify.sh --defaults'; README.md:935 './platforms/parrot-ctf/scripts/verify.sh'; README's own WSL 'Validation' subsection at line 825 avoids the bare './scripts/verify.sh' call), so the bug is specifically that these two generic, platform-agnostic-looking sections point every reader at the Fedora shim.

**Problem.** A user who installed on macOS, Fedora WSL, or the Parrot CTF guest and follows the README's own 'Verification' section or 'Manual post-install checklist' literally will run the Fedora verifier against a non-Fedora machine: it checks for SELinux/firewalld/DNF/KDE-specific state that doesn't apply, producing spurious failures (or in the macOS case, running under a possibly-incompatible bash) instead of validating what was actually installed. This directly contradicts the two correctly-scoped references to platform-specific verifiers elsewhere in the same document.

**Fix.** In README.md, qualify both instances: at line 4134-4139 rename or annotate the section as Fedora/Fedora-WSL-specific and add a short 'On macOS, run platforms/macos/scripts/verify.sh (see docs/macos.md); on the Parrot CTF guest, run ./platforms/parrot-ctf/scripts/verify.sh' branch; do the same at the step-8 instruction in 'Manual post-install checklist' (line 4407-4409). Optionally also harden scripts/verify.sh itself to detect the installed platform (e.g. read the same platform marker install.sh / setup-local.sh records) and dispatch to the matching platforms/<platform>/scripts/verify.sh instead of hard-coding fedora, mirroring how scripts/*.sh shims already exec into platform scripts elsewhere.

**Acceptance.** Add a tests/test-installer-options.sh (or a new tests/test-verify-dispatch.sh) case that fakes a non-Fedora platform marker and asserts scripts/verify.sh either refuses with a clear platform-mismatch message or dispatches to the correct platforms/<platform>/scripts/verify.sh, not silently to Fedora's. Manually confirm the README wording change by grepping README.md for './scripts/verify.sh' and checking each occurrence carries a platform caveat.

**Verifier note.** Verified directly. README.md:4136-4139 ('# Verification') says only 'Run: ./scripts/verify.sh' with no platform qualifier, then the bulleted list at 4143-4165 names checks that are Fedora-only in substance (SELinux/firewalld/Secure Boot always, ASUS hardware, Fedora VM-host/guest, Fedora security-hardening). scripts/verify.sh is exactly the 5-line unconditional shim quoted: it always execs platforms/fedora/scripts/verify.sh. Confirmed fedora-wsl has its own materially different verify.sh (450 lines, different flags --smoke-test/--latex, different helper functions like check_linux_command/is_windows_path) that the shim never reaches - so the bug affects WSL too, not just macOS/Parrot. The step-8 'Manual post-install checklist' at README.md:4405-4409 repeats the same bare command, in a checklist whose other steps (6: ASUS hardware, 7: Sway) are also Fedora-specific without being labeled as such. Correctly-scoped counterexamples the finding cites do exist: docs/macos.md:417 ('platforms/macos/scripts/verify.sh --defaults') and README.md:935 ('./platforms/parrot-ctf/scripts/verify.sh') confirmed present.

### readme-kde-auto-default-undocumented: The --kde/--no-kde default is 'auto-detect Plasma', never mentioned in README's Installer options
*medium, documentation. verified by a second agent.*

**Locations.** `README.md:231-260`, `platforms/fedora/install.sh:8`, `platforms/fedora/install.sh:379-384`, `platforms/fedora/install.sh:641-646`

**Evidence.** README.md's 'Installer options' block (lines 236-240) documents only: '--kde  install Catppuccin KDE integration' / '--no-kde  skip KDE integration', with no stated default -- unlike every other boolean pair in the same block, which explicitly states '(default)' (e.g. '--no-ocaml  skip the OCaml profile (default)', '--no-sway  skip Sway (default)'). In the actual parser, platforms/fedora/install.sh:8 sets `install_kde="auto"`, and lines 379-384 resolve it before any prompt is shown: `if [[ "$install_kde" == "auto" ]]; then if command_exists plasmashell; then install_kde="true"; else install_kde="false"; fi; fi`. The interactive confirmation flow (lines 641-646) only *displays* the already-resolved value ('KDE integration: %s') -- it never prompts the user to choose, unlike LaTeX which gets an explicit `confirm` call a few lines later.

**Problem.** Running `./install.sh` (the README's own documented 'Install using the defaults' quick-start command) or any --non-interactive invocation that omits both --kde and --no-kde silently installs or skips Catppuccin KDE integration depending on whether plasmashell happens to already be on PATH -- a detail no other part of the option-parsing README section warns about. On a minimal/Server/Everything Fedora install without Plasma pre-installed, or in an automated/CI-style non-interactive run, the outcome differs from a normal Fedora KDE spin with no way to predict it from the docs, and the interactive flow gives the user no chance to change it since (unlike --latex) there is no confirm prompt.

**Fix.** In README.md's Installer options block (around line 239), change the --kde/--no-kde description to state the real default explicitly, e.g. '--kde  install Catppuccin KDE integration (default: auto-detected via `command -v plasmashell`)' / '--no-kde  skip KDE integration'. Also add one sentence in the 'Installer options' preamble or the Quick Start noting that omitting both flags does not mean 'off' the way it does for --sway/--ocaml/--hardening -- it auto-detects the current desktop.

**Acceptance.** Add a case to tests/test-installer-options.sh that runs the fedora installer --dry-run with neither --kde nor --no-kde, once with a mocked `plasmashell` on PATH and once without, and asserts the printed 'KDE integration:' line differs accordingly -- proving current behavior -- then check the corresponding README wording change is present.

**Verifier note.** Verified directly. README.md's Installer options block (lines 231-260) lists '--kde' / '--no-kde' with no '(default)' annotation, unlike every other boolean pair in the same block (e.g. '--no-ocaml ... (default)', '--no-sway ... (default)', '--no-hardening ... (default)'). platforms/fedora/install.sh:8 sets install_kde="auto"; lines 379-384 resolve it via `command_exists plasmashell` before any dry-run/interactive display, exactly as quoted. The interactive block (600-646) only prints 'KDE integration: %s' - it never calls confirm() for KDE the way it does for LaTeX ('if confirm "Install LaTeX toolchain?"'). README's 'Current defaults' section (line 4440-4459) also never mentions KDE integration or its auto-detected default, so there is genuinely no place in the document that explains this. The finding's claim that plain `./install.sh` is the README's own documented default-install command is also verified verbatim at README.md:118-120 ('Install using the defaults: ./install.sh').

### readme-dnf-package-list-inaccurate: README's Fedora/DNF package-ownership lists omit shadow-utils, misname fd-find, and double-count xdg-utils as a desktop-tools addition
*medium, correctness. verified by a second agent.*

**Locations.** `README.md:2649-2670`, `README.md:2653`, `README.md:1727-1736`, `README.md:2690-2691`, `platforms/fedora/scripts/install-system.sh:10-33`, `platforms/fedora/scripts/install-desktop-tools.sh:22-27`

**Evidence.** platforms/fedora/scripts/install-system.sh:10-33 installs this exact `packages=(...)` array unconditionally on every Fedora install: bat, curl, eza, fd-find, fzf, gh, git, git-delta, libicu, neovim, openssh-clients, ripgrep, ShellCheck, shadow-utils, sqlite, sqlite-devel, stow, tmux, wl-clipboard, xdg-utils, zoxide, zsh, zsh-autosuggestions, zsh-syntax-highlighting. README.md's 'Fedora / DNF' baseline list (lines 2649-2670) reproduces every DNF package name verbatim except: (a) line 2653 says `fd` where the real DNF package is `fd-find` (every other entry in that list, e.g. `git-delta`, `ShellCheck`, is the literal package name, not the binary name, so this one is inconsistent); (b) `shadow-utils` (needed by `ensure_zsh_login_shell`'s chsh/usermod calls, install-system.sh:35) is missing from the list entirely. Separately, README.md lists `xdg-utils` twice as something the OPTIONAL desktop-tools profile 'adds' -- 'Package ownership: ... xdg-utils' at line 1736, and 'The optional desktop-tools profile adds `gimp`, `pdfarranger`, `skanpage`, and `xdg-utils`' at lines 2690-2691 -- but xdg-utils is already unconditionally installed by the baseline (install-system.sh:30) for every Fedora install, before any optional profile runs; install-desktop-tools.sh:27 reinstalls it a second, redundant (harmlessly idempotent) time only because that script is also runnable standalone.

**Problem.** A reader relying on the Fedora/DNF baseline list to know what a bare Fedora install puts on the system gets it wrong in three ways: it prints 'fd' where the actual DNF package is 'fd-find'; it omits 'shadow-utils' (needed by ensure_zsh_login_shell's usermod call) entirely; and it also omits 'xdg-utils' even though install-system.sh installs it unconditionally - while the desktop-tools profile section separately (and misleadingly) claims xdg-utils as one of that optional profile's own additions.

**Fix.** In README.md's Fedora/DNF baseline block (2646-2668): change 'fd' to 'fd-find', and add both 'shadow-utils' and 'xdg-utils' (the latter is already unconditionally installed by install-system.sh, so listing it only under --desktop-tools is wrong). In the desktop-tools section (1727-1736, 2690-2691), either drop xdg-utils from 'adds' and note it is baseline-installed already and merely re-asserted defensively by install-desktop-tools.sh for its standalone-run case, or keep it but add that one-line clarification.

**Acceptance.** Add a repo-hygiene check (e.g. in scripts/lint.sh or a small new tests/test-readme-package-lists.sh) that extracts the packages=() array from platforms/fedora/scripts/install-system.sh and the fenced ```text block under README's '## Fedora / DNF' heading and asserts set equality; run it and confirm it currently fails on `fd` vs `fd-find` and the missing `shadow-utils`, then passes after the fix.

**Verifier note.** fd-vs-fd-find and missing shadow-utils are both verified exactly: platforms/fedora/scripts/install-system.sh:10-33 installs 'fd-find' and 'shadow-utils' unconditionally; README.md's fenced Fedora/DNF block has 'fd' at line 2653 (confirmed by direct line lookup) and no 'shadow-utils' entry anywhere in that block. shadow-utils is indeed load-bearing: common/lib/common.sh:117-135 ensure_zsh_login_shell() calls `sudo usermod --shell`, which is the shadow-utils package. The xdg-utils claim is real but its framing overstates the bug: xdg-utils is NOT actually double-counted as a baseline+addition in the DNF baseline block itself (README's baseline fenced list at 2646-2668 in fact omits xdg-utils entirely, even though install-system.sh installs it unconditionally at line 30 - so the baseline list is inaccurate in the opposite direction than the finding states). The real, verified problem is narrower: README's desktop-tools 'Package ownership' list (1727-1736) and prose (2690-2691) present xdg-utils as one of the profile's four 'deliberate additions' (mirroring install-desktop-tools.sh:22-27's own added_packages array and comment), without noting it is already unconditionally installed by the Fedora baseline before that optional profile ever runs - so a reader is led to believe xdg-utils is exclusive to --desktop-tools. That inaccuracy is real; 'listed twice' is not itself the bug (repeating a package name in a table and in prose about the same profile is normal), and the finding should also flag that the baseline block is separately missing xdg-utils outright.

### readme-theme-hooks-contract-undocumented: The theme-hooks.d extensibility mechanism used by two platforms is never documented as a contract
*medium, documentation. verified by a second agent.*

**Locations.** `bin/.local/bin/theme:84-91`, `platforms/fedora/stow/theme-hooks/.config/dotfiles/theme-hooks.d/fedora.sh`, `platforms/fedora-wsl/stow/theme-hooks/.config/dotfiles/theme-hooks.d/fedora-wsl.sh`, `README.md:2922`

**Evidence.** bin/.local/bin/theme (the portable `theme` command every platform stows) contains a real, working plugin mechanism at lines 84-91: after writing theme state and reloading tmux, it does `hook_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/theme-hooks.d"; for hook in "$hook_dir"/*.sh; do [[ -r "$hook" ]] || continue; source "$hook"; done`, with the comment 'Platform hooks may add desktop integration without putting platform checks in the portable command itself.' Two platforms already populate this directory via their own Stow packages: platforms/fedora/stow/theme-hooks/.config/dotfiles/theme-hooks.d/fedora.sh and platforms/fedora-wsl/stow/theme-hooks/.config/dotfiles/theme-hooks.d/fedora-wsl.sh. README.md's only acknowledgment of this mechanism is a single tree-comment line in the 'GNU Stow layout' section: 'theme-hooks/    # Fedora desktop response to `theme`' (line 2922) -- it never explains the directory convention, that files are `source`d (not exec'd, so they share the caller's shell state including `$flavour`/`$preserve_wallpaper`), the naming/ordering of hooks, or that this is the intended integration point for a new platform or desktop session (e.g. Sway, or a future macOS AeroSpace hook).

**Problem.** A contributor wanting to add theme integration for a new platform (e.g. a future macOS AeroSpace hook) has no documented interface to follow and must reverse-engineer it by reading bin/.local/bin/theme and the two existing platform hook implementations.

**Fix.** Add a short subsection (e.g. under 'Catppuccin theming' or 'GNU Stow layout' in README.md) titled something like 'Theme hook contract' that documents: the hook directory `~/.config/dotfiles/theme-hooks.d/*.sh`; that files are sourced (not executed) in glob order after `write_theme_state` and the tmux reload, so a hook can read `$flavour`/`$preserve_wallpaper` and any function from common/lib/theme-state.sh; that a new platform or session (e.g. Sway) adds one file via its own Stow package rather than editing bin/.local/bin/theme; and point at platforms/fedora/stow/theme-hooks/.config/dotfiles/theme-hooks.d/fedora.sh as the reference implementation.

**Acceptance.** No code change required; verify the fix by confirming a new README subsection exists that names the `theme-hooks.d` directory, the sourcing behavior, and the in-scope variables, and that it's discoverable from the table of contents/heading grep (`grep -n theme-hook README.md`) with more than the current single tree-comment line.

**Verifier note.** Verified directly. bin/.local/bin/theme:85-91 contains exactly the quoted hook-sourcing loop with the 'Platform hooks may add desktop integration...' comment. platforms/fedora/stow/theme-hooks/.config/dotfiles/theme-hooks.d/fedora.sh and platforms/fedora-wsl/.../fedora-wsl.sh both exist and are sourced (not exec'd) hooks that read $flavour/$preserve_wallpaper, confirming the sourcing/variable-sharing contract described. `grep -in theme-hook README.md` returns exactly one hit, the tree-comment at line 2922 ('theme-hooks/    # Fedora desktop response to theme') - no prose subsection documents the directory, sourcing semantics, or extension contract anywhere in the 4462-line document. One correction: the finding's claim that 'Sway...currently has no theme-hooks.d entry of its own' overstates the gap - fedora.sh's existing hook already contains full Sway-session handling (sway_session_active detection, waybar/mako/swaymsg reload) inline, so Sway does not need and was never meant to get a separate hook file; only a genuinely new platform/session (e.g. a future macOS AeroSpace hook) would need one.

### repo-hygiene-misc-gaps: Minor repo-hygiene gaps: no root LICENSE, a vestigial empty package-lock.json, and no .editorconfig/.shellcheckrc/root AGENTS.md
*low, hygiene. verified by a second agent.*

**Locations.** `package-lock.json:1-5`, `LICENSES/Catppuccin.txt:1`, `common/assets/AGENTS.md:1`

**Evidence.** The repo root has no LICENSE file; the only license text tracked is LICENSES/Catppuccin.txt, which is explicitly the MIT license for the *vendored Catppuccin wallpaper collection* (README.md:3168-3169: 'The exact upstream revision and license are recorded beside the assets and in `LICENSES/Catppuccin.txt`'), not a license for this repository's own ~27k lines of shell/lua/PowerShell. Separately, /package-lock.json is an 87-byte stub (`{"name": "dotfiles", "lockfileVersion": 3, "requires": true, "packages": {}}`) with no matching package.json anywhere in the repo and no script or CI step that references package-lock.json (confirmed by repo-wide grep); it appears to be a stray leftover. There is also no .editorconfig or .shellcheckrc despite 143 tracked shell files, and no root-level AGENTS.md/CLAUDE.md giving a contributing engineer or coding agent this repo's own build/lint/test conventions -- common/assets/AGENTS.md is a different thing (the user's personal, cross-machine agent instructions mirrored from a separate NixOS dotfiles repo and symlinked into installed AI tools, per README.md:2260-2270), not repo-contribution guidance.

**Problem.** None of these block a personal dotfiles workflow, but each is a small piece of avoidable clutter or friction for anyone else (or an AI agent) working in the repo: no LICENSE leaves the code's reuse terms undefined for a public GitHub repo; the orphaned package-lock.json is dead weight with no purpose; the missing .editorconfig/.shellcheckrc means any repo-wide shellcheck/style choices live only as scattered inline comments; and a contributor has no single canonical place (root AGENTS.md/CLAUDE.md) to find 'run ./scripts/lint.sh and ./scripts/test.sh before committing' short of reading all of README.md.

**Fix.** If reuse by others matters, add a root LICENSE (e.g. MIT, consistent with the vendored Catppuccin assets). Delete the orphaned package-lock.json (or, if something does depend on it, add the missing package.json and document what generates/consumes it). Optionally add a minimal .editorconfig (matching the repo's existing indentation conventions) and a .shellcheckrc capturing any repo-wide disables. Optionally add a short root AGENTS.md pointing at scripts/lint.sh, scripts/test.sh, and the README's 'Verification' section, distinct from common/assets/AGENTS.md.

**Acceptance.** None of these need a test; verify by `ls` at repo root showing the new LICENSE/.editorconfig/.shellcheckrc/AGENTS.md files (as applicable) and `git ls-files package-lock.json` returning nothing once removed (or a package.json present alongside it if kept).

**Verifier note.** All claims verified directly by listing/reading the files: no LICENSE at repo root (only LICENSES/Catppuccin.txt, which README.md:3168-3169 confirms is scoped to the vendored wallpaper collection's MIT license, not the repository). package-lock.json exists with exactly the quoted 87-byte stub content, no matching package.json exists anywhere outside tests/fixtures/angular-smoke/package.json (a test fixture, unrelated), and no reference to package-lock.json exists in any script/CI file. .editorconfig, .shellcheckrc, and a root AGENTS.md/CLAUDE.md are all confirmed absent. common/assets/AGENTS.md is confirmed to be the user's personal cross-machine agent instructions (README.md:2260-2270), not repo-contribution guidance, as the finding states. Effort/severity (low) is appropriate given all items are inert or optional polish with no functional impact.


## Cheat sheets and the macOS guide

### macos-latex-workflow-undocumented-prereq: docs/macos.md documents a LaTeX dev workflow that has no toolchain install path on macOS
*high, correctness. single-source.*

**Locations.** `docs/macos.md:113-131`, `platforms/macos/install.sh:18-64`, `platforms/macos/Brewfile`, `scripts/test-dev-workflows.sh:235-259`, `README.md:4005-4030`

**Evidence.** docs/macos.md section 4 lists `./scripts/test-dev-workflows.sh --latex` as one of four workflow commands to 'Run separately', then describes: 'LaTeX uses the shared VimTeX/texlab setup ... a small platforms/macos/stow/nvim-macos package overrides vimtex_view_general_viewer to macOS's native open'. `run_latex_workflow()` in scripts/test-dev-workflows.sh:235-239 does `require_command latexindent`, `require_command latexmk`, `require_command pdflatex` before doing anything else. `platforms/macos/install.sh` has no `--latex`/`--no-latex` flag at all (its full flag set is --theme/--ocaml/--containers/--tailscale/--defaults/--workflows/--dry-run/--non-interactive), `platforms/macos/Brewfile` contains no tex/mactex/basictex package, and `grep -rin 'mactex|basictex|texlive|pdflatex|latexmk|latexindent' platforms/macos/` returns zero matches. README.md's dedicated '# LaTeX' section (line 4005) only shows install commands for '# Native Fedora' and '# Fedora WSL' via `--latex`; macOS is never mentioned as an install target for the toolchain.

**Problem.** Following docs/macos.md exactly as written -- a fresh Apple Silicon install followed by `./scripts/test-dev-workflows.sh --latex` as the guide instructs -- fails immediately with 'latexindent not found' (or latexmk/pdflatex), because nothing in the macOS profile ever installs a TeX distribution. Unlike Fedora and Fedora WSL, which both expose an explicit `--latex` installer flag that runs `platforms/fedora/scripts/install-latex.sh` (dnf install texlive-scheme-medium latexmk biber ...), macOS has no equivalent flag, no Homebrew cask (e.g. `basictex`/`mactex-no-gui`), and no manual-install callout anywhere in docs/macos.md (contrast with section 1, which walks through installing Xcode Command Line Tools as an explicit 'Manual required' step). The nvim-macos VimTeX viewer override is real and correctly wired, but it configures PDF *viewing* only -- it does nothing for the missing compiler, so the feature this override was built to support cannot actually be exercised on macOS as documented.

**Fix.** Either (a) add a `--latex`/`--no-latex` flag to platforms/macos/install.sh mirroring platforms/fedora-wsl/install.sh's pattern, backed by a new platforms/macos/scripts/install-latex.sh that runs `brew install --cask basictex` (or mactex-no-gui) followed by `sudo tlmgr update --self && sudo tlmgr install latexmk latexindent biblatex biber collection-fontsrecommended` (BasicTeX ships a minimal package set), wire it into install.sh's step list and platforms/macos/scripts/verify.sh the same way Fedora WSL's verify.sh gains a `--latex` section; or (b) if automating a multi-GB TeX install via Homebrew cask is out of scope, add a 'Manual required' step in docs/macos.md section 4 before the LaTeX bullet, e.g. `brew install --cask basictex` plus the tlmgr package list above, and add a `command -v latexmk` guard with a clear error at the top of `run_latex_workflow()` in scripts/test-dev-workflows.sh pointing at that manual step. Either way, update README.md's '# LaTeX' section to mention macOS's path (or explicitly state LaTeX is Fedora/Fedora-WSL only and remove/qualify the macOS workflow doc accordingly) so the three documents agree.

**Acceptance.** Add a case to tests/test-dev-workflows.sh's own guard, or a new assertion in tests/test-macos.sh, that `platforms/macos/install.sh --help` output either contains `--latex` (if fixed via (a)) or that docs/macos.md's LaTeX bullet is preceded by an explicit manual-install code block containing `tlmgr install latexmk` (if fixed via (b)). Manually verify on a real Mac: run the documented steps from a clean shell with no TeX installed and confirm `./scripts/test-dev-workflows.sh --latex` either succeeds after the new install step or fails with the new guard's clear message instead of a raw 'command not found'.

### macos-md-eza-ripgrep-fd-zoxide-not-stowed: docs/macos.md misattributes eza/ripgrep/fd/zoxide as 'packages through Stow'
*medium, correctness. single-source.*

**Locations.** `docs/macos.md:59-60`, `common/stow.sh:28-38`, `zsh/.config/zsh/.zshrc:60,80-83`

**Evidence.** docs/macos.md:59-60 reads: 'reuses the common Zsh, Starship, Git, Ghostty, Neovim/LazyVim, tmux, fzf, bat, eza, ripgrep, fd, zoxide, mise, and Catppuccin packages through Stow'. common/stow.sh's `packages=(bat bin fzf git lazygit nvim-lazyvim starship tmux zsh)` (plus optional mise/ghostty) is the complete list of stow packages this repo defines anywhere -- there is no `eza/`, `ripgrep/`, `fd/`, or `zoxide/` top-level directory in the repository at all (confirmed by `find . -maxdepth 1 -type d`). Their only tracked footprint is plain aliases/eval lines inside the `zsh` package's `.zshrc` (`alias ls='eza'` at line 80, `eval "$(zoxide init zsh)"` at line 60); ripgrep and fd have no tracked configuration whatsoever, aliased or otherwise.

**Problem.** The sentence implies eza, ripgrep, fd, and zoxide are each Stow-managed configuration packages like Zsh/Starship/Ghostty, and that 'Catppuccin' is itself one of the 'packages'. In reality they are plain Homebrew binaries (declared once in platforms/macos/Brewfile) with no per-tool stow package, and Catppuccin is a theme applied across other tools' configs, not a package. A reader trying to find `platforms/macos/stow/eza` or a top-level `eza/` package (to see how it's configured, or to make a platform-specific tweak) will find nothing, because there is nothing to find.

**Fix.** In docs/macos.md, split the sentence into two clauses: one naming the actual Stow-managed dotfiles packages reused from `common/stow.sh` (Zsh, Starship, Git, Ghostty, Neovim/LazyVim, tmux, fzf, bat, mise), and a second naming eza/ripgrep/fd/zoxide as plain Homebrew-installed CLIs from platforms/macos/Brewfile with their only configuration being the aliases/`eval` lines already inside the shared `zsh` package -- and drop 'Catppuccin' from the packages list, folding it instead into the `theme` command description already given elsewhere in the same document.

**Acceptance.** No automated test currently checks doc-to-code stow-package claims; add a lightweight one to tests/test-macos.sh (or extend tests/test-cheatsheet-bindings.sh's pattern) that greps docs/macos.md's package-ownership sentence and asserts every named 'package' after 'through Stow' matches a directory that `common/stow.sh` or `platforms/macos/scripts/stow.sh` actually stows; run `./scripts/test.sh` to confirm it passes against the corrected wording.

### macos-tex-reload-binding-missing-from-canonical-table: AeroSpace's reload-config binding is documented in the cheat sheet but missing from its own cited canonical source
*medium, parity. single-source.*

**Locations.** `docs/cheatsheets/macos.tex:1-5,62-67`, `docs/macos.md:258-289`, `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml:76`

**Evidence.** docs/cheatsheets/macos.tex:3-4 states in its header comment: 'Source of truth: ... docs/macos.md section 6 ("the canonical macOS input for the cross-platform keybinding documentation tracked in issue #72")'. macos.tex:62-66 documents `Ctrl+Opt+Shift+C -> Close focused window` and `Ctrl+Opt+Shift+R -> Reload AeroSpace config` in its 'System' section, and this second row is load-bearing enough that tests/test-cheatsheet-bindings.sh:87,100 asserts both `ctrl-alt-shift-r = 'reload-config'` exists in aerospace.toml and the phrase 'Reload AeroSpace config' exists in macos.tex. But docs/macos.md's own binding table at lines 269-286 (the section macos.tex names as its 'source of truth' and 'canonical' input) has no row at all for reload-config -- its rows stop at 'move workspace | Control+Option+Command+Tab | Move workspace to next display' with no reload entry anywhere in section 6.

**Problem.** docs/macos.md section 6 claims to be the canonical, complete AeroSpace keybinding table that the cheat sheet is generated from, but the cheat sheet actually documents a binding (reload-config) that the 'canonical' table omits entirely. A reader who trusts docs/macos.md as complete (rather than opening the .tex or the raw aerospace.toml) will not know Ctrl+Opt+Shift+R exists.

**Fix.** Add a row to the table in docs/macos.md section 6 (around line 282, next to the Close-window row) for the reload binding, e.g. `| reload config | Control+Option+Shift+R | Reload AeroSpace config |`, matching the phrasing already used in docs/cheatsheets/macos.tex:65. While there, also check the layout-toggle key `ctrl-alt-e = 'layout tiles horizontal vertical'` in aerospace.toml:72 -- it is undocumented in both docs/macos.md and macos.tex and should be added or explicitly noted as intentionally omitted, for the same completeness reason.

**Acceptance.** Extend tests/test-cheatsheet-bindings.sh with a check mirroring its existing sway_tex/macos_tex phrase loop, but against docs/macos.md instead: `require_in "$repo_root/docs/macos.md" 'Reload AeroSpace config' "docs/macos.md"` (or an equivalent phrase), so a future binding added to macos.tex/aerospace.toml without a matching docs/macos.md row fails CI the same way an undocumented Sway binding already does.

### cheatsheets-no-ci-compile-check: No CI step ever compiles the untracked cheat-sheet PDFs, so a LaTeX-breaking edit passes CI silently
*medium, testing. single-source.*

**Locations.** `.github/workflows/validate.yml:1-93`, `docs/cheatsheets/README.md:43-50,54-62`, `docs/cheatsheets/generate.sh:23-27,40`

**Evidence.** docs/cheatsheets/README.md:43-48 states the PDFs are 'intentionally not committed' and 'regenerate byte-for-byte from the tracked .tex source', calling that source 'the source of truth'; README.md:54-62 explicitly says tests/test-cheatsheet-bindings.sh 'is deliberately not a LaTeX compile check ... it does not require a LaTeX toolchain to run as part of ./scripts/test.sh'. Reading the full .github/workflows/validate.yml (93 lines, 3 jobs: fedora:44 container running lint.sh+test.sh+whitespace check, windows-latest running test-windows-bootstrap.ps1, macos-26 running lint.sh+test-macos.sh+whitespace check) confirms none of the three jobs installs latexmk/TeX Live, runs `docs/cheatsheets/generate.sh`, or otherwise invokes a LaTeX engine anywhere.

**Problem.** Since the PDFs are deliberately untracked, the .tex/.sty source is the only artifact anyone can check, yet nothing in CI ever attempts to actually build it. A typo in a `\csrow`/`\cssection` macro call, an unbalanced brace, a missing `\end{cskeys}`, or a change to cheatsheet.sty that breaks one of the four sheets would pass lint.sh (it isn't shell), pass test.sh/test-cheatsheet-bindings.sh (pure grep against .tex source text, not compiled output), and merge to main with a permanently broken cheat sheet that nobody notices until someone runs `docs/cheatsheets/generate.sh` by hand.

**Fix.** Add a fourth job (or a step appended to the existing `repository` job, which already runs inside `container: fedora:44`) to .github/workflows/validate.yml that installs a TeX toolchain and runs the generator: `dnf --assumeyes --setopt=install_weak_deps=False install texlive-scheme-medium latexmk` (matching platforms/fedora/scripts/install-latex.sh's package list minus biber/texlive-biblatex/texlive-latexindent, which the four cheat sheets don't need per cheatsheet.sty:11-19's package list) followed by `./docs/cheatsheets/generate.sh`, then assert `git status --porcelain docs/cheatsheets/*.pdf` is empty (the PDFs must stay gitignored/untracked) and that generate.sh's own exit code is 0 (latexmk's `-halt-on-error` already makes it non-zero on any compile failure).

**Acceptance.** Add the step above to the `repository` job in .github/workflows/validate.yml; verify by intentionally introducing a LaTeX syntax error (e.g. an unmatched `\begin{cskeys}`) in a scratch branch and confirming the new CI step fails, then revert and confirm it passes. Document the added cost in docs/cheatsheets/README.md's 'Regenerating the PDFs' section: texlive-scheme-medium is roughly 300-600MB to install inside the Fedora container and the full four-sheet compile adds well under a minute, so the total CI time cost is dominated by the package install, not the compile.

### cheatsheet-structural-asymmetry: The four cheat sheets do not share a common section skeleton, and two of the four skip the page-break/second-title pattern the other two use for common-workflow
*low, maintainability. single-source.*

**Locations.** `docs/cheatsheets/fedora-kde.tex:14-29`, `docs/cheatsheets/fedora-sway.tex:15-110`, `docs/cheatsheets/fedora-wsl.tex:13-35`, `docs/cheatsheets/macos.tex:14-83`, `docs/cheatsheets/README.md:1-5`

**Evidence.** Section-by-section inventory (profile-specific sections only, before common-workflow): fedora-kde.tex has 'Desktop & keyboard layout', 'Theme'. fedora-sway.tex has 'Launch', 'Navigate', 'Move', 'Workspaces', 'Layout', 'Resize', 'System', 'Keyboard layout', 'Notifications', 'Screenshots & clipboard', 'Media & hardware'. fedora-wsl.tex has 'Windows / Linux boundary', 'Windows interop helpers', 'Noctty (if used as the Windows terminal)', 'Repository locations'. macos.tex has 'Launch', 'Navigate', 'Move', 'Workspaces', 'Layout', 'Resize', 'Displays', 'System', 'Clipboard & screenshots'. Additionally, fedora-sway.tex:105-108 and macos.tex:78-81 both do `\clearpage` + a second `\cssheettitle{... continued}` before `\input{common-workflow}`, while fedora-kde.tex:27 and fedora-wsl.tex:33 `\input{common-workflow}` directly inside the same `multicols` block as the profile content, with no page break or second title.

**Problem.** README.md's own stated goal (docs/cheatsheets/README.md:3-5) is that sheets are 'organized by task (Launch, Navigate, Move, Workspaces, ...) rather than config-file order, so it works as an actual desk reference' -- implying a comparable, diffable structure across profiles. In practice only Sway and macOS share the Launch/Navigate/Move/Workspaces/Layout/Resize/System skeleton (macOS additionally has Displays, for multi-monitor, which Sway lacks even though sway-workspace-grid/waybar could plausibly support one); KDE and WSL use an entirely different, non-overlapping vocabulary of sections since they don't own a tiling WM. A user switching between, say, Sway and macOS gets a genuinely comparable page; a user switching between Fedora KDE and Fedora Sway (the two most likely to be compared, both same-machine desktop choices) cannot mentally diff them at all, and the KDE/WSL sheets additionally render as a single unbroken page rather than the two-part 'profile + continued workflow' layout Sway/macOS use, so their PDF page count and visual shape differs from the other two for no documented reason.

**Fix.** Adopt a shared skeleton documented once in docs/cheatsheets/README.md: every sheet emits, in this fixed order, whichever of {Launch, Navigate, Move, Workspaces, Layout, Resize, System, Displays, Screenshots & clipboard} sections it has content for, followed by any profile-unique sections (KDE's keyboard-layout note, WSL's Windows-interop sections) under a clearly separated final block, then always `\clearpage` + `\cssheettitle{... continued}` before `\input{common-workflow}` so all four PDFs have the same two-part shape regardless of how much profile content precedes it. For KDE and WSL, this means explicitly stating (via a `\csnote`) which of the skeleton sections are N/A ('Workspaces: Plasma's own, see System Settings' / 'Workspaces: Windows owns window management') rather than silently omitting them, so the absence is a documented decision rather than an accident of authoring order.

**Acceptance.** No test currently enforces section ordering; add a check to tests/test-cheatsheet-bindings.sh that greps each of the four .tex files for `\clearpage` immediately preceding `\input{common-workflow}` and fails if any sheet's `\input{common-workflow}` is not preceded by `\clearpage` within the same file, then manually diff `docs/cheatsheets/README.md`'s documented skeleton against a `grep -o '\\cssection{[^}]*}' docs/cheatsheets/*.tex` listing to confirm every sheet uses only skeleton-approved section names plus its documented profile-unique exceptions.


## Windows host bootstrap and WSL

### win-1: A mistyped -FedoraDistribution name triggers a needless UAC elevation and WSL update before failing
*high, correctness. single-source.*

**Locations.** `platforms/windows/install.ps1:125-167`, `platforms/windows/install.ps1:624-639`, `platforms/windows/install.ps1:257-265`

**Evidence.** Resolve-FedoraDistribution (125-167): when -RequestedDistribution is set and not found in installed/online/web catalogues, it returns $null if -AllowUnavailable is set (140-142) instead of throwing. The top-level call at 624-626 always passes -AllowUnavailable. When the result is null, 637-638 unconditionally calls Invoke-ElevatedWslUpdate() (which spawns an elevated wsl --update child, line 264: 'requesting administrator approval to update WSL') before re-resolving. Only the second Resolve-FedoraDistribution call (638, no -AllowUnavailable) finally throws the real 'neither installed nor present in Microsoft's WSL catalogues' error (line 143).

**Problem.** There is no way for Resolve-FedoraDistribution's caller to distinguish 'auto-discovery found nothing (a WSL update might help)' from 'the user explicitly requested a name that genuinely does not exist anywhere, including the web catalogue'. A simple typo in -FedoraDistribution (e.g. FedoraLinux-4 instead of FedoraLinux-42) is treated identically to a stale WSL catalogue: the script prints the misleading warning 'The current WSL catalogue does not advertise an official FedoraLinux distribution', pops a UAC prompt, runs 'wsl --update --web-download' (which the script's own comments say depends on reaching api.github.com and commonly fails on restricted corporate networks), and only after that succeeds does it discover the name was simply wrong. On a network where that update call fails, the real, fast, one-line validation error is masked entirely by an elevated-phase network failure that has nothing to do with the actual problem.

**Fix.** In Resolve-FedoraDistribution (platforms/windows/install.ps1), when $RequestedDistribution is non-empty and not found (even after checking the web catalogue at 138), throw the 'neither installed nor present' error unconditionally -- do not honor -AllowUnavailable for an explicit request; reserve -AllowUnavailable only for the auto-discovery path (no $RequestedDistribution, the branch starting at 149). Callers at 624-639 and 628-635 (dry-run) then only reach the 'catalogue is stale, try updating WSL' branch when the user did not name a distribution at all. Update the two call sites' surrounding comments/messages accordingly, and update the DryRun branch (628-635) the same way so a mistyped name in a dry run also fails fast instead of printing 'Would request administrator approval to update WSL'.

**Acceptance.** Add a case to tests/test-windows-bootstrap.sh (or a new pwsh-run unit test if pwsh is added to CI) that calls Resolve-FedoraDistribution with a -RequestedDistribution that matches no installed/online/web entry and asserts it throws immediately without any call to Invoke-ElevatedWslUpdate; alternatively grep-assert that Resolve-FedoraDistribution's explicit-request branch (125-146) does not return $null when -AllowUnavailable is passed together with a non-empty $RequestedDistribution.

### win-3: The Fedora-container leg of Windows-bootstrap CI never actually parses or runs the PowerShell it is grepping
*high, testing. single-source.*

**Locations.** `tests/test-windows-bootstrap.sh:114-132`, `.github/workflows/validate.yml:33-35`, `tests/test-windows-bootstrap.ps1:1-87`

**Evidence.** tests/test-windows-bootstrap.sh:114 wraps its only syntax check in `if command -v pwsh >/dev/null 2>&1; then ... fi`. The 'repository' job in .github/workflows/validate.yml (container: fedora:44) installs only `git jq neovim python3 ripgrep ShellCheck stow` (line 34-35) -- no pwsh/powershell package -- and this is the only job that runs ./scripts/test.sh, which is what invokes tests/test-windows-bootstrap.sh. tests/test-windows-bootstrap.ps1 (the file that actually runs on windows-latest per validate.yml:71) only AST-parses both files (32-44) and executes set-noctty-theme.ps1's write behavior (51-76); it never invokes any function from install.ps1 itself (Resolve-FedoraDistribution, Install-WslDistribution, Set-NocttyConfiguration, Invoke-ElevatedPhase, Update-Wsl).

**Problem.** The entire Fedora-side coverage of the Windows bootstrap is line-for-line grep matching against install.ps1's source text (e.g. `grep -Fq -- "--set-default-version', '2'"`) with the one syntax-validation fallback silently skipped in CI because pwsh is not installed in that container. The windows-latest job supplies real PowerShell but exercises only ~15 of install.ps1's 684 lines (the theme helper). None of the actual logic this dimension was asked to audit -- Resolve-FedoraDistribution's catalogue fallback, the elevation retry/UAC path, Install-WslDistribution's idempotency branches, or Set-NocttyConfiguration's managed-block merge -- is executed by any CI job. A change that keeps every grepped literal string intact while breaking the surrounding logic (e.g. inverting a condition, dropping the -AllowUnavailable guard) passes CI cleanly on both platforms.

**Fix.** Two independent improvements, either of which materially closes the gap: (1) add `dnf install ... powershell` (or a pinned pwsh RPM/tarball) to the 'repository' job's dependency install step in .github/workflows/validate.yml so tests/test-windows-bootstrap.sh:114's pwsh branch actually runs the AST parse in CI, and make its absence a hard failure (`else printf '... pwsh required ...' >&2; exit 1; fi`) rather than a silent skip; (2) extend tests/test-windows-bootstrap.ps1 (which does have real pwsh) to dot-source or otherwise invoke the pure, side-effect-scoped functions in install.ps1 -- Resolve-FedoraDistribution and Get-WslDistributionVersion are the best candidates, since they can be exercised by mocking wsl.exe via a PATH-shadowing shim script the same way tests/test-fedora-wsl.sh mocks dnf/rpm/sudo -- and add assertions for the -AllowUnavailable/explicit-name behavior fixed in win-1.

**Acceptance.** After adding pwsh to the fedora:44 job, confirm `./scripts/test.sh` output includes evidence the pwsh branch ran (e.g. echo a line from inside the `if command -v pwsh` block) rather than being silently absent; for the ps1-side extension, add to tests/test-windows-bootstrap.ps1 a case that dot-sources install.ps1 with a stub wsl.exe on PATH returning a fixed --list/--list --online output and asserts Resolve-FedoraDistribution's return value for at least one of: a valid installed name, a valid online-only name, and (post win-1 fix) an immediate throw for an unresolvable explicit name.

### win-2: Declining the UAC prompt is retried as if it were a transient launch failure
*medium, correctness. single-source.*

**Locations.** `platforms/windows/install.ps1:221-236`

**Evidence.** for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) { try { $process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -Verb RunAs -Wait -PassThru; break } catch { if ($attempt -ge $maxAttempts) { throw }; Write-Warning "Requesting administrator approval failed (attempt $attempt of ${maxAttempts}): $($_.Exception.Message). Retrying..."; Start-Sleep -Seconds 2 } } -- the comment above it justifies the retry only for 'Start-Process -Verb RunAs is known to intermittently fail to launch or track the elevated process with a generic "the system cannot find all the information required" error'.

**Problem.** Start-Process -Verb RunAs throws synchronously (before -Wait even begins) both for the transient launch glitch the comment describes and for a user explicitly clicking 'No' on the UAC consent dialog (a Win32Exception for ERROR_CANCELLED). The catch block does not inspect $_.Exception.Message or any error code to tell these apart, so declining elevation is retried up to maxAttempts (3) times: the user who says no once is shown the UAC prompt two more times before the script finally gives up, contrary to the explicit, informed decision they already made.

**Fix.** In Invoke-ElevatedPhase's catch block (platforms/windows/install.ps1, inside the for loop around line 229), check whether $_.Exception is a [System.ComponentModel.Win32Exception] with NativeErrorCode -eq 1223 (ERROR_CANCELLED) or whether $_.Exception.Message matches 'cancel' (case-insensitive); if so, rethrow immediately with a clear message such as "$FailureDescription was not approved (elevation request canceled)." instead of retrying. Keep the existing retry-with-backoff behavior only for the remaining, genuinely transient exception cases.

**Acceptance.** Add a unit-level check (mocking Start-Process is impractical in the current test harness, so instead assert the source contains the cancellation check) -- extend tests/test-windows-bootstrap.sh with a grep for the new cancellation-detection branch inside Invoke-ElevatedPhase's catch block (e.g. grep for 'ERROR_CANCELLED' or the chosen distinguishing string) and a grep that the retry Write-Warning path is now conditioned on it, so a future refactor can't silently drop the distinction.

### win-4: wsl-copy/wsl-paste's executable check doesn't catch the interop-disabled failure mode the codebase itself documents
*medium, correctness. single-source.*

**Locations.** `platforms/fedora-wsl/stow/interop/.local/bin/wsl-copy:4-10`, `platforms/fedora-wsl/stow/interop/.local/bin/wsl-paste:4-10`, `platforms/fedora-wsl/lib/wsl.sh:166-172`, `README.md:465-470`

**Evidence.** wsl-copy/wsl-paste both do: `[[ -x "$clip"/"$powershell" ]] || { printf '... executable not found: %s\n' ... >&2; exit 1; }` before exec'ing it. platforms/fedora-wsl/lib/wsl.sh's own comment on windows_interop_works (166-172) explains the check exists precisely because 'Setting enabled=false ... breaks that explicit path even though PATH itself stays clean; it fails as a plain "cannot execute binary file" / "exec format error" from the shell, not an obviously WSL-related message,' and README.md:465-466 names 'wsl-open, the clipboard helpers' as exactly the tools this affects.

**Problem.** The `-x` test only checks the DrvFS execute-permission bit on the file, which stays set regardless of the WSL `[interop] enabled` setting -- it says nothing about whether the WSLInterop binfmt handler can actually run the binary. When a user (or a stale /etc/wsl.conf from before configure-interop.sh ran) has `[interop] enabled=false`, `-x` still passes, the guard clause in wsl-copy/wsl-paste is a no-op, and the script falls through to exec, producing exactly the confusing raw 'exec format error' the codebase's own documentation says this failure mode produces -- the clear, purpose-built diagnostic message the script tried to give never fires for the one case its neighboring code (wsl.sh, README) says is the real-world trigger.

**Fix.** In wsl-copy and wsl-paste, replace or augment the `-x` existence check with an actual invocation probe (mirroring windows_interop_works in platforms/fedora-wsl/lib/wsl.sh, which both scripts could source instead of duplicating the check): attempt a trivial invocation (or reuse windows_interop_works directly) and, on failure, print a message that distinguishes 'file missing' from 'found but cannot execute -- WSL interop is likely disabled; run platforms/fedora-wsl/scripts/configure-interop.sh' so the user is pointed at the actual fix instead of a raw shell error.

**Acceptance.** Add a case to tests/test-wsl-interop.sh (which already mocks WINDOWS_SYSTEM_ROOT/cmd.exe for windows_interop_works) that creates an executable clip.exe/powershell.exe stub which exits nonzero to simulate binfmt-disabled interop, runs wsl-copy/wsl-paste against it with input piped in, and asserts the script's stderr names the interop-disabled cause (not just a generic failure) and exits nonzero.


**Auditor notes for this dimension.** Checked and found clean (not reported as findings): the -ElevatedWslPhase/-ElevatedWslUpdateOnly mutual-exclusion guard (install.ps1:599-601) is present and correct; both elevated entry points correctly detect a non-admin session and fail with a clear thrown message (Update-Wsl:170-172, Install-WslDistribution:303-305) rather than half-running; Invoke-ElevatedPhase's transcript log is correctly surfaced to the parent's console on both success and failure paths, and the two elevation phases are reached strictly sequentially with no reachable bad ordering; Copy-FileIfChanged/Sync-NocttyGhosttyConfig and the Noctty managed-block merge in Set-NocttyConfiguration are both genuinely idempotent on inspection (traced the regex removal/reinsertion by hand); the Windows-to-Linux and Linux-to-Windows sequencing contract is documented in one authoritative place (README.md "Fedora on WSL", lines 335-433); wsl-paste correctly targets Windows PowerShell 5.1 (System32/WindowsPowerShell/v1.0/powershell.exe, which defaults to STA) rather than pwsh, so Get-Clipboard's well-known MTA-apartment failure mode does not apply here -- initially suspected this as a bug and ruled it out on inspection. Also noted but deliberately not filed as a finding: install.ps1 performs no explicit Windows-build/WSL-version precondition check beyond requiring wsl.exe to exist (line 620-622); failures downstream surface as generic wsl.exe exit-code errors via Invoke-NativeCommand rather than a friendly message, which is a minor documentation-vs-enforcement gap but not a strong enough defect to include given the 12-finding budget. One further gap worth the parent audit's attention even though I did not turn it into a standalone finding: theme divergence between the Linux theme-state and Noctty's theme.conf is never verified by either side -- platforms/fedora-wsl/scripts/verify.sh checks only that the Linux Starship config matches the local theme-state file (verify.sh:132-146), with no check that reads back Noctty's %LOCALAPPDATA%\\noctty\\dotfiles\\theme.conf through powershell.exe to confirm the Windows side actually applied the last selection -- so a failed or skipped sync (-SkipNocttyConfiguration, missing PowerShell, or a user-authored theme= override that README:407-409 says intentionally wins) is silently invisible to `./install.sh --platform fedora-wsl`'s own verify pass. This overlaps conceptually with the already-established "no Windows verify script" fact, which is why I left it as a note rather than a standalone finding, but it is a distinct, independently fixable gap (a WSL-side check, not a Windows-side script) if the parent report wants to fold it in.


## Structural maintainability

### M4: Parrot CTF's package list is duplicated between install-system.sh and verify.sh and has already drifted: 9 installed packages are never verified
*high, correctness. single-source.*

**Locations.** `platforms/parrot-ctf/scripts/install-system.sh:15-46`, `platforms/parrot-ctf/scripts/verify.sh:22-30`

**Evidence.** install-system.sh:15-46 installs 30 packages via `sudo apt-get install -y --no-install-recommends "${packages[@]}"`, including build-essential, ca-certificates, python-is-python3, python3-dev, python3-pip, unzip, xdg-utils, zsh-autosuggestions and zsh-syntax-highlighting. verify.sh:22-25 independently declares its own `packages=(bat eza fd-find fzf gh git git-delta jq lazygit neovim pipx python3 python3-venv ripgrep shellcheck spice-vdagent sqlite3 starship stow tmux zoxide zsh qemu-guest-agent)` and dpkg-query-checks only those 22 -- it never checks the 9 packages named above, and it checks two (spice-vdagent, qemu-guest-agent) that install-system.sh never installs (those come from install-guest-integration.sh instead, per the parrot verify.sh's own guest-channel checks earlier in the same file).

**Problem.** Because the two lists are independently hand-typed rather than derived from one source, a Parrot CTF machine where build-essential, python3-dev, or zsh-autosuggestions silently failed to install (e.g. a mirror hiccup during `apt-get install`) will still show `./platforms/parrot-ctf/install.sh` and its verify step as fully green, since nothing in verify.sh's package loop ever names them. This is the concrete, already-realized cost of the general 'duplicated scaffolding drifts silently' problem in M1: it is not hypothetical here, the two lists are visibly out of sync today.

**Fix.** In platforms/parrot-ctf/scripts/verify.sh, replace the independently-typed `packages=(...)` array at line 22-25 with one that is sourced from install-system.sh's own list plus the guest-integration extras, e.g. have install-system.sh export its packages array via a small `common/lib` helper (`source_package_list platforms/parrot-ctf/scripts/install-system.sh packages`) or, more simply, factor the shared 22-entry core into a `platforms/parrot-ctf/lib/parrot.sh` array constant that both install-system.sh and verify.sh reference, with install-system.sh appending build-only extras (build-essential, python3-dev, unzip, xdg-utils, ca-certificates) and verify.sh appending guest-integration extras (spice-vdagent, qemu-guest-agent) on top of the same shared base.

**Acceptance.** Add an assertion to tests/test-parrot-ctf.sh (or a new tests/test-parrot-package-parity.sh) that parses both arrays out of the two files with the same `sed`-based extraction used elsewhere in the test suite and asserts every package in install-system.sh's array that is a genuinely apt-installed baseline tool (excluding the guest-integration-owned ones) also appears in verify.sh's array. Run it against the current tree first to confirm it fails on today's 9-package gap, then fix and confirm it passes.

**My independent check.** Confirmed, with a slightly different count. Extracting the package
array from `platforms/parrot-ctf/scripts/install-system.sh` gives 31 packages; comparing each
against every token in `platforms/parrot-ctf/scripts/verify.sh` leaves **10** that appear
nowhere in it: `build-essential`, `ca-certificates`, `curl`, `python-is-python3`,
`python3-dev`, `python3-pip`, `unzip`, `xdg-utils`, `zsh-autosuggestions`,
`zsh-syntax-highlighting`. I checked specifically whether the two zsh plugins are verified
indirectly by file path rather than package name, since that would be a legitimate pattern:
they are not mentioned in the file at all. So roughly a third of what the CTF guest installs
has no verification of any kind, and the verifier is a hand-maintained 96-line subset with
nothing tying it to the install list.

### M1: Verify scaffolding and the stow loop are reimplemented from scratch in each of the four platform script sets, with no shared contract
*medium, maintainability. single-source.*

**Locations.** `platforms/fedora/scripts/verify.sh:15-60`, `platforms/fedora-wsl/scripts/verify.sh:30-62`, `platforms/macos/scripts/verify.sh:25-38`, `platforms/parrot-ctf/scripts/verify.sh:11-13`, `platforms/fedora/scripts/stow.sh:75-95`, `platforms/fedora-wsl/scripts/stow.sh:17-28`, `platforms/macos/scripts/stow.sh:15-23`, `platforms/parrot-ctf/scripts/stow.sh:17-23`

**Evidence.** Every verify.sh independently defines pass()/fail()/warning()/section()/check_command() with the identical bodies (e.g. fedora:15 `pass() { printf '\033[1;32m✓\033[0m %s\n' "$*"; }` reappears verbatim, one-lined, at macos:25 and parrot-ctf:11; fedora-wsl:30-46 spells the same four functions out multi-line). check_symlink() is duplicated in fedora:39-56 and fedora-wsl:62 with the same `readlink -f` + prefix-match body (already known to be unguarded against dangling links in both copies, not just one). Every stow.sh independently authors the same `for package in "${packages[@]}"; do [[ -d "$dir/$package" ]] || die ...; stow --dir=... --target="$HOME" --restow --no-folding "$package"; done` loop (fedora:75-95, fedora-wsl:17-28, macos:15-23, parrot-ctf:17-23) -- fedora's copy additionally carries Sway/wallpaper migration logic mixed into the same file, so the platform-specific and generic parts are not even separated within one script. Notably the repo already contains the right pattern elsewhere: platforms/fedora-wsl/scripts/install-containers.sh:1-99 is a thin wrapper that adds WSL-specific preflight checks and then `exec`s into platforms/fedora/scripts/install-containers.sh -- it does not re-author the Podman install. That delegation pattern is simply not applied to stow.sh or verify.sh.

**Problem.** Four independent copies of the same ~15-45 line scaffold (pass/fail/warning/section/check_command/check_symlink, and the stow-loop) mean a fix or improvement made in one platform's copy (for example, adding an existence check to check_symlink so a dangling stow link fails instead of passing) has to be manually ported to three more files by memory, with nothing that would catch a missed one. This is exactly the shape of the readlink -f gap already found in the fedora copy: the same bug is duplicated into fedora-wsl's copy at lib/../scripts/verify.sh:62 rather than existing once.

**Fix.** Move the generic scaffold into common/lib/: add common/lib/verify-scaffold.sh exporting pass(), fail(), warning(), section(), check_command(), and a corrected check_symlink() (fixing the dangling-link gap once, for every platform). Each platform's verify.sh sources it and keeps only its own section() blocks. Do the same for stow: add a common/stow-packages.sh helper function `stow_packages <stow_dir> <package...>` implementing the existing loop body (mkdir check, stow --restow --no-folding, error message), called from each platform's stow.sh with its own package array; fedora's Sway/wallpaper migration functions stay local to platforms/fedora/scripts/stow.sh since they are genuinely platform-specific. Define the per-platform contract as three required hook points sourced by a common driver: platform_packages (array, used by install-system.sh), platform_stow_packages (array, used by stow.sh), platform_verify_sections (function list, used by verify.sh) -- each platform's lib/<platform>.sh declares these, and common/lib/ drives them. Migration order that keeps scripts/test.sh green throughout: (1) add common/lib/verify-scaffold.sh and common/stow-packages.sh with the extracted, unmodified logic, unit-covered by a new tests/test-common-scaffold.sh; (2) switch parrot-ctf's verify.sh and stow.sh to source them first (smallest surface, 96/25 lines) and run scripts/test.sh; (3) macos next; (4) fedora-wsl; (5) fedora last, since its stow.sh and verify.sh carry the extra Sway-specific logic that must stay untouched during the swap. Each step is a mechanical function-body replacement, so `git diff` after each step should show only deletions inside the four files being migrated.

**Acceptance.** tests/test-cheatsheet-bindings.sh and the platform-specific tests (tests/test-fedora-wsl.sh, tests/test-parrot-ctf.sh, tests/test-macos.sh) continue to pass unmodified after each migration step since they test behavior, not implementation. Add tests/test-common-scaffold.sh asserting pass()/fail() increment the right counters and check_symlink() now fails (not passes) on a dangling symlink target, then assert each platform's verify.sh still sources common/lib/verify-scaffold.sh via `grep -q 'source.*verify-scaffold.sh' platforms/<p>/scripts/verify.sh` for all four platforms.

### M2: Hand-rolled `while ((\$#)); do case "$1" in ... esac; shift; done` option parsing is copied into 24 separate scripts with no shared flag-declaration helper
*medium, maintainability. single-source.*

**Locations.** `platforms/fedora/install.sh:117-312`, `platforms/fedora-wsl/install.sh:85-187`, `platforms/macos/install.sh:42-64`, `platforms/parrot-ctf/install.sh:31-53`, `install.sh:9-24`

**Evidence.** platforms/fedora/install.sh's option-parsing while-loop runs lines 117-312, 196 lines, containing 38 case arms (19 boolean flag pairs like --kde/--no-kde, each a 5-line block: `--kde) install_kde="true" ;; --no-kde) install_kde="false" ;;`, plus multi-value flags like --theme and --hardware). fedora-wsl's own copy of the same pattern is 103 lines (85-187), macos's is 23 lines (42-64), parrot-ctf's is 23 lines (31-53) -- 345 lines total across just the four top-level installers implementing the identical `while (($#)); do case "$1" in ... *) die "Unknown option: $1" ;; esac; shift; done` shape by hand. A repo-wide search for that exact while-loop opening (`grep -rl 'while ((\$#)); do' --include=*.sh . | grep -v /tests/`) finds it copied independently into 24 non-test files (install.sh, common/install-ai.sh, common/stow.sh, every platform install.sh, and a dozen platforms/*/scripts/install-*.sh / verify.sh files), each with its own `*) die "Unknown option: $1" ;;` fallback and its own per-flag boilerplate.

**Problem.** Every new boolean flag anywhere in the repo costs 5 lines of copy-pasted case-arm boilerplate, and every script that parses options re-derives the same unknown-option error, the same multi-value-flag validation (`[[ $# -ge 2 ]] || die "--theme requires a value"`), and the same shift bookkeeping independently. There is no single place that knows "this is how a boolean install flag is declared" -- a maintainer adding a flag has to find and imitate an existing case arm rather than following a documented API, and a bug in the pattern (e.g. an inconsistent `shift` vs `shift 2`) has to be hunted down in up to 24 places rather than fixed once.

**Fix.** Add a declarative helper to common/lib/common.sh: `parse_bool_flags <assoc-array-name-of-flag-to-var> "$@"` that walks argv, and for each `--foo`/`--no-foo` pair sets the named variable to true/false, leaving unrecognized args in a returned remainder array for the caller's own multi-value/positional handling. Concretely: `declare -A flag_vars=([--kde]=install_kde [--latex]=install_latex ...)` then `parse_known_bool_flags flag_vars remaining_args "$@"`, after which the caller's existing case statement only needs the flags that are NOT simple booleans (--theme, --hardware, --charge-limit, --containers-api-socket). This does not need to replace every case statement at once: convert platforms/fedora/install.sh first since it has by far the largest boolean-flag count (19 pairs, ~140 of its 196 parsing lines), verify the flag count in its usage() text still matches the parsed set, then apply the same helper to fedora-wsl, macos, parrot-ctf and the smaller scripts (install-containers.sh, install-hardening.sh, etc.) opportunistically as they're touched -- there is no ordering dependency between them since each script's parsing is self-contained.

**Acceptance.** tests/test-installer-options.sh (already exercises fedora's flag parsing) continues to pass unmodified against the refactored platforms/fedora/install.sh, proving parity. Add a new assertion there that an unrecognized flag still produces the existing 'Unknown option: --bogus' die message and non-zero exit, so the shared helper preserves that contract. Add a unit test tests/test-common-scaffold.sh (or extend it if M1's file exists) that calls parse_bool_flags directly with a small synthetic flag map and asserts both the true and false paths and that unmatched args are returned untouched.

### M3: Extension cost, measured: five common maintenance tasks each require touching between 2 and 10+ files with no registry, checklist, or table to shorten the list
*medium, maintainability. single-source.*

**Locations.** `platforms/fedora/scripts/install-system.sh:10-32`, `platforms/fedora-wsl/scripts/install-system.sh:12-`, `platforms/parrot-ctf/scripts/install-system.sh:15-46`, `install.sh:26-52`, `zsh/.config/zsh/.zshrc:24-96`, `docs/keybindings.md:1-14`, `docs/cheatsheets/common-workflow.tex:1-3`

**Evidence.** (a) Add a new baseline CLI tool available on every platform: platforms/fedora/scripts/install-system.sh's `packages=(...)` array (line 10) and platforms/fedora-wsl/scripts/install-system.sh's independently-authored `packages=(...)` array (only 60% overlapping -- a `diff` of the two arrays shows fedora-wsl alone adds bzip2, gawk, gcc, gcc-c++, make, procps-ng, unzip and drops wl-clipboard/xdg-utils) both need the addition by hand, plus platforms/macos/Brewfile, plus platforms/parrot-ctf/scripts/install-system.sh:15-46's own apt list, plus each of the four verify.sh `commands=(...)`/`packages=(...)` arrays to actually check it landed, plus README.md's package-ownership tables -- 8-9 files, none of them a single source of truth. (b) Add a new optional profile (e.g. a fifth toggle like --hardening): a new platforms/<p>/scripts/install-<x>.sh and verify-<x>.sh from scratch (no scaffold to inherit from, see M1), a new case arm + usage() line in the platform install.sh's option parser (M2), the invocation site further down that same install.sh, a state-file write, README.md documentation, and a scripts/<x>.sh shim if the convention of exposing one is followed -- 6-7 files for one profile on one platform. (c) Add a new platform: install.sh:26-34's hardcoded `case "$platform" in fedora | fedora-wsl | macos | parrot-ctf)` and its line 30 error string listing the same four names by hand, a wholly new platforms/<new>/{install.sh,lib/,scripts/{install-system,stow,verify}.sh}, a new .github/workflows/validate.yml job, README.md sections, and a new line in scripts/test.sh's `tests=(...)` array (scripts/test.sh:8-34 is itself the one place in the repo that IS a registry -- adding a platform's test there is one line, in contrast to every other list above). (d) Add a new Catppuccin-themed CLI tool: theme files for all four flavours under <tool>/, plus wiring in zsh/.config/zsh/.zshrc using whichever idiom that tool needs -- a `case $DOTFILES_THEME` block for bat (zshrc:45-49), a direct env-var path substitution for starship (zshrc:96) and lazygit (zshrc:42), or a `source .../catppuccin-fzf-${DOTFILES_THEME}.sh` for fzf (zshrc:63) -- each tool wired by its own hand-written idiom, no shared "themed tool" table. (e) Add a shared keybinding: the tool's own config file, plus docs/keybindings.md (the stated single source), plus docs/cheatsheets/common-workflow.tex, which carries the comment at line 1-3 'Keep this in sync with docs/keybindings.md; regenerate all sheets together' -- an explicitly manual duplication that tests/test-cheatsheet-bindings.sh does not check (it only asserts discovery phrases exist in keybindings.md and that common-workflow.tex exists as a file at lines 131-140, never that its table rows match keybindings.md's content).

**Problem.** None of (a), (b), or (d) has a registry, manifest, or generator; each is a flat 'find every place a sibling entry appears and copy the pattern' exercise, and nothing fails CI if one of the 6-10 places is missed (a forgotten verify.sh entry silently means the tool is never checked; a forgotten Brewfile entry silently means macOS never gets it). (c) and (e) are partially better: scripts/test.sh's tests array is a genuine one-line registry, and docs/keybindings.md is explicitly designed as the single prose source -- but (e)'s LaTeX mirror undoes that design by requiring the same content maintained twice by hand.

**Fix.** Introduce one manifest per axis rather than one shared parser for all of them, since the five tasks have different natural shapes: for (a), a common/lib/baseline-packages.toml-style manifest is overkill given DNF/APT/Homebrew package names genuinely differ per platform -- instead add a `tests/test-baseline-packages.sh` that extracts every platform's install-system.sh package array and every platform's verify.sh check-list, and fails if a package is installed but never verified (this is exactly the drift already demonstrated concretely in M4 for parrot-ctf) or vice versa. For (b), give M1's platform contract a `platforms/<p>/scripts/PROFILES.md` or, more mechanically, require every install-<x>.sh to register itself by sourcing a common `register_profile <name>` call that appends to a manifest verify.sh reads to auto-generate its own section list, removing the need to hand-edit verify.sh's section() calls. For (d), add a `docs/theming.md` table of {tool, theme-file location, zshrc wiring line} that a new tests/test-theme-coverage.sh greps for consistency (each tool in the table has a theme file present for all 4 flavours, and appears in zshrc). For (e), extend tests/test-cheatsheet-bindings.sh's existing keybindings_doc/common-workflow.tex checks (currently only lines 131-140) to assert every `\csrow{...}{...}` entry in common-workflow.tex has a corresponding line of text in docs/keybindings.md, catching drift instead of just file existence.

**Acceptance.** For (a): a new tests/test-baseline-packages.sh added to scripts/test.sh's tests=() array, run against the current tree, should immediately fail on the parrot-ctf drift documented in M4, proving it catches real cases. For (e): extend tests/test-cheatsheet-bindings.sh with a loop over `\csrow{X}{Y}` matches in common-workflow.tex asserting `grep -Fq "$Y"` (or a normalized form) against docs/keybindings.md, and confirm it currently passes (establishing a baseline) before any new keybinding is added without updating both files, at which point it should fail.

### M5: README.md is a 4462-line monolith even though the repo already proves the fix: docs/macos.md is the one platform successfully extracted out of it
*medium, maintainability. single-source.*

**Locations.** `README.md:39-844`, `README.md:3280-3926`, `docs/macos.md:1`, `README.md:63,133,2643`

**Evidence.** README.md carries 128 '#'/'##' headings across 4462 lines, including full inline installation/configuration guides for Fedora ("# Supported environment" at line 39 through "# Parrot Security Edition CTF VM" at line 844, roughly 800 lines), Fedora WSL ("# Fedora on WSL" at line 335), Parrot CTF (line 844), and generic tool documentation with nothing platform-specific about most of it ("# Ghostty" 3280, "# tmux" 3331, "# Zsh" 3367, "# Git and GitHub workflow" 3410, "# Neovim / LazyVim" 3479, "# .NET development" 3567, "# Angular / TypeScript development" 3635, "# Python development" 3732, "# OCaml development" 3781 -- roughly 650 more lines). By contrast, macOS's equivalent content genuinely lives in the separate docs/macos.md (460 lines), and README.md links out to it rather than duplicating it: README.md:63 'Apple Silicon macOS workstation guide](docs/macos.md)', :133 'The [macOS guide](docs/macos.md) covers permissions, AeroSpace keys,...', :2643 'in the [macOS package-ownership table](docs/macos.md#3-package-ownership)'. The extraction pattern is proven to work in this repo; it simply was not applied to the other three platforms or to the generic tool sections.

**Problem.** A single 4462-line file is slow to navigate, slow to diff meaningfully in review (an edit to the OCaml section and an edit to the Fedora WSL section land in the same file-level diff noise), and its own internal consistency (e.g. keeping the Fedora package-ownership table in sync with platforms/fedora/scripts/install-system.sh) is harder to eyeball than a per-topic file would be. The macOS extraction is direct evidence the maintainer already recognizes this and has done it once, making the remaining three platforms' inline treatment an inconsistency rather than a deliberate flat design.

**Fix.** Extract docs/fedora.md, docs/fedora-wsl.md and docs/parrot-ctf.md mirroring docs/macos.md's existing structure and heading conventions (its own internal '#' sections, anchored by '## N. <topic>' the same way docs/macos.md is referenced by anchor at README.md:2643), moving README.md:39-844's Fedora/WSL/Parrot content into them and replacing it with the same kind of short pointer paragraph + anchor links README.md already uses for macOS. Separately extract the generic tool sections (Ghostty, tmux, Zsh, Git, Neovim, .NET, Angular, Python, OCaml -- README.md:3280-3926) into a docs/tools.md, since none of that content is Fedora/WSL/macOS/Parrot-specific and it currently sits between platform-specific sections rather than a tools reference. Update every internal README.md cross-reference and every `docs/macos.md#section`-style anchor link elsewhere in the repo (grep for `README.md#` and the moved section titles first) in the same commit so links don't rot.

**Acceptance.** tests/test-cheatsheet-bindings.sh already asserts specific text exists in README.md (e.g. 'Meta+Alt+K' at line 122); after extraction, update it to check the new docs/fedora.md (or wherever that text lands) instead, and add a lightweight link check (see M8) that fails on a broken internal anchor, then run it against the extracted docs to prove no link was left dangling.

### M6: platforms/fedora/install.sh and verify.sh are flat, undecomposed monoliths despite the repo already having a working split pattern one directory over
*medium, maintainability. single-source.*

**Locations.** `platforms/fedora/install.sh:117-312`, `platforms/fedora/scripts/verify.sh:66-780`, `platforms/fedora/scripts/install-containers.sh:1-170`, `platforms/fedora/scripts/verify-containers.sh:1`

**Evidence.** platforms/fedora/install.sh is 905 lines; its option-parsing while-loop alone (lines 117-312, quantified in M2) is 196 lines, 21.7% of the file. platforms/fedora/scripts/verify.sh is 780 lines organized into 11 `section "..."` blocks (line 66 'Core commands' through line 730 'Repository hygiene', found via `grep -n '^section "'`), all inline in one file with no per-concern split, even though optional-profile verification is already correctly split out into sibling files in the very same directory: verify-containers.sh, verify-tailscale.sh, verify-hardening.sh, verify-vm-host.sh, verify-desktop-tools.sh, verify-asus-hardware.sh each own one concern and are invoked from install.sh or verify.sh as separate scripts.

**Problem.** The baseline (always-run) 780 lines of verify.sh do not get the same per-concern separation the optional profiles already enjoy one directory over, so the file that runs on every single Fedora install is also the largest and least navigable of the bunch. Similarly, install.sh's 905 lines are dominated by parsing boilerplate (M2) rather than the installation logic itself, which is comparatively compact.

**Fix.** Apply the same split already used for optional profiles to the mandatory sections: extract platforms/fedora/scripts/verify-core.sh (Core commands, SFTP client baseline, Login shell), verify-theme.sh (Theme, Catppuccin tmux), and keep Stow links / Git local configuration / mise / Neovim tooling / Repository hygiene either as further splits or as the remaining body of a slimmed verify.sh that sources the extracted files in order, matching the calling convention verify-containers.sh already uses (each extracted file keeps its own `failures`/`warnings` accounting and the top-level verify.sh sums them, the same pattern used when it already calls `"$DOTFILES_ROOT/common/verify-ocaml.sh"` conditionally at line ~529). For install.sh, apply M2's parse_bool_flags helper first; that alone removes roughly 140 of the 196 parsing lines without any other restructuring.

**Acceptance.** tests/test-installer-options.sh and tests/test-sftp-baseline.sh (which already asserts content of install-kde-theme.sh per the existing test suite) continue to pass unmodified against the split verify.sh, proving the section boundaries were preserved exactly. Add a line-count assertion is unnecessary; instead assert (in a hygiene test) that platforms/fedora/scripts/verify.sh's own line count drops below a stated threshold (e.g. 200) after the split, so the decomposition cannot silently regress back into one file.

### M7: No installed-revision record and no changelog: a machine cannot report which commit it was built from, and verify.sh cannot compare against it
*medium, completeness. single-source.*

**Locations.** `platforms/fedora/scripts/setup-local.sh:1-75`, `platforms/fedora/scripts/verify.sh:1-780`, `common/lib/common.sh:51-70`

**Evidence.** Every profile that writes machine-local state does so through the same atomic_write_file helper (common/lib/common.sh:51-70) into small `key=value` files under $XDG_CONFIG_HOME/dotfiles/ (tailscale.conf, containers.conf, ocaml.conf, ai.conf, and the theme file setup-local.sh reads at line 43), but none of them, nor setup-local.sh itself, records the repository git SHA, the resolved option set, or a timestamp of the run that produced them. There is no CHANGELOG file anywhere in the repository (`find . -iname 'CHANGELOG*'` returns nothing) and no revision-comparison logic anywhere in verify.sh (`grep -n 'rev-parse' platforms/fedora/scripts/verify.sh` matches only an unrelated tmux-theme-plugin check at line 558, `git -C "$tmux_theme_dir" rev-parse HEAD`, not the dotfiles repo's own revision).

**Problem.** For a repository whose stated purpose is rebuilding a workstation from scratch and that expects to survive years of OS upgrades, there is no way -- short of manually running `git log` inside the cloned dotfiles checkout, if the user still has it -- for a maintainer to answer 'what version of this repo is this machine actually running', or for verify.sh to warn that a machine was built from an option set that no longer matches what a re-run would choose (e.g. a flag renamed or removed since the machine was set up).

**Fix.** Add a `write_install_stamp <platform> <options-string>` helper to common/lib/common.sh that writes $XDG_CONFIG_HOME/dotfiles/install-state.conf via atomic_write_file with: `platform=<name>`, `revision=$(git -C "$DOTFILES_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)`, `dirty=$(git -C "$DOTFILES_ROOT" status --porcelain 2>/dev/null | grep -q . && echo true || echo false)`, `options=<the resolved flag summary>`, and `installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)`. Call it once at the end of each platform install.sh's successful run (mirroring where setup-local.sh is already invoked, e.g. platforms/fedora/install.sh:816). Have each platform's verify.sh print this file's contents under a new leading `section "Install record"` block so `./verify.sh` output always states what it's validating. A minimal CHANGELOG.md following Keep a Changelog conventions, updated by hand alongside meaningful behavior changes, gives the revision stamp something human-readable to cross-reference.

**Acceptance.** Extend tests/test-local-state.sh to assert install-state.conf is written with all five keys after a mocked install run, that its `revision` value is a 40-character hex string (or 'unknown' in a non-git test sandbox), and that a second install run updates installed_at rather than duplicating the file. Add an assertion to the relevant platform test (e.g. tests/test-mocked-installs.sh) that verify.sh's output contains the string 'Install record' and the revision value from the stamp file.

### M8: scripts/lint.sh checks only *.sh files with bash -n + shellcheck, leaving PowerShell, Lua and Markdown entirely unchecked -- despite shfmt and stylua already being provisioned in every install
*low, hygiene. single-source.*

**Locations.** `scripts/lint.sh:1-29`, `nvim-lazyvim/.config/nvim/mason-packages.txt:12-13`, `platforms/fedora/scripts/verify.sh:487-493`, `platforms/windows/install.ps1:1`, `platforms/windows/set-noctty-theme.ps1:1`

**Evidence.** scripts/lint.sh:8 collects only `git ls-files -z -- '*.sh'`, runs `bash -n` on each (line 18) and `shellcheck -x -P SCRIPTDIR -s bash` on the set (line 27) -- nothing else. Yet nvim-lazyvim/.config/nvim/mason-packages.txt:12-13 lists `shfmt` and `stylua` as Mason-managed tools that platforms/fedora/scripts/verify.sh:487-493's mason_packages loop already verifies are installed on every machine (`for package in "${mason_packages[@]}"; do if [[ -d "$mason_root/$package" ]]; then pass ...`), and README.md:2839-2840 documents them as 'Editor formatting for shell files' / 'Editor formatting for Lua files' respectively -- i.e. formatting today depends entirely on each contributor's LazyVim format-on-save being active, with no repository-level enforcement. Separately, the 684-line platforms/windows/install.ps1 and set-noctty-theme.ps1 get zero static analysis (no PSScriptAnalyzer anywhere in the repo or in .github/workflows/validate.yml's windows job, which only runs tests/test-windows-bootstrap.ps1), and README.md's ~30 internal `docs/*.md#anchor`-style cross-references (used throughout, e.g. README.md:2643) have no automated link check.

**Problem.** Shell formatting consistency across 143 tracked shell files rests on an editor convention that CI cannot see, so a PR from a contributor without LazyVim's Mason tools active can introduce formatting drift that shellcheck and bash -n both accept. The 684+238 lines of PowerShell backing the Windows bootstrap have no static analysis at all despite being exercised by a real CI job. A moved or renamed heading anywhere in the now-4462-line README (or the docs/ files M5 proposes creating) silently breaks any cross-reference pointing at it, since nothing checks internal links.

**Fix.** Add to scripts/lint.sh: (1) if `command -v shfmt` is available, run `shfmt -d $(git ls-files '*.sh')` and fail on non-empty diff output -- since shfmt is already a Mason-provisioned dependency on every dev machine per mason-packages.txt, this costs nothing new to provision, only wire it into the existing lint entrypoint; (2) if `command -v stylua` is available, run `stylua --check $(git ls-files '*.lua')` over the 19 tracked Lua files; gate both behind an availability check (matching the existing shellcheck-required-but-checked pattern at lint.sh:21-24) so environments without Mason yet don't hard-fail, but make .github/workflows/validate.yml's fedora container job install both (`dnf install -y shfmt` where packaged, or download the pinned release, similar to how the container already installs jq/neovim/ripgrep for validation at validate.yml:33-36) so CI itself always enforces them. Add a PSScriptAnalyzer step to .github/workflows/validate.yml's `windows` job (Install-Module PSScriptAnalyzer -Force; Invoke-ScriptAnalyzer -Path platforms/windows -Recurse) alongside the existing tests/test-windows-bootstrap.ps1 step. Add a markdown-link-check step (or a simple grep-based internal-anchor checker, given the CDN/network restrictions a full markdown-link-check tool may hit in CI) validating every `](docs/*.md#...)`-style link in README.md resolves to a real heading.

**Acceptance.** Run `./scripts/lint.sh` after wiring shfmt/stylua and confirm it still exits 0 on the current tree (proving no existing file already violates the new formatting check); then deliberately misindent one tracked .sh file and one .lua file locally and confirm lint.sh now fails on each, before reverting. For the PSScriptAnalyzer step, confirm it runs green against platforms/windows/install.ps1 and set-noctty-theme.ps1 as they stand today.

## Findings from my own pass over files no agent covered

I computed which tracked files appear in no finding at all: of 281 tracked files, 118 were
unexamined, most of them legitimately data (wallpapers, test fixtures, per-flavour theme
files). Opening the ones that were neither data nor covered by the second pass surfaced two
defects, both genuinely low, reported at that severity rather than inflated.

### G-01: `sway-screenshot` computes and creates a save path its main branch never uses
*low, correctness. Support: executed.*

**Locations.** `platforms/fedora/stow/sway/.local/bin/sway-screenshot:5-7`, `:11-14`,
`platforms/fedora/stow/sway/.config/sway/config:111-113`

**Evidence.** Lines 5-7 run unconditionally:
```bash
screenshots="${XDG_PICTURES_DIR:-$HOME/Pictures}/Screenshots"
mkdir -p "$screenshots"
filename="$screenshots/$(date +'%Y-%m-%d_%H-%M-%S').png"
```
The `region` branch then does `geometry="$(slurp)" || exit 0` and
`grim -g "$geometry" - | swappy -f -`, never referencing `$filename`. Only the `output`
branch writes it. `sway/config` binds `region` to both `Print` (`:111`) and `$mod+Shift+s`
(`:112`), and `region` is also the default mode, so two of the three bindings plus the
default take the path that ignores the directory it just created. A `find` for any swappy
configuration in the repository returns nothing, so where a region screenshot lands is
swappy's own default, which this repository neither sets nor documents.

**Problem.** A machine that only ever takes region screenshots accumulates an empty
`~/Pictures/Screenshots` that the script created, and `$filename` is dead computation on that
path. More substantively, the save destination for the primary screenshot flow is the one
piece of this desktop the repository does not manage, while it manages theming and
configuration for everything else.

**Not a finding, checked and cleared.** The documentation is accurate here and should not be
changed: `docs/cheatsheets/fedora-sway.tex:89` says "Print, Super+Shift+S -> Select a region,
annotate (swappy)", promising no path, and `:90` correctly attributes the
`~/Pictures/Screenshots` destination to `Shift+Print`, which is the `output` branch.
`README.md:3241-3242` says the same thing correctly. I had initially drafted this as a
documentation contradiction and dropped that framing on reading the sheet. Also cleared: every
tool these scripts need is installed by `platforms/fedora/scripts/install-sway.sh` (`grim:16`,
`jq:17`, `libnotify:18`, `mako:20`, `slurp:24`, `swappy:30`); `region` having no
`notify-send` while `output` has one is correct, since swappy opens a GUI; and `|| exit 0` on
a cancelled `slurp` is right, because a cancelled selection is not an error.

**Fix.** Move `mkdir -p` and the `filename` assignment into the `output` branch. Then either
ship a swappy configuration in the `sway` stow package pinning its save directory to the same
`$XDG_PICTURES_DIR/Screenshots` the `output` branch uses, so both paths agree, or state in
`fedora-sway.tex` that region hands off to swappy and the save location is swappy's own
setting.

**Acceptance.** Extend `tests/test-sway-config.sh`, which already parses this script at
`:175`, to assert the `region` branch does not reference `$filename`, and that if a swappy
config is added its save directory matches the `output` branch's directory.

### G-02: the two workspace-grid scripts handle the same edge case oppositely
*low, parity. Support: executed.*

**Locations.** `platforms/fedora/stow/sway/.local/bin/sway-workspace-grid:17-19`,
`platforms/macos/stow/aerospace/.local/bin/aerospace-workspace-grid:14-17`

**Evidence.** The same logical helper, opposite behaviour when the focused workspace is
outside the 1-9 grid. Sway:
```bash
if [[ ! "$current" =~ ^[1-9]$ ]]; then
  current=1
fi
```
AeroSpace:
```bash
[[ "$current" =~ ^[1-9]$ ]] || {
  printf 'Focused workspace is not in the 1-9 grid: %s\n' "$current" >&2
  exit 1
}
```

**Problem.** On Sway, being on a workspace outside 1-9 and pressing `$mod+Ctrl+<direction>`
silently teleports you into the grid from a false premise; on macOS the same situation is
reported and refused. The AeroSpace behaviour is the better one, and the divergence is the
kind that only shows up when a user hits it.

**Fix.** Make `sway-workspace-grid` match `aerospace-workspace-grid`: report to stderr and
exit non-zero rather than assuming workspace 1. Keep the message format consistent between
the two so a future shared helper is straightforward.

**Acceptance.** `tests/test-sway-config.sh` already sources this script. Add a case stubbing
`swaymsg` to report a focused workspace of 10 and assert a non-zero exit and a message on
stderr.
