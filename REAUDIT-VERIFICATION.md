# Re-audit verification pass

**Verified revision:** `d4f61dd` (`main` plus the 15 commits that landed after the interim
report's `6c649ab`; none of them touch a finding's subject).
**Input:** the interim re-audit report, 45 dimension findings plus R-01 and R-02.
**Status of the input:** every dimension finding was marked UNVERIFIED. This document is the
adversarial pass the interim report said had not run.

## 1. Verdict

**47 report entries in, 39 distinct findings out. None was refuted.** Nine entries were
duplicates of another entry and are merged. Six entries needed a correction to their scope,
their numbers or their reasoning; the correction is recorded with the finding and, in one
case, materially shrinks it.

| Outcome | Findings |
|---|---|
| Confirmed by live negative control — I broke something and watched the gate stay green | 16 |
| Confirmed by measurement — counted, diffed or parsed the real files | 13 |
| Confirmed by code reading — mechanism proven, behavioural proof blocked by a missing tool | 10 |
| Refuted | 0 |
| **Total distinct findings** | **39** |

(47 interim entries in; 9 were duplicates of another entry and are merged, leaving 39. The 16
negative-control findings took 21 separate reproductions, because four findings needed more
than one.)

The interim report predicted that "roughly one finding in five does not survive verification."
That did not happen here. What happened instead is that the report's *counts* were sometimes
wrong while its *mechanisms* were right, and that its 14 independent dimensions reported the
same defect up to four times under different names.

Two tools were unavailable in the verification container and bound what I could execute:
`shellcheck` and `stow` are not installed, and `nvim` is absent. Findings that needed them are
marked below and rest on code reading rather than execution.

## 2. Corrections to the interim report

These matter more than the confirmations, because each one changes what the fix has to be.

### C-1. The test-harness finding is one suite, not seven. (affects PF-02, R-02, macos-login-shell-false-pass)

The interim report measured which suites declare `errexit` by looking at each file's **first
five lines** and concluded "35 declare errexit, 7 do not". That window is too small: six of the
seven named suites declare `set -euo pipefail` on lines 7 to 16, after their header comment.

Measured over every line of every suite that sources the test library:

```
suites sourcing tests/lib/test.sh          43
  declare errexit somewhere                41
  do not                                    2
    tests/test-dev-workflow-contract.sh      (sound: has a failures counter, exits 1)
    tests/test-macos-login-shell.sh          (the defect)
```

R-02 had already self-corrected to "ONE suite out of 42" by execution. PF-02 and
macos-login-shell-false-pass restate the same defect from two other dimensions. All three are
one finding, RA-10. The harness weakness that permits it is real and structural; its live blast
radius is a single file.

### C-2. Two verifiers drop warnings, not one. (affects PF-05)

PF-05 says `verify-containers.sh` is the one copy whose `warning()` has no counter. Measured:

```
verify-containers.sh     DOES NOT COUNT
verify-vm-host.sh        DOES NOT COUNT
verify-vm-guest.sh       counts
verify-desktop-tools.sh  counts
verify-asus-hardware.sh  counts
```

The `fail()` divergence PF-05 also claims is real: the shared library's `fail()` returns 1, the
hand-rolled copies return 0, so `fail x || handle` behaves differently between the two dialects.

### C-3. The unchecked-rows denominator is 40, not 46. (affects parity-3, REG-3)

parity-3 reports "18 of 46 implemented rows", REG-3 reports "18 of 40". Recomputed from the
real files: 40 implemented rows declare a non-`-` packages column, 18 of them have no
`CAPABILITY_INSTALLERS` entry. **45% of package-declaring rows are unchecked**, not 39%.
parity-3 also claims the fabricated package reaches the generated doc at 3 occurrences; it
reaches 1. Both entries describe one defect and are merged into RA-04.

### C-4. The two documented Neovim floors disagree with each other. (affects R-01, PF-06)

