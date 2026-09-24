# Verification and installation testing

The repository deliberately separates **fast mocked/contract evidence** from
**real-environment installation evidence**. A green mocked suite is not treated
as proof that a clean machine can install, survive a new login, or converge on
a second run.

## Contributor toolchain

`./scripts/lint.sh` and `./scripts/test.sh` are the two entry points a
contributor runs locally before opening a pull request, and both preflight
their own dependencies rather than failing partway through. The tools they
expect, matching `./scripts/test.sh`'s aggregate preflight list and the
`.github/workflows/validate.yml` `repository` job's installed packages:

| Tool | Minimum version | Used by |
| --- | --- | --- |
| ShellCheck | any version supporting `-S warning` (`./scripts/lint.sh` pins the severity threshold so info-level notes never fail CI on version drift) | `./scripts/lint.sh` |
| Neovim (`nvim`) | >= 0.12 | `./scripts/test.sh` preflight and the Neovim/editor suites |
| Bash (`bash`) | >= 4.4 | every entry point and suite; `./scripts/test.sh` preflight, and the macOS bootstrap re-executes under one |
| zsh | any recent release | shell-startup and profile suites |
| GNU Stow (`stow`) | any recent release | install/stow suites |
| OpenSSH client tools (`ssh`, `scp`, `sftp`) | any recent release | SFTP/remote-access suites |
| Python 3 (`python3`) | >= 3.11 | every `scripts/*.py` validator and generator |
| jq | any recent release | JSON-fixture and action-registry suites |
| ripgrep (`rg`) | any recent release | `./scripts/test.sh` preflight and search-based checks |
| lazy.nvim | the revision [`nvim-lazyvim/.config/nvim/lazy-lock.json`](../nvim-lazyvim/.config/nvim/lazy-lock.json) pins | `./scripts/test.sh` preflight and the Neovim spec-resolution suite. A checkout, not a command — see below |

`./scripts/test.sh` also preflights `awk`, `curl`, `find`, `getent`,
`git`, `grep`, `mktemp`, `sed`, `sha256sum`, `timeout` and `unlink`, which are
assumed already present on any supported development machine. The list is the
whole set the default suites reach for, not the memorable part of it: a command
that is missing from the preflight does not go unnoticed, it surfaces halfway
through the run as one suite's failure, naming the tool but not the policy.

Every minimum version in that table comes from
[`config/tool-floors.tsv`](../config/tool-floors.tsv), which is the one place
a floor is stated for a tool the toolchain preflights. `./scripts/test.sh` and `./scripts/lint.sh` check it in
their preflight, `common/install-neovim-tools.sh` checks it before the first
headless Neovim phase, and each platform verifier asserts it on an installed
machine, so a tool below its floor is named here rather than failing later
inside a suite or a Mason build. `./scripts/validate-tool-floors.py` fails the
build if this table and that registry disagree, if a consumer stops reading it,
or if a mise configuration this repository provisions pins a tool below its own
floor. "Stops reading it" is decided by reading the consumer as shell: the
reader has to be the word that starts a command, in a code path the file
reaches, so a mention in a comment, inside a string, or in a function nothing
calls does not count. How that code path is written makes no difference:
`tool_floor_check nvim || exit 1` and `if ! tool_floor_check nvim; then exit 1;
fi` both enforce the floor, and a function whose brace sits on its own line is
as uncalled as one whose brace does not. The reader names are derived from
[`common/lib/tool-floors.sh`](../common/lib/tool-floors.sh) rather than written
into the validator, so renaming one cannot leave the check hunting for a name
that no longer exists. A mise pin is read the way mise reads it: the key may be
backend-qualified, and the version is a prefix rather than an exact number, so
a pin of `3` provisions the newest 3.x and satisfies the floor above. A pin the
check cannot interpret fails the build rather than being skipped.

The Bash floor is in the registry, but four of its consumers cannot read it:
[`scripts/bootstrap-macos.sh`](../scripts/bootstrap-macos.sh),
[`common/lib/modern-bash.sh`](../common/lib/modern-bash.sh),
`scripts/install-main.sh` and `platforms/macos/install.sh` decide it while the
shell may still be Apple's 3.2, before the reader library -- which needs the
Bash in question -- can be sourced. So each compares `BASH_VERSINFO` itself,
and the validator evaluates every such comparison for the version it actually
admits and holds that, and every message or constant restating the number, to
the row. A comparison outside the tests in a file the row does not name is
refused, so a fifth copy cannot drift unseen.

One minimum this repository enforces is deliberately stated where it is
enforced instead, because it is not a tool the toolchain provisions or
preflights. The kernel minimum in
[`platforms/fedora/scripts/install-asus-hardware.sh`](../platforms/fedora/scripts/install-asus-hardware.sh)
belongs to the distribution rather than to this repository, which can refuse to
enable the hardware but cannot raise it.

lazy.nvim is the one entry in that table that is not a command, which is why it
is spelled out here rather than left to the preflight's command list.
`tests/test-neovim-tool-ownership.sh` resolves this repository's plugin
fragments through lazy.nvim itself instead of reading them, so a checkout is a
hard requirement of that suite: a missing one fails it and is never skipped.
Both the suite and `./scripts/test.sh`'s preflight resolve the path through
`lazy_nvim_checkout` in [`tests/lib/lazy-nvim.sh`](../tests/lib/lazy-nvim.sh),
so there is one rule -- `DOTFILES_LAZY_NVIM` when it names a checkout, and
otherwise the one a normal install already leaves in
`${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/lazy.nvim`. Two copies would be
two chances for the runner to preflight a path the suite does not use, which is
worse than not preflighting at all: the run would be refused for a checkout that
is present, or admitted for one that is missing.

An aggregate run refuses up front when that checkout is absent, in the same
"no suites were run or credited as skipped" terms the command and floor failures
use, and says how to get one. Before that, the requirement bypassed the
preflight entirely, because the preflight only understood names on `PATH`: one
suite out of eighty-odd failed in the middle of a long run on a machine that
satisfied every documented tool, naming lazy.nvim but not the policy -- the
exact failure mode the command list exists to prevent. The `repository` job
clones the pinned revision and exports `DOTFILES_LAZY_NVIM`, so the gap was
invisible on pull requests and visible only to a contributor running the
documented command. A targeted run is unaffected: each selected suite reports
its own dependencies, and refusing one over a checkout it does not need would be
the same defect pointing the other way.

The run also states how many suites it is about to run, read off the array
rather than quoted from anywhere. The count in circulation was 89 while the
runner ran 82, which matters whenever that number is used as a coverage claim.

`scripts/test-installer.sh` is a deprecated compatibility alias that forwards
to `./scripts/test.sh` unchanged; use `./scripts/test.sh`.

## Fast PR validation

`.github/workflows/validate.yml` is the workflow that runs on every pull
request and on pushes to `main`. It has four independent jobs:

| Job | Runner / image | What it runs |
| --- | --- | --- |
| `repository` (Repository validation) | `ubuntu-latest`, inside a pinned `fedora:44` container | `./scripts/lint.sh`, then a clone of the lazy.nvim revision `nvim-lazyvim/.config/nvim/lazy-lock.json` pins, `./scripts/test.sh`, and a whitespace check (`git diff --check`) against the PR's base |
| `cheatsheets` (Printable cheat sheets) | `ubuntu-latest`, inside the same pinned `fedora:44` container, with a LaTeX toolchain installed | `./docs/cheatsheets/verify.sh`, then asserts the compiled PDFs are left untracked |
| `windows` (Windows PowerShell validation) | `windows-latest` | PSScriptAnalyzer at the pinned version, then `tests/test-windows-static-analysis.ps1`, `tests/test-windows-bootstrap.ps1`, `tests/test-windows-verifier.ps1`, and a `verify.ps1` smoke test against a fixture |
| `macos` (macOS 26 arm64 validation) | `macos-26` | `tests/integration/macos-dotnet-debug.sh`, `./scripts/lint.sh`, portable-verifier/shell-test/profile-state suites, a `--dry-run` macOS install, `tests/test-macos.sh`/`tests/test-macos-ai.sh`/`tests/test-ocaml-verification.sh`, and the same ranged whitespace check the `repository` job runs |

PowerShell's static analysis lives in the `windows` job rather than in
`./scripts/lint.sh`, because that script runs in a Fedora container with no
`pwsh` and a lint step that quietly skips itself when its tool is missing reads
as a pass forever after. The rules are
[`PSScriptAnalyzerSettings.psd1`](../PSScriptAnalyzerSettings.psd1) at the
repository root, which editors with PSScriptAnalyzer support read as well, and
each exclusion in it states why the rule does not apply here.
`tests/test-windows-static-analysis.ps1` analyses the PowerShell files
`git ls-files` reports rather than a list of its own, so a new `.ps1` cannot be
added outside the gate, and it then analyses fixtures that must be reported -- an
unapproved verb, a reversed `$null` comparison, a file that does not parse -- and
fixtures each exclusion must silence, so a rule set that had stopped applying
cannot pass as a clean tree. The analyser version is pinned on both sides: the
job installs it and the suite refuses to run against any other, so a runner
image that already ships a different PSScriptAnalyzer cannot supply it instead.