Neither dimension noticed this. `docs/testing.md:17` states the floor as `>= 0.10`;
`docs/platforms/README.md:27` states it as `0.12+`, and `docs/workflows/editor.md:8` says "this
configuration requires 0.12 or newer". So the repository documents two different floors for the
same tool in three places, and enforces neither at install time. Whatever registry the fix puts
the floor in has to reconcile the three pages, not just feed one of them. Merged into RA-30.

### C-5. The library load-order failure is a false negative, not a silent wrong path. (affects undocumented-common-sh-load-order)

The finding claims sourcing `capabilities.sh` alone "resolved CAPABILITY_MANIFEST to the wrong
path `/config/capabilities.tsv` with no error". Under `set -u` — the policy every entry point
uses — it dies with `DOTFILES_ROOT: unbound variable`, which is a loud, correct failure. The
silent-path case needs nounset off.

The genuinely dangerous half of the finding is `preflight.sh`, and it is worse than a wrong
path. Sourced alone under `set -u`:

```
$ bash -c 'set -u; source common/lib/preflight.sh; preflight_commands ls'
common/lib/preflight.sh: line 13: command_exists: command not found
Missing preflight command: ls
```

A preflight that reports the present command `ls` as missing is a false negative in the
component whose whole job is to refuse before mutating. `preflight.sh` is also the only one of
the three files with no header comment at all. The fix should be scoped to that, not to
documentation parity with `fetch.sh`.

### C-6. Nine entries are duplicates.

| Merged entries | Kept as |
|---|---|
| installer-1, REG-2, install-options-not-cross-checked, parity-1 | RA-01 |
| parity-3, REG-3 | RA-04 |
| PF-02, R-02, macos-login-shell-false-pass | RA-10 |
| F5, PF-05 | RA-21 |
| R-01, PF-06 | RA-30 |

This is a property of the 14-dimension method, not a defect in it: independent dimensions
converging on the same file is corroboration. But it inflates a "45 findings" headline by a
fifth, and the fixes are one change each, not four.

## 3. The section-5 thesis holds, and it is the largest cluster

The interim report's central claim — *in several key places the registries describe the code
rather than govern it* — was flagged as the first thing to re-check because seven findings
depended on it. It survives, and I reproduced it four separate ways against the real tree. Each
run below executed **all 7 validators and all 8 `--check` renderers**.

**Parser gains a flag the registry never hears about.** Added a working `--turbo`/`--no-turbo`
boolean to `platforms/fedora/install.sh`'s case block, with its own initialised variable:

```
7/7 validators PASS, 8/8 render --check gates PASS
```

**Registry gains an option the parser never implements.** Appended one row to
`config/install-options.tsv`, regenerated the docs as the lint error message itself instructs:

```
7/7 validators PASS, 8/8 render --check gates PASS
docs/reference/installer-options.md:41 documents `--fooopt` / `--no-fooopt` as a real option
$ ./install.sh --platform fedora --dry-run --non-interactive
ERROR: Persistent installer option was never recorded: fooopt
```

Every Fedora install is bricked, and the gate that exists for this document is green.

**Registry enumerates a value the runtime rejects.** Added `oled` to the `theme` row's `values`:

```
7/7 validators PASS, 8/8 render --check gates PASS
docs/reference/installer-options.md now presents `latte|frappe|macchiato|mocha|oled`
$ bash platforms/fedora/install.sh --dry-run --theme oled
ERROR: Invalid Catppuccin flavour: oled
```

**Registry loses a row the installer still offers.** Deleted the `hardening`/`fedora` row:

```
validate-capabilities.py rc=0
--dry-run still plans "3. [hardening] Install the optional conservative security-hardening profile"
```

The one check that catches it, `capability_validate_selection`, is real and works — I called it
directly and it fails correctly — but `--dry-run` returns before preflight, so the fast path
most likely to be run in CI or by a maintainer never reaches it.

The fix shape is the same in all four directions and the repository already proves it works:
`validate-capabilities.py` cross-checks `platforms/macos/Brewfile` against the registry's
packages column, 23 entries, zero drift. The machinery exists. It stops at the argv parser.

## 4. Finding-by-finding verdicts

Severity is the interim report's, adjusted where verification changed the picture. `[NC]` marks
a finding I confirmed by live negative control.

### Registry ↔ implementation closure — WS-H

- **RA-01** *(High)* `[NC]` No gate compares a platform's argv parser with `config/install-options.tsv`, in either direction. Four independent reproductions in §3. Merges installer-1, REG-2, install-options-not-cross-checked, parity-1.
- **RA-02** *(High)* `[NC]` A `kind=value` option's enumerated `values` are never checked against the runtime enum in `common/lib/theme-selection.sh:35-39` and `common/setup-local.sh:16-22`.
- **RA-03** *(High)* `[NC]` Deleting an implemented capability row is undetected, and `--dry-run` never calls `capability_validate_selection`.
- **RA-04** *(Medium)* `[NC]` `CAPABILITY_INSTALLERS` is a hardcoded dict in Python, not registry data; `if installers is None: continue` makes absence indistinguishable from "nothing to check", silently skipping 18 of 40 package-declaring rows. A fabricated package on `ai`/`fedora` validates clean and is published into the generated package-ownership doc as fact. The sibling `ARRAY_OWNERS` dict *does* have a completeness check; this one has none.
- **RA-05** *(Medium)* `[NC]` The `stow` column drives preflight conflict detection; the `packages=(…)` arrays drive what is actually stowed; nothing compares them. Removing `,ghostty` from the base/fedora cell while `common/stow.sh:45` still stows it leaves every gate green and silently narrows preflight.

### Duplicated truth inside shell — WS-I

- **RA-06** *(High)* `[NC]` `platforms/fedora/install.sh` states the 16-element capability selection twice (`:182`, `:295`); I confirmed the two lists are byte-identical today and that deleting one entry from `:295` alone passes `bash -n` and all 15 gates. `:182` governs preflight, `:295` governs the durable record `./doctor` and `--rerun` read. `fedora-wsl` repeats it. macOS already solved this with `macos_selected_capabilities()`.
- **RA-07** *(High)* `[NC]` `capability_field_number()` hardcodes 15 column positions never checked against the file's header, while the Python validator *does* check its `FIELDS` list. Pointing `CAPABILITY_MANIFEST` at a manifest with `cli_flag` and `default` swapped returns `auto` for `cli_flag` and `--kde` for `default` — silently, exit 0.
- **RA-08** *(Medium)* Each `plan_add` note restates its `apply_` function's command as a hand-written literal ~24 lines away. `render-install-flows.py`'s regex captures id, label and phase only, so the note is covered by nothing. macOS's `macos_ai_args()` is the fix pattern, already written.
- **RA-09** *(Medium)* The `config/fedora-command-providers.tsv` + closure-validator pattern covers `fedora` and `fedora-wsl` only. macOS (`install.sh:147`) and Parrot (`install.sh:81`) still carry unregistered literal `preflight_commands` lists.

### Test harness can report false success — WS-J

- **RA-10** *(High)* `[NC]` `tests/lib/test.sh`'s `_test_die` prints and returns 1 with no accumulator and no trap, so whether a failure fails the suite depends on the caller's shell policy. I neutralised `macos_login_shell_change_required` — the exact function the suite exists to test — and `tests/test-macos-login-shell.sh` printed 3 `TEST FAILURE` lines, then `macOS login-shell policy tests passed.`, and exited **0**. See correction C-1 for the corrected scope.
- **RA-11** *(High)* `[NC]` `check_mise_owned`'s configured-login-PATH shadow branch (`common/lib/verify.sh:307-311`) — the design-principle-2 enforcement — has no coverage. Replacing those five lines with `true` leaves `tests/test-verifier.sh` exiting 0. The fixture creates `configured-login-bin` but never puts a shadowing binary in it.
- **RA-12** *(Medium)* The Terra fingerprint gate, the repository's most consequential security control, is covered by two `assert_file_contains` substring checks. `ensure_terra_repository` and `terra_pinned_fingerprint` are invoked by no test.
- **RA-13** *(Low)* `tests/test-parrot-ctf.sh:236` brace-expands a `template.toml` that no longer exists; `if grep; then fail; fi` treats the open error identically to "pattern absent", and every run prints a spurious stderr line.
- **RA-14** *(Low)* `tests/test-install-rerun.sh:207` hardcodes `charge-limit` as the last Fedora option. It is, today. Appending any row to the manifest fails an unrelated suite with `fixture did not drop a trailing option`.
- **RA-15** *(Low)* `tests/test-theme-hooks.sh` asserts Parrot installs no theme hook and contains zero `macos` references, though the doc makes the identical claim for both.