`./scripts/test.sh` is the normal aggregate runner that the `repository` job
above invokes. It:

- preflights the normal Linux aggregate toolchain before the default suite set;
- runs independent suites to completion by default, each under a per-suite
  `timeout` (900 seconds, `DOTFILES_TEST_SUITE_TIMEOUT`, `0` to disable), so a
  suite that hangs is killed and counted as failed instead of stalling the run
  until the job's own limit ends it with no summary at all;
- reports passed, failed, and skipped suites in one final summary;
- exits non-zero when any required suite fails;
- accepts `--fail-fast` for local debugging;
- accepts explicit suite paths for targeted debugging without requiring
  unrelated aggregate-only tools;
- refuses a suite path that resolves outside this checkout's `tests/`
  directory, absolute or through `..`, before anything is executed. The runner
  is a general-purpose executor of the path it is handed, and
  `.claude/settings.json` pre-approves `./scripts/test.sh tests/...` for agent
  sessions opened in this repository — a rule an agent matcher reads as a
  prefix. Without containment the two compose into a standing approval to run
  any file on the machine, and the refused path is counted as a failed suite
  rather than credited as a passing one.

`DOTFILES_TEST_REQUIRED_COMMANDS` can be set to request runner-level dependency
preflight explicitly. Missing commands in that list are a **runner error**, not
a skip and never a pass. Individual targeted suites remain responsible for
reporting dependencies specific to themselves.

Every `tests/test-*.sh` must appear in the runner's `default_tests` array, and
`tests/test-test-runner.sh` compares the directory with the array and fails
naming any file that does not. Nothing used to require that: a new suite that
always failed passed every validator, because no check looked at the two lists
together, so a suite could be written, forgotten and never run once.

These tests use isolated homes, strict mocks, disposable directories and
containers where appropriate. Their output is labelled
`mocked/unit/contract evidence` because they do not replace clean-machine tests.

### Shared shell-test contracts

Shell suites should source `tests/lib/test.sh` instead of defining another
temporary-root, assertion, capture, or privileged-command framework. The
library creates per-suite HOME/XDG roots and provides one generic exact-argv
stub: `test_stub_install <root> <name>` installs a strict stub for any command
a suite needs — `sudo`, `dnf`, `systemctl`, `git`, `curl` and `mise` are the
usual ones, but the list belongs to each suite, not to the library. A stubbed
command is rejected with status 96 unless the suite explicitly registers its
complete argument vector with `test_stub_allow`.

A fixture that a suite writes by hand follows the same rule as the shared stub:
it refuses an invocation it was not taught, with status 96 and a line naming the
argv it refused. A fixture whose unknown branch falls through to `exit 0`
answers for a command nobody wrote it for, and does it silently. Every mise
fixture in `tests/` did this in some degree: `tests/test-fedora-wsl.sh` and
`tests/test-idempotency.sh` fell off the end of their `if` chains, so adding a
mise call to the installer returned success and no output and both suites
stayed green. Inside those two, three real calls were already being answered
that way -- `--yes install` installed nothing and reported success, bare `mise
ls` satisfied the Fedora verifier's "mise configuration loads successfully"
check without loading anything, and `--version` returned an empty string.
`tests/test-shell-startup.sh` handed its activation script to any argv at all,
and `tests/test-parrot-verification.sh` ran every `mise exec` target as Neovim,
so the bounded start's `timeout` options arrived as Neovim's own arguments.

A refusal also has to be distinguishable from an answer. Exiting 1 is what a
`mise which` fixture says about a tool it does not have, so a bare `exit 1` for
an unknown verb reads as an ordinary negative; 96 with the argv printed is the
shared stub's convention and says what actually happened. The one deliberate
exception in the tree is the recorder in `tests/test-fedora-verification.sh`,
which answers everything identically because what that case asserts is the
directory and ceiling each call ran in, read back from its log: an untaught
call still lands in the log and is still asserted against. It says so in place.

Stateful behavior remains visible in the owning suite. After the shared stub
has logged and accepted an invocation, it executes an optional handler at
`$TEST_STUB_ROOT/handlers/<command>`. Handlers may model such things as login
shell changes or system/user service state; they do not widen the allow-list.
This keeps command policy centralized while leaving domain fixtures auditable.

Every suite that sources the library calls `test_install_cleanup_trap` near the
top. Its EXIT trap removes the test roots and fails the suite when any assertion
failed, even if the suite runs without errexit or swallowed an assertion's
status, so a `TEST FAILURE` line can never sit above a passing exit. Assertions
still return 1, so errexit suites stop at the first failure. A suite that needs
extra cleanup, such as restoring a tracked file a negative case edited in place,
passes a function name to `test_install_cleanup_trap` instead of installing its
own EXIT trap; `tests/test-test-support.sh` enforces both rules.

A test never pipes into a quiet grep, in either direction. `grep -q` exits at
its first match, which leaves the producer writing to a closed pipe: it takes
SIGPIPE and exits non-zero, and under `set -o pipefail` that is the pipeline's
status. The pipeline then says something about the writer rather than about the
match, and it says it in exactly the case the assertion exists to detect. Both
directions are wrong, in opposite ways:

```
producer | grep -Fq needle || _test_die  # fails when the needle IS present
if producer | grep -Fq needle; then ...  # does nothing when it IS present
```

The first fired once for real, on a loaded machine, and blamed the data rather
than the pipeline. The second is the worse of the two, because it fails open --
it reports no violation, and several assertions of that shape are the negative
controls that prove a validator still catches drift:

```
$ bash -c 'set -o pipefail
>   if seq 1 200000 | grep -q "^1$"; then echo CAUGHT; else echo MISSED; fi'
MISSED
```

Both survive only while the producer is small enough to finish before grep
exits, which is the property that changes under load. Read the producer into a
variable and match against a here-string instead
(`result="$(producer)"; grep -Fq needle <<<"$result"`), or, where the test only
asks whether the producer emitted anything at all, capture it and test
`[[ -n "$result" ]]`. `tests/test-test-support.sh` enforces this across every
suite through `tests/support/check-quiet-grep-assertions.py`, which finds the
pipelines by tokenising the suites as shell rather than by matching their text,
and carries a control that demonstrates the fail-open case itself.

A negative assertion says what a producer did not contain, so it is only worth
anything once the producer has been shown to contain something. Several in this
repository were searching an empty set and passing for that reason alone: one
grepped the Neovim configuration for `BufWritePre`, a string that appears
nowhere in it; one used a Lua pattern with a `|` in it, which Lua has no
alternation for, so it searched for a literal 32-character string no name could
contain; one looked for a tab-delimited registry fragment of a shape that file
never has. Each named exactly the leak it was meant to catch, and none of them
could have caught it.

So an assertion of the form "X does not appear in Y" carries a guard that fails
when Y is empty, and says in its message that the check would otherwise be
proving nothing:

```
commands="$(derive_the_set)"
[[ -n "$commands" ]] || _test_die 'no commands were derived, so the audit proves nothing'
assert_not_contains "$commands" "$forbidden"
```

`tests/test-macos-command-surface.sh` and `tests/test-sway-config.sh` are the
worked examples. Where the forbidden construct is absent from the tree by
design, so no live guard is possible, the suite plants it in a scratch copy and
asserts the reader reports it -- `tests/test-json-workflow.sh` does both, and
its permanent negative control is what keeps the two halves honest. The same
rule applies to the search itself: prefer a plain-text comparison to a pattern
language whose syntax the assertion does not actually use, and give a tool that
could be missing an explicit requirement rather than an `|| true` that reads its
absence as a clean result.

A reproduction can manufacture the defect it claims to find, which is the third
way a test lies about its subject. #368 reported that `plan_preflight`
suppressed errexit through the action it runs. It does not: Bash exempts a
command in an `&&`/`||` list only up to the final operator, and the action sits
after it. The reproduction wrapped the call as
`plan_preflight && status=0 || status=$?`, which is itself a suppressing
position, so it measured its own harness and reported the behaviour it had
created. Two threads drove the real function before the issue was closed as not
reproducing.

So a claim about `errexit`, `pipefail`, `nounset`, a subshell, an exit status or
a truthiness coercion begins with a negative control that drives the real
function from its real call shape -- the way its callers actually write it,
never inside a condition or an `&&`/`||` list, and in its own process when the
status of an aborted statement is the thing being measured. A control that
cannot be made to fail before the fix refutes the finding rather than confirming
it.