### The verify direction — WS-K

- **RA-16** *(High)* `[NC]` `check_command` proves PATH resolution only. `check_command_runs` exists at `common/lib/verify.sh:88` and is called from nowhere in the repository — dead code. A stub that always exits 127 is reported `✓ PASS` with `VERIFY_FAILURES=0`.
- **RA-17** *(High)* `check_system_service_active` tests `is-active` only. firewalld (`verify.sh:142`, `verify-hardening.sh:153`) and auditd (`:261`) pass while disabled, so a machine can verify clean and boot with no firewall. The repository already uses `is-enabled` for containers, tailscale, asus and dnf5-automatic — this is an inconsistency, not a missing idea.
- **RA-18** *(High)* macOS's verifier has **0** occurrences of `mason`, `catppuccin` and `theme`, against fedora's 17/25/62, WSL's 16/1/6 and Parrot's 10/4/11 — while `platforms/macos/install.sh:208,209,224` installs all three.
- **RA-19** *(High)* `check_mise_owned` is used for general runtimes in exactly one base verifier (`platforms/fedora/scripts/verify.sh:469`). fedora-wsl and macOS run the same tool list through PATH-presence checks, so a Homebrew or dnf duplicate shadowing a mise shim is undetectable — the scenario the function's own comment names.
- **RA-20** *(Medium)* Parrot's three package lists, parsed and diffed: installer 35, verifier 27, registry 36. Ten packages are installed and never verified — `build-essential ca-certificates curl python-is-python3 python3-dev python3-pip unzip xdg-utils zsh-autosuggestions zsh-syntax-highlighting`. The registry differs from the installer only by `mise`.
- **RA-21** *(Medium)* Six files define their own `pass()`; **none** sources `common/lib/verify.sh`, so none can call `check_symlink`, `check_mise_owned` or `check_easy_dotnet_debugger`. See correction C-2 for the divergences already present.
- **RA-22** *(Medium)* `curl`, `gnupg2` and `jq` are in the base/fedora packages column; the verifier's Core commands array omits all three, and `jq` is checked only inside the conditional Sway block at `:320`.
- **RA-23** *(Medium)* `grep -rn 'test-dev-workflows' .github/workflows/` returns nothing, while three `capabilities.tsv` rows name it as the `dev-workflows` verifier.

### Supply chain and privilege disclosure — WS-L

- **RA-24** *(High — raised from Medium)* `[NC]` The network-source gate selects files by extension, so **13 tracked shell scripts with no extension are never scanned**, including `doctor` and `bin/.local/bin/theme`. An unregistered `curl … | sh` appended to either passes with rc=0, while the same line in a `.sh` installer is caught. Separately, the two constructs that add a persistent package trust root on Fedora — `dnf config-manager addrepo --from-repofile=<url>` and `rpm --import <url>` — are absent from `NETWORK_PATTERNS` and also pass silently, though `platforms/fedora/lib/tailscale.sh:37` really uses the first one and is registered only because someone did it by hand. Raised because `docs/supply-chain.md:231` states the gate's coverage with no qualifier.
- **RA-25** *(Medium)* `gpgcheck` appears in exactly two files: the installer and a grep-test. No verifier and no `doctor` check asserts that the repo file Terra dropped still has `gpgcheck=1` or that the pinned key is still in the keyring; and `ensure_terra_repository` returns early on every rerun, so the fingerprint comparison never executes again after first install.
- **RA-26** *(Medium)* `install-vm-host.sh:149` runs `sudo usermod -aG libvirt`, which is root-equivalent; `docs/profiles/vm-host.md:43` — the only doc that mentions it — says the installer "never grants broad administrator permissions". The `warn` at `:150` mentions only the logout requirement.
- **RA-27** *(Low)* `install-hardening.sh:30-33`'s `--help` says "Nothing is mixed into a vendor config file"; `lib/hardening.sh:109` runs `sudo sed -i` on `/etc/selinux/config` with no backup and no content comparison — the one boot-relevant file in the profile, and the only one not using the file's own stage-compare-install helper.

### Install-time safety boundaries — WS-M

- **RA-28** *(High)* `preflight_stow_packages` is called from the four platform `install.sh` entry points only. `common/stow.sh` and every `platforms/*/scripts/stow.sh` — the scripts that own the mutation — contain **zero** `preflight` references, while the test suite invokes them directly 16 times and `docs/troubleshooting.md:26` claims without qualification that "Preflight runs before anything is changed, and refuses rather than half-installing". *(`stow` is not installed here, so I confirmed the structure, not the partial-HOME state; the interim report reproduced that.)*
- **RA-29** *(High)* `[NC]` `theme-hooks.sh:77,102,131` use `("$@") || status=$?`. Putting the subshell on the left of `||` disables errexit for its whole body, not just at its boundary. Driving a hook through the real `theme_hook` machinery with a failing statement followed by more code: the later code ran, the later `theme_action` ran, and the command reported full success with exit 0. The two existing regression fixtures both fail on their *last* statement, which is the one case that still propagates. The real Fedora hook opens with an unguarded top-level `source`.
- **RA-30** *(Medium)* `scripts/test.sh:141-155` preflights with `command -v` only; `grep -cE 'version|--version'` returns 0 for both `test.sh` and `lint.sh`. `common/install-neovim-tools.sh:8` is a bare `require_command nvim` with no version test, and only Parrot's verifier asserts a floor. `docs/testing.md:11-12` claims both entry points "preflight their own dependencies rather than failing partway through". See correction C-4: the documented floor is stated twice, differently.
- **RA-31** *(Medium)* `profile_state_validate_value`'s catch-all charset rejects `git@host:~user/repo.git` and `ssh://git@host/~/repo.git`. `install_repository_url` passes the remote through unsanitised and `profile_state_write` calls `die`, at `install-lifecycle.sh:297` — immediately before `plan_execute` — so the install aborts before any package is touched, reporting only `Invalid state value for repository`.
- **RA-32** *(Medium)* See correction C-5. `preflight.sh` sourced without `common.sh` reports a present command as missing rather than failing.
- **RA-33** *(Medium)* `common/lib/preflight.sh` defines exactly four checks and contains zero disk-space or connectivity probes, so those two failure modes are caught only after a mutating step has partly run.

### Schema hygiene and remaining parity — WS-N