The same class has a second shape, where the manufactured part is the
specification rather than the harness. An issue argued that a Windows shim
resolved to the wrong file because `PATHEXT` prefers `.EXE` to `.PS1`. `PATHEXT`
is cmd.exe's mechanism; PowerShell resolves an ExternalScript ahead of an
Application, so a bare name finds the `.ps1` first, and the comment naming
`PATHEXT` was the only defect there. The validation pass repeated the premise
instead of testing it and carried the wrong specification forward as a reason to
expect a group of related findings to hold.

So a finding's evidence is the behaviour of this code on this platform,
observed. A citation -- `PATHEXT`, POSIX, a man page, a vendor doc -- is a
hypothesis to check against the thing that actually runs, because a real
documented behaviour of the wrong system reads exactly like evidence.

A suite whose code under test probes for tools on `PATH` calls
`test_isolate_path [command ...]` right after that trap. It replaces `PATH` with
one directory linking only a small portable base userland plus the host commands
the suite names (for example `git`, `jq` or `zsh`), so a tool that happens to be
installed on the machine running the tests, such as a real `opam`, `mise` or
`tailscale`, cannot satisfy a lookup the suite meant to mock or to find absent.
Mocks go in front (`PATH="$mock_bin:$PATH"`); never append `/usr/bin` or `/bin`.
A named command the runner lacks fails the suite rather than silently narrowing
`PATH`. Host state that is not a command, such as the runner's user id or its
DNF repository files, is pinned the same way through the suite's mocks and the
product's override variables (`DNF_REPO_DIR`, `OS_RELEASE_FILE`,
`MACOS_APPLICATIONS_DIR`, ...). A check that names such a location outright
answers from the machine running the tests: the macOS verifier read
`/Applications` directly for Ghostty, AeroSpace and Tailscale, so those
checks passed on a maintainer's own Mac and failed on a Linux runner, and
which of the two a run reported had nothing to do with the tree under test. The goal
is the same result on a developer workstation as in the pinned CI container.
For example, `tests/test-hardening.sh` sets `HARDENING_ROOT` to its fake root so
the hardening profile's owned drop-ins are read and written there; without it, a
machine with the profile installed answers the suite's missing-drop-in checks
from its real `/etc`.

A suite that runs a platform verifier against a fixture the fixture cannot make
clean states which checks are allowed to fail, by name, through
`assert_verifier_failures <output> [prefix ...]`. Counting them is an open
assertion. The macOS fixture describes no Mac, so ten checks fail in it whatever
the tree does; while the suite held that run to a *number*, a check added to the
verifier that failed on every single run merely raised the number by one, every
case measured as "one more failure than the baseline" still passed, and nothing
anywhere observed that the new check had never once succeeded. That is what
happened to the Neovim plugin check in issue #371: it was green in CI from its
first commit and had never worked. Naming the set closes it -- a failure the
list does not describe is reported, whatever the count did -- and the count
still follows from the list, so the one-more-failure cases are unchanged.

Each declared entry is a prefix, because a verifier names the paths it looked at
and those carry the fixture's temporary root. A prefix must begin exactly one
failure line and every failure line must be begun by exactly one prefix: an
entry loose enough to cover two failures is the same open assertion in
miniature, so the assertion refuses it rather than accept a weaker version of
itself. `tests/test-test-support.sh` drives all four outcomes, including the
extra always-failing check as the negative control for #371.

The other three platform suites reach a run with no failures at all, which is
the same assertion with an empty list, and they keep their own form of it: the
Fedora verifier must come out clean at the end of the mocked bootstrap in
`tests/test-idempotency.sh`, and the Fedora WSL and Parrot fixtures must verify
cleanly in their own suites. A fixture that verifies cleanly needs no list; only
one that cannot must say why, entry by entry.

### Shared shell startup and ergonomics

`tests/test-shell-startup.sh` covers the shared Zsh profile (issues #157 and
#168). It sources the tracked `zsh/.zshenv` and `zsh/.config/zsh/.zshrc` in a
real `zsh -f` under a sandboxed HOME and asserts behavior, not configuration
text:

- sourcing startup three times leaves `PATH` byte-identical, with no duplicate
  entries and `~/.local/bin` still in front, on its own and layered under the
  Parrot and macOS platform PATH files;
- macOS keeps Homebrew coreutils `gnubin` as the last entry;
- a real `zsh -l -c` login that is not interactive, in a sandboxed home that
  carries `.zshenv` and `.zprofile` the way Stow links them, resolves `python`
  and `node` to mise's shims rather than to a system copy on the `PATH` it
  inherited: the shims sit behind `~/.local/bin` and ahead of that system
  directory, follow `MISE_DATA_DIR`, and are left out (silently) when the
  directory does not exist, while a plain `zsh -c` is unaffected. Under the
  simulated macOS `path_helper` they still lead the system directories, and
  an interactive login still resolves through `mise activate` first. Only the
  entries the fixture controls are compared, never a whole login `PATH`,
  since the host's own `/etc/zprofile` takes part;
- a shell with none of zoxide/fzf/mise/Starship on `PATH` still starts, stays
  silent, and reports the degradation only when `shell-integrations` is run;
- `compinit` is called exactly once, still against the cached compdump, and no
  platform file adds a second one;
- `menu select`, `INTERACTIVE_COMMENTS` on, `CORRECT` off;
- every editing/history key resolves to its intended widget under
  `xterm-256color`, `xterm-ghostty`, `screen-256color`, `tmux-256color`,
  `linux` and an unknown `TERM`, while plain `Left`/`Right` keep moving by
  character and `Ctrl-R` stays fzf's;
- `tar`/`untar` round-trip `.tar`, `.tar.gz`, `.tar.xz`, `.tgz` and `.txz`,
  while `tar -tf`, `tar -xf`, `tar --help` and `command tar` keep native
  behavior.

Terminal escape sequences themselves cannot be exercised from a shell fixture:
the suite asserts what each sequence is *bound* to, which is the part this
repository controls. What still needs one manual pass per new terminal is that
the terminal actually emits one of the bound sequences — press `Home`, `End`,
`Delete`, `Ctrl+Left`, `Ctrl+Right` and prefix-filtered `Up`/`Down` once in
that terminal.

`./scripts/benchmark-shell-startup.sh` measures interactive login,
interactive and non-interactive startup and can enforce a budget with
`--interactive-login-ms`, `--interactive-ms` / `--non-interactive-ms`. It is deliberately **not** in `./scripts/test.sh`:
wall-clock timing is machine- and load-dependent, so a timing assertion in the
fast suite would be a flaky gate rather than evidence.

### The Fedora WSL PATH sanitizer

`platform-env.zsh` strips Windows drive mounts out of `PATH`, which is the one
piece of behaviour that defines the Fedora WSL profile: without it Windows
executables resolve in the Linux development environment and `command -v`
starts answering with `.exe` shims. Until `tests/test-wsl-path-sanitizer.sh`
existed the only check on it was a `grep` for the case-arm text over the file's
own source, and `tests/test-fedora-wsl.sh` replaces `zsh` with a Bash stub that
computes `PATH` itself, so the tracked file was never interpreted by a shell in
any test. Inverting the case arm so the sanitizer *kept* every Windows path
left lint at 0 and the whole default suite green, printing "Fedora WSL
verification rejects a Windows entry the Zsh sanitizer hides" while the
sanitizer hid nothing (issue #384, PS-01).

The suite runs the tracked file under real Zsh with a seeded `PATH` and reads
the `PATH` that comes out: a mixed `PATH` keeps its Linux entries in order and
loses its Windows ones, a Linux mount point under `/mnt` that is not a drive
letter survives, and a `PATH` of nothing but Windows mounts is left unsanitized
with a reason on stderr rather than emptied — an empty `PATH` would leave the
login shell with no commands at all and nothing saying why. It ends with two
controls run against copies of the file, one with the case arm inverted and one
with the loop body removed, both of which must be rejected. A suite that cannot
be made to fail proves nothing about the file it names.

### Theme precedence and platform hooks

Two suites carry issue #148.

`tests/test-theme-precedence.sh` runs each platform installer with `--dry-run`
across the whole precedence matrix: first install, explicit `--theme`, a plain
rerun with an existing flavour, a missing theme file falling back to the
remembered selection, a record belonging to another platform, an invalid theme
file, and an unreadable or future-schema record. It also asserts that
`./install.sh --rerun --dry-run` reconstructs the remembered flavour as an
explicit `--theme` through the shared selection library, that a dry run changes
no theme or lifecycle state, and that transient execution controls never appear
in the persistent option manifest.

`tests/test-theme-hooks.sh` builds machines with a recorded capability set and
runs the real `theme` command against the real Fedora, Fedora WSL and macOS
hooks. It proves a `--no-kde` machine never runs a KDE apply command —
including when KDE assets are left over from an earlier install — that a
selected capability with missing assets is still skipped, and that a machine
with no recorded install decides by assets alone. For failure isolation it
fails one action and requires the independent ones after it to still run, the
failing one to be named, the shared state to be current, and the command to
exit 3 rather than claiming a complete application; a hook that calls `exit` is
contained the same way, while an unwritable shared state stops the command with
status 1. Two cases guard the boundary itself: a hook, and then an action
inside a hook, that fails on its first statement must stop there rather than
running to the end and being reported as applied. It also asserts that no
output claims a live Ghostty theme reload. The macOS hook runs under a stubbed
`osascript`, which proves the hook's asset selection and its one invocation per
flavour — and none under `--preserve-wallpaper` — but not that macOS accepted
the change; see
[the macOS desktop-wallpaper notes](platforms/macos.md#desktop-wallpaper).

### Generated Starship configurations

`tests/test-starship-themes.sh` owns the generated-prompt invariants (issues
#125 and #169). It asserts that each tracked
`starship/.config/starship/catppuccin-<flavour>.toml` selects one palette and
contains exactly that one `[palettes.*]` table, parses every output with a real
TOML parser, and checks that every colour name used in a style resolves against
the selected palette.

The drift gate runs against a disposable copy of the source and output trees:
the suite mutates that copy's common source and then its palette source, and
requires `--check` to fail, name the stale files, and leave the tree untouched.
It also proves generation is byte-identical when run twice and that the
generator fails closed on a source that would reintroduce multiple palettes.
`./scripts/lint.sh` runs `./scripts/update-starship-themes.sh --check` so the
same gate fails CI.

When `starship` is installed, the suite renders each flavour outside a Git
working tree and requires status `0` to show nothing while `1`, `2`, `126`,
`127` and `130` each show their exact number in the flavour's own red. Without
`starship` those assertions are reported as skipped rather than silently
passing.

### Supply-chain and transition suites

Three suites carry the invariants from the AI/mise/supply-chain workstream:

- `tests/test-supply-chain.sh` validates the network-source registry, proves
  the linter fails closed on a new unregistered `curl`/`wget`/PowerShell
  download, Git clone, container image, or new package trust root (a
  `dnf config-manager addrepo` or an `rpm --import`), including one added to
  an extensionless script the scanner selects by role or shebang rather than
  by suffix, rejects a registry row whose tier and integrity mechanism
  contradict each other, rejects a wildcard used as an exact pin, asserts no
  installer passes `--nogpgcheck` or pipes a download into a shell, proves the
  Fedora verifier's read-only Terra trust-root check against a mocked keyring
  and repository configuration, and exercises the bounded fetch policy (single
  successful attempt, bounded retry on a transient failure, clear terminal
  failure, empty-body rejection, non-HTTPS refusal, digest and shape
  rejection).
- `tests/test-mise-context.sh` copies `tests/fixtures/unrelated-project`,
  whose `.mise.toml` declares a sentinel tool, and runs the real global and
  AI bootstraps from inside it, from a nested directory inside it, from
  `$HOME`, and from the dotfiles checkout. The resolved tool set must be
  identical every time and must never contain the sentinel. The fixture
  first proves it *can* see the sentinel without isolation, so the test
  cannot pass vacuously. The same suite holds verification to its read-only
  promise: it snapshots the context tree (path and content digest per entry)
  around a real verifier run against a clean context, a missing one, and one
  contaminated with each of the four filenames mise reads as directory
  configuration, and requires the snapshot to come back identical and the
  contamination to be reported. Its negative control performs the forbidden
  mutation deliberately and requires the snapshot to notice, so the
  "unchanged" assertions cannot pass on a comparison that sees nothing.
  `tests/test-macos-verification.sh` and `tests/test-parrot-verification.sh`
  carry the same case against those platform verifiers.
- `tests/test-ai-transitions.sh` walks the full optional-component matrix:
  fresh core-only install, add one component, no-op rerun, full install,
  rerun omitting an installed component, dry-run preview, declined removal,
  explicit removal, a removal refused because the target was user-modified,
  an enabled-but-missing component, a disabled-but-present component, an
  interrupted transition and its recovery, and a lost state file. Each step
  asserts both the profile state and the filesystem.

### The shell registry reader

`common/lib/manifest.sh` is the single read path for `config/capabilities.tsv`,
`install-options.tsv`, `command-providers.tsv`, `tool-floors.tsv`,
`pin-freshness.tsv` and `actions.tsv` from shell, and it had no suite of its
own: the only test that reached it did so incidentally through
`capability_field`. `tests/test-manifest-reader.sh` holds it to its stated
contract by execution — the header it refuses (a repeated column, a column the
caller names and the file lacks), the arguments it refuses, the difference
between `manifest_values` answering nothing and `manifest_field` finding
nothing, and a value containing a backslash, which is the case the library's
`ENVIRON` indirection exists for.

It also closes a disagreement between the two readers of the same registries.
Given a three-column header and a two-field row, `scripts/lib/manifests.py`
refused the file and this one printed an empty value and returned 0, so a
truncated `packages` column read as "this capability installs nothing" and the
installer reported success (issue #387, NC-05). The Python validator runs in
CI; this library is what runs on a user's machine during `./install.sh` and
`platforms/*/scripts/verify.sh`, where no validator ever runs, so it is the
reader that most needed the rule. Every data row is now held to the header's
column count, naming the line and the columns that are missing or past the end.

`manifest_field` checks the whole manifest rather than stopping at its own
match, and the suite asserts that: a guard that stops guarding once the caller
has its answer would let a malformed row below the first match through unseen.

### Repository hygiene

`tests/test-repository-hygiene.sh` owns the rules in
`scripts/validate-repository-hygiene.py` (issue #162). Each negative case
builds a minimal tree that is valid except for one defect, so a rule that stops
working fails visibly rather than passing vacuously: a lone root npm lockfile,
a retained upstream licence text nothing references, a third-party notice
pointing at a path that no longer exists, and a licensing page whose stated
decision disagrees with the tree. The positive cases prove the rules do not
over-reach — a lockfile beside its own manifest, and a fixture project below
the root, are both accepted.

### Neovim plugin specs

`scripts/validate-neovim-plugin-specs.py`, which `./scripts/lint.sh` runs,
parses every plugin fragment under `nvim-lazyvim/` and `platforms/*/stow/nvim-*/`
and fails when two fragments that are stowed together declare the same key
lazy.nvim does not merge (`init`, `config`, `build`, `priority`). Only `opts`,
`dependencies`, `cmd`, `event`, `ft` and `keys` are merged across fragments;
everything else is overridden by the fragment imported last, silently. Two
different platforms' overlays are never installed together, so they are not
treated as contending.

`tests/test-neovim-tool-ownership.sh` proves the same rule behaviourally: it
stows each platform overlay beside the shared fragments in a scratch config,
resolves the set through lazy.nvim, and requires that refocusing the window
reloads the machine-local flavour - the behaviour
[theming](workflows/theming.md) and [troubleshooting](troubleshooting.md)
both promise. `tests/fixtures/neovim-contended-init/colorscheme.lua` keeps the
arrangement that was wrong (issue #248, RA-36): the behavioural test and the
validator must both reject it, so neither can go green vacuously.

### Mason package identity

A Mason package directory is evidence that an installation was *started*, never
that one finished. Mason promotes the staged files, links the package's
executables into `<mason>/bin` and writes `<package>/mason-receipt.json` last,
so an interrupted install, a half-deleted package and a converged one are all
directories. `common/lib/mason.sh` is the one place that decides what
"installed" means -- a receipt that parses, names its own package, claims links
that exist and are executable, and records the version an explicit pin in
`common/mason-package-versions.txt` demands -- and both `check_mason_inventory`
in `common/lib/verify.sh` and the provisioning in
`common/install-neovim-tools.sh` ask it, so the verifier cannot credit a
package the installer would have to repair (issue #346).

The Parrot CTF verifier asks the same question through
`check_mason_package`, because its inventory policy differs and its answer
about a package must not (issue #366): the reduced profile is an isolation
boundary, so a package Mason holds that the profile does not list is a failure
there rather than the warning `check_mason_inventory` raises, and that set
comparison stays its own check beside the per-package one.

A fixture that creates a package directory therefore models an interrupted
install and not a working one. `tests/support/mason-mock-install.sh` leaves
behind what a finished install leaves behind, optionally at the versions
`--pins` names, and every suite with a Mason fixture builds its packages through
it. `tests/test-verifier.sh`, `tests/test-neovim-bootstrap.sh` and
`tests/test-parrot-verification.sh` then damage a
complete installation one way at a time -- an empty directory, a missing
receipt, a missing linked executable, a truncated receipt, a version the pin
file no longer names -- and require the verifier to report it and a rerun to
repair it, while the complete package beside it stays untouched. That undamaged
sibling is what keeps the cases honest: a check that had started failing
everything would fail there too.

### Documentation architecture

`tests/test-documentation.sh` owns the documentation gates in
`scripts/validate-docs.py` and the two normative renderers (issue #159). Each
negative case builds a small tree that is valid except for one defect — a
broken internal link, a link to a heading that does not exist, a document
nothing links to, a capability described as waiting for or blocked on an
issue, and an `./install.sh --platform X` command line passing an option that
platform does not have. The drift cases are the real ones: a manifest row is
changed and nothing is regenerated, and the generated document is hand-edited;
both fail, and the checker never silently repairs the tracked file. The suite
also asserts that the README stays an entry point rather than growing back
into the operating manual.

### What the shell lint gate checks

`./scripts/lint.sh` reads its file set from `scripts/list-shell-files.py`, not
from a glob. The rule is the shebang, not the extension: a tracked file is
linted if it ends in `.sh` **or** its first line names `bash` or `sh`. That
distinction is the whole point. A command installed onto `PATH` does not carry
an extension, and fourteen tracked Bash programs — `bin/.local/bin/theme`,
`doctor`, the stowed Sway and WSL interop commands, and
`platforms/fedora/assets/dotfiles-sway`, which is the Wayland session `Exec=`
the display manager runs to start the desktop — were therefore checked by
nothing. A hard syntax error could be appended to any of them and the gate
still printed "Shell validation passed" (issue #384, NC-01).

The reader enforces its own floor: every file the old `*.sh` glob matched must
still be in the set it returns, or it fails rather than printing a shorter
list, so a regression in the reader cannot quietly narrow coverage back.

The files Zsh reads are a set of their own, `list-shell-files.py --zsh`: every
tracked `.zsh` file, every file named as a Zsh startup file (`.zshenv`,
`.zprofile`, `.zshrc`, `.zlogin`, `.zlogout`) and every file with a `zsh`
shebang. Neither `bash -n` nor ShellCheck can parse Zsh, and for as long as
that was the reason to leave them out nothing parsed them at all: an
unterminated `[[` at the top of the Fedora WSL `platform-env.zsh`, which strips
Windows' `/mnt/<drive>` entries from `PATH` in every shell, passed lint and
every suite (issue #536, V5-08). The gate runs `zsh -f -n` on each, and prints
`SKIP` rather than passing when `zsh` is not installed.

`tests/test-lint-file-selection.sh` proves the effect rather than the wiring.
It breaks each extensionless program in a scratch copy of the tree and runs the
real entry point against it, and it records the argv ShellCheck is actually
handed from a stub, because the defect being guarded against is exactly a file
set that looks right in one place and is narrower in another. It also asserts
that removing the session command's row from `config/shell-file-roles.tsv`
fails validation: `governed()` claims any `platforms/*/assets/*` file carrying
a shell shebang, so that program's mode is somebody's responsibility too.
It breaks three Zsh files the same way -- as the first line of the file no
suite sources, as the last line of one that a suite does source, and in
`.zprofile`, which has no extension -- and checks that lint names each one, and
that a machine without Zsh reports the check as skipped.

### What the gates cover on Windows

Four platforms run the Bash installer; the fifth, the Windows host, is
installed and verified by PowerShell. Most mechanical gates read Bash and so
cover the four, which is deliberate rather than an oversight, and this table is
where that decision is written down instead of being a property of each file
(#539). `tests/test-documentation.sh` requires a row here for every
`scripts/validate-*.py` and `scripts/render-*.py`.

| Gate | Windows inside it | What covers Windows instead, or why nothing needs to |
| --- | --- | --- |
| `scripts/validate-acceptance-records.py` | Yes | `windows-host.md` is a checklist like the others |
| `scripts/validate-actions.py` | No | The action registry is the Bash platforms'. The one Windows command, `set-noctty-theme.ps1`, has its flavours held by `config/option-consumers.tsv` and its existence and mode by `config/shell-file-roles.tsv` |
| `scripts/validate-capabilities.py` | Yes | Windows capability rows, `verify.ps1` and the PowerShell suites |
| `scripts/validate-check-outcomes.py` | No | `verify.ps1` writes no trace; `tests/test-windows-verifier.ps1` asserts its failure paths directly |
| `scripts/validate-command-provider-closure.py` | No | The pre-mutation command closure is a Bash installer's; `install.ps1` runs on a stock Windows |
| `scripts/validate-docs.py` | Yes | Every page, the Windows ones included |
| `scripts/validate-errexit-conditions.py` | Not applicable | It reads Bash for a `set -e` Bash ignores; PowerShell has no errexit to suppress |
| `scripts/validate-install-options.py` | Partly | The Bash installers' parsers; `install.ps1`'s switches are its own `param` block, exercised by `tests/test-windows-bootstrap.ps1`, and the theme script's `ValidateSet` is a registered option consumer |
| `scripts/validate-library-guards.py` | Not applicable | `common/lib` is Bash; the PowerShell libraries are dot-sourced by path |
| `scripts/validate-neovim-plugin-specs.py` | Not applicable | Neovim runs inside the WSL distribution, which is the Fedora WSL platform |
| `scripts/validate-network-sources.py` | Yes | PowerShell downloads carry the same annotations |
| `scripts/validate-pin-freshness.py` | Yes | The Scoop installer pin in `manifest.psd1` |
| `scripts/validate-plan-network.py` | No | Execution plans are the Bash installers'; `install.ps1` has none |
| `scripts/validate-repository-hygiene.py` | Yes | PowerShell path references and the static-analysis step |
| `scripts/validate-shell-file-roles.py` | Yes | Every `.ps1` has a role and mode |
| `scripts/validate-symlink-checks.py` | No | Windows configuration is copied, not stowed, so there is no symlink to check |
| `scripts/validate-tool-floors.py` | No | The floors are the Bash toolchain's; the Windows host uses what Windows ships |
| `scripts/render-action-reference.py` | No | Rendered from the action registry above |
| `scripts/render-capability-matrix.py` | Yes | Windows has its own column |
| `scripts/render-file-ownership.py` | No | Stow packages and Bash machine-local state |
| `scripts/render-install-flows.py` | No | Rendered from the Bash installers |
| `scripts/render-installer-options.py` | No | Rendered from `config/install-options.tsv`, which holds no Windows rows |
| `scripts/render-installer-usage.py` | No | The same manifest |
| `scripts/render-package-ownership.py` | No | Package managers of the Bash platforms; Scoop's one package is in `manifest.psd1` |
| `scripts/render-supply-chain.py` | Yes | Rendered from the network-source registry, Windows sources included |
| `scripts/render-verifier-reference.py` | Yes | Windows has its own section |

### Every Bash verify check is proven able to fail

Every other gate here reads files. This one cannot, and that is the whole
point: whether a `check_*` call site is able to fail is a statement about what
ran. A predicate that is always true and one that is merely true on this
machine are the same text. The audit's reproduction was a `check_file_contains`
inserted into `platforms/fedora/scripts/verify.sh` — one file, `bash -n`,
shellcheck, every validator and the suites all green (GRADE-03 of #393).

So `common/lib/verify.sh` records, for each verdict it prints, the call site
that produced it, whenever `DOTFILES_VERIFY_TRACE` names a file to append to.
The call site is the first frame outside the library, which for a `check_*`
helper is the line in the verifier that called it. A verifier may define a
`check_*` helper of its own, and then that first frame is the helper's own
`pass` or `fail` line, so while the frame is running a `check_*` function the
verdict is credited to its caller too, as far out as the calls go. A line that
only defines such a helper is not a call site. A call written as `check_x \`
with its first argument on the next line is refused outright: bash credits it
to that next line, so no fixture could ever cover it. `./scripts/test.sh` arms
that trace for the aggregate run only — a targeted run reaches a fraction of
the call sites and would report every other one as uncovered — and reads it
with `scripts/validate-check-outcomes.py` once the suites are done.

A call site that produced both a pass and a fail is covered: some fixture drove
it each way, so inverting its predicate takes one of those outcomes away and
the run turns red naming the line. The rest are uncovered on purpose, and
`config/check-outcomes.tsv` names each one with the reason it is allowed. Any
other uncovered call site is refused, however many the verifier had before: when
the file held a count per verifier, one check could lose its failing fixture
while another gained one and the gate never noticed (#497).

A row names its call by what it says, not by its line, so a change elsewhere in
the verifier cannot move an exception onto a different check. The text is the
whole command with continuation lines joined and whitespace collapsed, without
the `if`, `while`, `until` or `!` in front or the `; then` behind; a call made
twice in one verifier gets `(occurrence 2)`. A row whose call is gone is refused,
and so is a row with no reason.

A row whose call is now covered is reported, not refused, because the two rules
read different things. The symlink gate below reads files, which are identical
on every machine. This one reads behaviour, which is not: a machine with
`podman` or `systemctl` drives checks to a verdict that a machine without them
reports as not observed. So the rows are the worst environment's, and coverage
beyond them is reported with the instruction to delete the row. `--record`
rewrites the file from a trace, keeping the reasons already written; a row it
adds has none, and the next run refuses it until someone writes one.

Only the repository's own files count. A suite that copies the tree and mutates
the copy is proving something about the mutation, so its verdicts must not make
the real call site look covered — otherwise a check could be "covered" by a
fixture that had edited it first.

`tests/test-check-outcomes.sh` proves the gate can fail, against traces it
writes itself: a new check no fixture drives, a new verifier, a call site that
lost its fail, an excused site swapped for another at the same count, an
excused call moved by unrelated lines, one of two identical calls excused, an
excused call now covered, a row with no reason, a row for a call that is gone,
an empty trace, a missing trace, verdicts recorded against a copy of
the tree, and a verifier-local `check_*` helper that must credit its caller.
Its first case is the control — a tree whose every call site was
driven both ways is accepted — so none of the others can pass because the tree
was already red.

This is a partial answer to GRADE-03, not the whole of it: it holds every new
check to the rule from today, and catches an inverted predicate at the 140 call
sites already covered. The remaining 10 are uncovered on purpose, as #383
records: themes, VM agents and CPU architecture, where a false pass costs little,
and two digest checks whose negative outcome is a warning by design, which this
gate does not count.

### Every symlink check names its Stow source

`check_symlink <link> <expected-root> [expected-source]` proves five things
without the third argument: the link exists, it is a symlink, its referent
exists, it canonicalises, and the referent is inside the expected package root.
None of those is "it points at the right file", so a link redirected at another
file in the same package was reported green (issue #369).

The third argument is optional in the helper, which is what let the call sites
migrate one platform at a time — and equally what would let the weak form come
back unnoticed, because a two-argument call is not a syntax error and its
output is a tick like any other.
`scripts/validate-symlink-checks.py` is therefore what answers "is the
migration finished": every call site outside `tests/` passes an expected
source, except the files listed in that script's `MIGRATING` table with the
exact number of two-argument calls left in each. An exact count rather than a
floor, so neither direction is silent — adding a weak call site to a listed
file fails, and migrating one fails too, with the instruction to lower the
number — and the entry must go when it reaches zero, so the list cannot outlive
the migration.

Three arguments are not enough on their own: the checker also reads the third
argument's text, because `check_symlink "$link" "$root" ""` and a third
argument that repeats the link each proved no more than the two-argument form
while passing a count (issue #507). The expected source must not be empty, must
not be the link over again, and must be written inside the package the second
argument names, below a whole path component. The helper itself decides on the
argument count rather than on whether the third one is empty, so a variable
that expands to nothing fails at runtime instead of skipping the comparison.

The suites under `tests/` are out of scope: `tests/test-verifier.sh` calls the
two-argument form on purpose, to prove the containment verdicts the helper
still owes when no source is given.

The expected source is written out per call site, read off the package layout,
rather than derived from the deployed path. Deriving it would recompute the
same `$HOME`-relative mapping Stow itself applied, so a wrong link and a wrong
expectation would agree.

`tests/test-repository-hygiene.sh` proves the gate can fail: it runs the real
checker against fixture trees carrying a two-argument call, a weak call beyond
a recorded count, a migrated call still listed, a shape the checker cannot
parse, and no call sites at all.

### Compatibility wrappers, file modes and names

`tests/test-compat-wrappers.sh` owns the deprecation policy (issue #161). A
deprecation window only means something if the wrapper still works, so the
suite proves both halves: every deprecated wrapper forwards to a real target
and passes its arguments through, and the notice names the wrapper's own path,
the supported replacement, the platform script and the removal date. It also
checks the properties that keep the notice from being harmful — it goes to
stderr so stdout stays parseable, and `DOTFILES_SUPPRESS_DEPRECATION=1`
silences it — and that the removal milestone lives in one constant rather than
being copied into every wrapper. A window that has already expired fails the
suite, which is how the follow-up removal gets noticed.

The mode policy is tested against a throwaway copy of the tree, one defect at a
time: an executable sourced library fails, a non-executable entry point fails,
and a shell file no role in `config/shell-file-roles.tsv` claims fails, so
classifying a new script is unavoidable rather than optional. The
`deprecated-wrapper` catch-all is covered the same way (issue #248, RA-35): a
new `scripts/` helper the pattern would claim fails until it has its own row,
while a file that really calls `deprecated_wrapper` still passes under that
same pattern. The rule itself belongs to
[repository conventions](architecture/repository-conventions.md#entry-points-and-what-scripts-actually-is).

The renamed theme libraries are checked for stale references across every
tracked file, and the deprecated shim is sourced to prove it still provides
what it used to while warning that it is deprecated.

### Custom actions and printable sheets

`tests/test-action-registry.sh` owns `config/actions.tsv` and everything
derived from it (issue #160). The registry is checked in both directions, and
the suite proves each direction separately: renaming a tracked binding without
updating the registry fails, and adding a binding without registering it fails
— the latter through the real parsers (`tomllib` for AeroSpace, `json` for
Waybar, Sway's own grammar, the shell's alias and function syntax), not a
single regex over everything. A row claims an implemented line only when its
`source_pattern` matches the whole line, so an argument appended to a
registered alias, or a second command chained onto a Sway binding with `;` or
`,`, fails as unregistered; a family of lines is spelled out as an
alternation, and a pattern that repeats without an upper bound (`.*`, `\S+`)
is refused.

It also pins the distinction the registry exists to make: every registered
action appears in the generated full reference, every `print=false` action
stays in that reference and off every sheet, and no sheet advertises a command
or flag its platform does not have. `docs/cheatsheets/verify.sh`, run as its
own CI job, compiles each sheet and checks the page budget, A4 size, overfull
boxes, undefined references, and byte-identical output across two builds.

### Machine-local Git identity

`tests/test-git-identity.sh` owns machine-local Git identity migration (issue
#163). Every scenario builds the exact history or backup state it needs in a
temporary directory, so nothing depends on this repository's own object graph
or on `fetch-depth: 0`; the suite behaves identically in a full clone, a
shallow clone, and an export with no `.git` at all. It covers each migration
source, validation of recovered content, byte-exact restoration at mode `0600`,
a no-op rerun, and the three failure modes that must never fabricate an
identity: a missing source, invalid content, and a shallow clone whose
historical objects are absent. It also asserts that no message contains the
fixture's name or email, because identity values must never reach a log.

### The one configuration root

`tests/test-installer-preflight.sh` owns the XDG contract (issue #343). Stow is
given one target, `$HOME`, while nearly everything that reads the result
resolves it through `XDG_CONFIG_HOME` or `XDG_DATA_HOME`, so a nondefault root
used to let Stow report success with every link somewhere nothing looked. The
suite deploys the default layout with the real `common/stow.sh` and requires
Git, mise, Neovim and shell configuration to be links into the checkout; that
run is also the control, because it is what "nothing was created" is measured
against. It then points each root in turn outside `$HOME` and requires all five
Stow entry points and `./install.sh` to refuse, naming the variable, with
neither `$HOME` nor the separate root gaining a single path and with no package
transaction or lifecycle state written. A last case requires the default root
to be accepted however it is spelled, so the refusal cannot be triggered by a
trailing or doubled separator.

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
- `tests/test-macos-verification.sh` runs the real macOS verifier against a
  mocked Apple Silicon machine. The checks a Linux runner can never satisfy
  are declared by name and asserted as the complete set the healthy fixture may
  fail, so each case breaks exactly one fact (a
  Starship configuration for the wrong flavour, a missing Delta override, Mason
  package or Catppuccin tmux plugin, a Homebrew `dotnet` ahead of the mise
  shim, a command that resolves but cannot run) and asserts exactly one more
  failure, naming it. A Catppuccin tmux checkout moved past the pin is the
  exception: it warns, naming both versions, and adds no failure. One run
  models an install that did not deploy -- Stow links missing or linked from
  another checkout, no `aerospace` on PATH, a Neovim whose configuration does
  not load -- and names every failure it expects rather than counting them.

## Which run is evidence for which commit

`validate.yml` runs on three kinds of event, and each proves a different tree.
Only the last is release-quality evidence.

| Evidence | What GitHub validated | What it does not prove |
| --- | --- | --- |
| Pull-request run | The pull request merged into `main` as `main` stood when the run started (`refs/pull/N/merge`). | The tree that lands, once `main` has moved: two pull requests each green against the old `main` can break it together. |
| Merge-group run | Nothing: this repository has no merge queue. GitHub offers merge queues only to repositories owned by an organisation, and this one belongs to a personal account. | — |
| Push run on `main` | The merge commit itself, which is exactly the tree on `main`. | Anything about a later commit. |

**A `main` commit is validated when its own push run concluded `success` with
every job its `validate.yml` defines succeeding in it.** A run on the branch it
came from, a run on an earlier or later `main` commit, or a cancelled run is not
evidence for that commit. Quote that run's URL when claiming a commit passed.

Two things keep that true (#499):

- **A push to `main` is never cancelled.** The workflow's concurrency group is
  the commit for a push and the branch for a pull request, and only pull-request
  runs cancel their predecessor. Before this, the group was the branch for both:
  a merge that landed while the previous merge's run was going cancelled it, and
  10 of the 40 `main` pushes up to 23 September 2026 kept only a cancelled run.
  `scripts/validate-repository-hygiene.py` holds the block to that exact shape,
  because turning `cancel-in-progress` off alone still leaves one pending slot
  per group, and GitHub cancels the pending run a newer one replaces.
- **A gap is reported, not waited for.** `.github/workflows/main-evidence.yml`
  runs `scripts/check-main-evidence.py` after every Validate run on `main` and
  once a day. It walks `main`'s first-parent history back to the commit that
  introduced the check and reports every commit without a green run of its own,
  plus merge rules on `main` that do not require the Validate jobs or an
  up-to-date branch, or that require a check no job in the tip's
  `validate.yml` provides, which is what a renamed or deleted job leaves
  behind. A finding fails the job and opens one tracking issue,
  which is commented on only when the findings change and closed by the first
  run that finds nothing. A cancelled or failed run can be re-run from its
  Actions page, which validates the same commit again; a commit GitHub never
  started a run for cannot, and is covered only by the next commit's run.
  `tests/test-main-evidence.sh` drives it against a fixture API.

The daily run matters because the other trigger cannot see the one gap it
exists for: `workflow_run` fires when a run finishes, and a push GitHub never
started a run for never finishes one.

**A green `main-evidence` run means the jobs the workflow currently defines
and the checks the branch rules name are the same set, with an up-to-date
branch required. It does not mean the merge rules are correct.** The rules are a repository setting,
editable in a web form with no commit, diff or review, and the check reads
them through an API whose handling here is only ever proved against fixtures
this repository wrote. It can show the text of `validate.yml` and the rules
GitHub returned agree; it cannot show GitHub enforced them on any merge.

**Merging should require the four Validate jobs on an up-to-date branch.**
That is a repository setting, not a file: a `required_status_checks` rule in
the ruleset on `main` naming `Repository validation`, `Printable cheat sheets`,
`Windows PowerShell validation` and `macOS 26 arm64 validation`, with
**Require branches to be up to date before merging** on. With it, a pull
request can merge only after its run passed against the `main` it will land on,
so the pull-request run and the push run validate the same tree. The main
evidence check reports the setting as a finding for as long as it is absent,
reading it from GitHub's public rules endpoint for the branch.

`REQUIRED_JOBS` in `scripts/validate-repository-hygiene.py` is the one list of
those four jobs and their names. `validate.yml` has to define exactly them,
none carrying an `if:` or `continue-on-error` or waiting on a job with an
`if:`, because GitHub counts a skipped job as a passing required check. The job
table under [Fast PR validation](#fast-pr-validation) and the paragraph above
have to name the same jobs, so renaming one fails lint until the list, this
page and the ruleset change together.

## Secret scanning

`./scripts/scan-secrets.sh` is the gate behind the README's claim that nothing
secret is committed here. It scans the working tree and the whole history with
a version-pinned gitleaks, and `.github/workflows/validate.yml` runs that same
command before lint, so a contributor and CI run the identical check. What it
covers, why history is scanned every time and how to bump the pin are in
[supply chain](supply-chain.md#the-gate-behind-that-claim).

Two things make it a gate rather than a habit.
`scripts/validate-repository-hygiene.py` refuses a tree whose validation
workflow does not run the scanner for real, so the step cannot be deleted,
commented out, or kept and switched off with `if:`, `continue-on-error` or
`--help`, without failing lint; the same rule covers `./scripts/lint.sh`,
`./scripts/test.sh` and `tests/test-windows-static-analysis.ps1`. And
`tests/test-repository-hygiene.sh` drives the real script over a fixture
checkout: it requires a planted access key and a planted private key to be
caught, requires a credential that was committed and then deleted to still be
caught from history, requires the report not to reprint the matched value,
requires a scanner that is not the pinned version to be refused outright,
since a different build is a different rule set, and requires neither a
`.gitleaksignore` nor a `gitleaks:allow` comment to silence a finding. It
also runs the tracked `.gitleaks.toml` over one generated sample per
high-value rule family, so an exception that silences a whole family fails
the suite. `tests/test-secret-scanner.sh` covers the download itself, against
an archive and a network it owns: a wrong digest, an archive without the
binary, a binary reporting another version, and a tar, mv or chmod that fails
must each stop the run before anything is scanned and leave nothing in the
cache that a later run would accept. Its tar fixture extracts the binary and
then exits non-zero, because one that writes nothing is caught by the version
check whether or not tar's status is read.

That suite needs the pinned binary and never downloads one, because no suite
here reaches the network. In CI the scan step runs earlier in the same job and
leaves it in the cache; on a workstation, running `./scripts/scan-secrets.sh`
once does the same. Set `DOTFILES_GITLEAKS` to use a copy from somewhere else.

The credential-shaped strings in that suite are assembled from parts, so the
repository never contains one and the allowlist can stay empty.

## Scheduled pin freshness

`.github/workflows/pin-freshness.yml` runs `./scripts/check-pin-freshness.sh`
on the first of each month and can be dispatched manually. It is a report, not
a test: it asks each `manual-bump` upstream in
[`config/network-sources.tsv`](../config/network-sources.tsv) what its newest
release is, prints that beside the pinned value, and writes the table into the
run summary. It downloads no artifact and changes no pin.

It exists because the real-install validation below cannot cover this. That
workflow installs from every pin for real, so it catches a pin that has
*broken*; a pin three releases old and still serving its bytes correctly is
indistinguishable from a current one there. The two are complementary, which is
why this is a separate schedule rather than another job.

A newer upstream release does not fail the job — `--fail-on-stale` is
deliberately not passed, because adopting a release is a reviewed act. A pin
that could not be read, or an upstream that could not be reached, does fail it:
a report that silently reached nothing would read as "everything is current".

`tests/test-pin-freshness.sh` covers the report itself against a stubbed
`git ls-remote`, so no suite here reaches the network, and covers
`scripts/validate-pin-freshness.py`, the lint gate that requires every
`manual-bump` source to declare how its staleness is noticed. See
[supply chain](supply-chain.md#noticing-that-a-pinned-source-has-moved).

## Scheduled/manual real-install validation

`.github/workflows/real-install.yml` is intentionally separate from normal PR
validation. It runs on a schedule and can be dispatched manually. Clean-state
jobs use disposable hosted machines, disposable containers, a freshly imported
WSL export, or a reverted VM snapshot so previously installed packages, user
configuration, mise/Mason state, lifecycle state, and login-shell changes do not
silently become test fixtures.

| Platform class | Automated evidence | Remaining gap |
| --- | --- | --- |
| Fedora workstation | A privileged disposable Fedora systemd environment runs the real installer, verifier, the development workflow smoke tests, a second install, and a theme-state transition. A disposable repository copy injects an invalid DNF package and the **real installer** is required to fail while reaching that package. | A containerized systemd userspace does not emulate firmware, a graphical login, Secure Boot, NVIDIA/AMD hardware, suspend/resume, or a physical GA402XZ. Periodic physical-machine validation remains valuable. |
| Apple Silicon macOS | A GitHub-hosted `macos-26` Apple Silicon runner invokes the public entry point through `/bin/bash` with ordinary PATH lookup restricted to Apple system paths, requires explicit Homebrew Bash discovery/re-exec, and executes the real bootstrap/install path, verifier, development workflow smoke tests, idempotent rerun, then an OCaml/AI/defaults/theme state transition. Every AI component the platform advertises is then probed individually on that runner: it must resolve through mise, must not be an Intel-only binary or a Homebrew/global-npm duplicate, and must run a harmless `--version`/`--help`. The remembered selection is finally replayed with `./install.sh --rerun` and reverified, which is what proves the optional AI subcomponents survive the persistent-selection round trip. | GitHub's image is disposable and real macOS/arm64, but it already contains Homebrew. Installing Homebrew itself on a factory-fresh Mac and granting interactive Accessibility/Tailscale approvals remain manual assurance. The AI probe never authenticates anything, so it proves installable and runnable, not logged in. TeX is user-managed on macOS, so the LaTeX workflow is never exercised there. |
| Fedora WSL / Windows boundary | `windows-latest` exercises the Windows bootstrap boundary. The manual self-hosted WSL job imports a fresh distro from a clean Fedora WSL export tar for every run, performs the first install, terminates and relaunches that distro so `/etc/wsl.conf` changes take effect, then runs the independent verifier, idempotent rerun and theme transition before unregistering it. | GitHub-hosted Windows runners do not provide a dependable, reboot-capable Fedora WSL installation. Clean WSL evidence therefore depends on maintaining an immutable clean export on the labelled self-hosted runner. |
| Parrot CTF guest | Scheduled CI confirms Parrot/APT availability and requires the real installer to reject a non-QEMU container specifically at the VM preflight boundary. A manual clean/snapshotted KVM/QEMU guest additionally runs an invalid-package failure-propagation check, install, verify, rerun and theme transition. | GitHub has no hosted Parrot KVM/QEMU guest with the repository's required guest channels/isolation. The container job is explicitly **not** counted as VM evidence. The self-hosted VM must be reverted to its clean snapshot between runs. |

### Why the real installs are weekly, and what that costs

Every gate a pull request waits on is mocked. `validate.yml` runs lint, the
mocked suites, the PowerShell suites and a macOS job whose install is
`--dry-run`; none of them installs anything. The real installs above run on a
Sunday schedule or a manual dispatch, and the WSL and Parrot jobs only on a
dispatch that sets their input. So a change can pass every merge gate, break a
real install, and sit on `main` until the next scheduled run — up to a week on
Fedora and macOS, and indefinitely on WSL and Parrot until someone dispatches
them.

**That is the accepted cadence, not an oversight.** A clean Fedora run is
around ninety minutes of runner time and the matrix is four platform classes,
two of them self-hosted and stateful: the WSL job imports a golden export tar
and the Parrot job reverts a VM snapshot, and neither can run concurrently with
itself. Making that a required pull-request check would put ninety minutes and a
serialised self-hosted runner in front of every merge, including the
documentation-only ones, for evidence that has so far agreed with the mocked
tier on every run. The repository buys timeliness elsewhere instead: the
registry enforcement in `scripts/validate-capabilities.py` requires every
implemented capability to be selected by a real-install invocation and to have
its verifier run there, so the weekly job cannot silently stop covering
something, and that requirement *is* checked on every pull request.

What this means in practice is the rule already stated under
[Maintenance/release role](#maintenancerelease-role): a green pull request means
the mocked tier agreed, not that any machine was installed, so changes to
bootstrap, login-shell, package-provider, lifecycle, Neovim bootstrap, VM
boundary or platform installer code are reviewed against the latest real-install
run before a release rather than against their own checks.

That bound is watched, not assumed: the
[real-install evidence check](#self-hosted-runner-contracts) reports any job
whose newest success is older than its allowed age, the hosted four included.

Revisit this only if a real-install run actually catches something the mocked
tier missed, or if the gap between a merge and its evidence starts costing more
than the runner time would. Until then, the weekly cadence is the decision, and
a change proposing to tighten it should say which of the two happened.

### Self-hosted runner contracts

The optional clean WSL job expects a runner labelled:

```text
self-hosted, Windows, X64, dotfiles-wsl
```

The runner must provide an immutable export tar of a clean Fedora WSL distro at
the path supplied by the `wsl_base_tar` workflow input. The archive must contain
the non-root user named by `wsl_user` with non-interactive `sudo`, networking,
and Git, and nothing else added: the installer's Fedora base bootstrap installs
Gawk, which the clean image lacks, and anything else it runs before its package
step, so the job proves that a clean distro is enough. The workflow
imports that archive under a run-specific distro name and install directory,
clones the selected commit into the distro's Linux filesystem, and performs the
first install. It then explicitly terminates the imported distro and launches it
again before the independent verifier. That restart boundary is part of the
test contract: it proves the installed `[interop] enabled=true` /
`appendWindowsPath=false` policy after WSL has re-read `/etc/wsl.conf`, rather
than merely checking the file written during the original session. The workflow
then runs the idempotent install and selected-state transition before
terminating/unregistering the distro and removing the imported files. That
removal runs on success, failure and cancellation, but not when the runner
itself is lost mid-run, so the job's first step unregisters any
`dotfiles-ci-*` distro an interrupted run left behind. The runner is expected
to serve this job alone, one job at a time; a second runner with the same
label would have its in-flight distro swept. Do not refresh the golden export
from a previously provisioned validation run; rebuild or deliberately update it
from a known-clean source instead.

The optional real Parrot VM job expects a runner labelled:

```text
self-hosted, Linux, X64, dotfiles-parrot-vm
```

That runner must itself be the disposable Parrot Security Edition KVM/QEMU
guest expected by the profile, including the normal guest-agent/SPICE channels.
Revert its VM snapshot after each validation run; do not preserve `$HOME`, mise,
Mason, package-manager or lifecycle state as a cache. The invalid-package check
uses an isolated HOME and disposable repository copy, but the VM snapshot is
still the authority for clean-machine state. The guest cannot revert its own
snapshot, so the job cannot enforce a clean start; it refuses one that is
visibly not clean instead. Its first step fails when the dotfiles lifecycle
state, the saved selections or mise's data directory from an earlier
installation are present, because evidence gathered on top of them is a rerun,
not a first install. After the idempotent rerun the verifier runs again, as it
does in the WSL job.

Neither job runs on the weekly schedule, and the hosted four are only as
current as the schedule that runs them, so each Monday
`.github/workflows/real-install-evidence.yml` runs
`scripts/check-real-install-evidence.py`. It finds, for every job in
`real-install.yml`, the newest scheduled or dispatched run in which that job
succeeded on a commit main contains, and holds it to the job's age in the
script's `MAX_AGE_DAYS` table: ten days for the four hosted jobs, which allows
one missed Sunday and reports the second, and 30 days for the two self-hosted
ones. The table has to name exactly the workflow's jobs, so which jobs are
watched never depends on a runner label, and adding, renaming or deleting a job
without changing the table fails `tests/test-real-install-evidence.sh`. When a
job is older than its age, or has no success at all, the check opens the issue
"Real-install jobs have not succeeded recently", and the first run that finds
every job current closes it. Its report, in the run's summary, gives each job's
last success date, commit and how far behind main that commit is. Clearing a
hosted job means finding out why its schedule stopped going green; clearing a
self-hosted one means dispatching real-install.yml on main with
`run_self_hosted_wsl` and `run_self_hosted_parrot` set, with the WSL runner up
and the Parrot guest reverted to its clean snapshot. The two label lists above
are pinned, exactly, by `tests/test-self-hosted-jobs.sh`, which reads both
jobs' `runs-on` from the workflow and this page's label blocks.

## Manual acceptance records

Every tier above is automated, and none of it reaches a physical machine's
firmware, a graphical login, suspend and resume, a second monitor, a privacy
approval, an interactive sign-in or a microphone. Evidence from those
boundaries is a different kind: a **manual acceptance record**, written by a
person who worked through a checklist on real hardware, committed under
`docs/testing/manual-acceptance/records/`, and naming the exact commit, date,
machine and installer options it describes.

The two kinds are never counted as each other. A green workflow run is not a
record, and a record is not a workflow run: it is one observation, it goes
stale, and it has its own rules for when it must be redone.
[Manual acceptance records](testing/manual-acceptance/README.md) has the
checklists, the template, the four outcomes (`pass`, `fail`, `not observed`,
`not applicable`), what must stay out of a record, and those rerun rules.

`scripts/validate-acceptance-records.py`, run by `./scripts/lint.sh`, holds
each record to a full commit SHA that is in the history, a real date, one
verdict per checklist item in that vocabulary, and none of the personal-data
shapes a pattern can recognise; it holds each checklist to its own item shape.
`tests/test-acceptance-records.sh` starts from a fixture record that passes and
breaks it one rule at a time, including an unfilled copy of the real template
and a shallow clone that cannot answer the ancestry question and must say so.

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
machine procedure before treating the release as fully validated. For the
hardware and interactive boundaries no job reaches, the release review also
checks that every target in use has a current
[manual acceptance record](testing/manual-acceptance/README.md#when-a-record-must-be-redone),
and says which boundary has none when one does not.

The capability manifest remains authoritative for what each platform supports;
this document describes **test evidence**, not a second capability matrix.