- **RA-34** *(Medium)* `[NC]` Five Python readers pass `QUOTE_NONE`; fourteen `DictReader` call sites do not; every shell reader uses `awk -F '\t'`. The same bytes parse three ways: default quoting swallows an embedded tab into one field, `QUOTE_NONE` splits it into two, `awk` reports `NF=5`. `config/actions.tsv:34` already carries a value that begins with a double quote. Separately, appending a 16th column to a `capabilities.tsv` row is accepted by every gate — the header is checked, per-row arity is not.
- **RA-35** *(Low)* `[NC]` `config/shell-file-roles.tsv:22` blanket-claims `scripts/*.sh` as `deprecated-wrapper`. A new, freshly added `scripts/` helper with no deprecation call passes `validate-shell-file-roles.py` with rc=0 — silently classified as a wrapper marked for deletion — in the one directory most likely to gain files, and against the validator's own docstring promise to make an unclassified file loud.
- **RA-36** *(High)* Three plugin fragments declare `init` on `"LazyVim/LazyVim"`: the shared `colorscheme.lua` (which holds the repository's only `FocusGained` autocmd, at `:44`) and the macOS and WSL overlays. `init` is not one of lazy.nvim's merged keys and the overlays sort after `colorscheme` alphabetically, so the platform `init` wins and the documented reload is dead on two of four platforms. `docs/workflows/theming.md:195` and `docs/troubleshooting.md:144` both promise the behaviour. *(`nvim` is absent here; mechanism verified by reading, not by resolving the spec set.)*
- **RA-37** *(Low)* `platforms/windows/install.ps1:278` catches every exception from `Start-Process -Verb RunAs` identically. A declined UAC prompt (`Win32Exception`, `NativeErrorCode` 1223) is retried twice more, two seconds apart, each time warning that the user's deliberate choice "failed".
- **RA-38** *(Low)* `sway-workspace-grid:16-19` silently coerces an out-of-grid workspace to `1` and moves you; `aerospace-workspace-grid:13-17` refuses and says why. `config/actions.tsv:10,42` describe both with the same sentence. Aerospace also forces base 10 (`10#$current`); Sway does not.
- **RA-39** *(Medium)* The theme-hook extension contract — that hooks are *sourced* inside a subshell, run in glob order, inherit `$flavour`/`$preserve_wallpaper`/`$DOTFILES_ROOT`, and may call six boundary functions — appears nowhere in `docs/`. `grep -rc 'theme_action_required\|theme_capability_permits' docs/` returns 0 files.

## 5. What verification did not change

The interim report's assessment of what the rearchitecture fixed is not re-litigated here and I
found nothing contradicting it. Two of its strengths I re-confirmed incidentally while running
negative controls: the validator and renderer suite is fast, deterministic and exits 0 on the
clean tree (7 validators, 8 `--check` gates), and `validate-capabilities.py`'s Brewfile
cross-check is genuinely load-bearing — it is the model every finding in WS-H asks to be
extended, not replaced.

The report's own closing observation is the right summary and survives verification intact:
**the registry covers the install direction and the documentation direction, and stops at the
verify direction and at the argv parser.** WS-H and WS-K are those two gaps.


## 6. Where these findings went

Grouped into seven workstream issues, continuing the repository's `WS-A`…`WS-G` lettering from
the documentation audit. Ordering is deliberate: WS-H is the largest cluster and the one the
rest of the registry work depends on.

| Workstream | Theme | Findings | Issue |
|---|---|---|---|
| WS-H | Close the registry↔parser loop | 5 (3 High, 2 Medium) | [#242](https://github.com/KasperElbo/dotfiles/issues/242) |
| WS-I | Facts the shell states twice | 4 (2 High, 2 Medium) | [#243](https://github.com/KasperElbo/dotfiles/issues/243) |
| WS-J | Tests that cannot fail | 6 (2 High, 1 Medium, 3 Low) | [#244](https://github.com/KasperElbo/dotfiles/issues/244) |
| WS-K | The verify direction | 8 (4 High, 4 Medium) | [#245](https://github.com/KasperElbo/dotfiles/issues/245) |
| WS-L | Supply chain and privilege disclosure | 4 (1 High, 2 Medium, 1 Low) | [#246](https://github.com/KasperElbo/dotfiles/issues/246) |
| WS-M | Error boundaries and install-time safety | 6 (2 High, 4 Medium) | [#247](https://github.com/KasperElbo/dotfiles/issues/247) |
| WS-N | Schema hygiene and remaining parity | 6 (1 High, 2 Medium, 3 Low) | [#248](https://github.com/KasperElbo/dotfiles/issues/248) |

Cross-workstream dependencies worth respecting: RA-05 (WS-H) before RA-28 (WS-M), so the stow
preflight reads one list rather than two; RA-11 (WS-J) before RA-19 (WS-K), so the shadow branch
is tested before three more verifiers depend on it; RA-12 (WS-J) and RA-25 (WS-L) share their
stub scaffolding; RA-29 (WS-M) before RA-39 (WS-N), because the doc has to state the corrected
errexit semantics; and RA-30 (WS-M) needs the 0.10-versus-0.12 contradiction settled before its
fix can be written at all.
