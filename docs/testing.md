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
| zsh | any recent release | shell-startup and profile suites |
| GNU Stow (`stow`) | any recent release | install/stow suites |
| OpenSSH client tools (`ssh`, `scp`, `sftp`) | any recent release | SFTP/remote-access suites |
| Python 3 (`python3`) | >= 3.11 | every `scripts/*.py` validator and generator |
| jq | any recent release | JSON-fixture and action-registry suites |
| ripgrep (`rg`) | any recent release | `./scripts/test.sh` preflight and search-based checks |

`./scripts/test.sh` also preflights `awk`, `bash`, `curl`, `find`, `getent`,
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
calls does not count. The reader names are derived from
[`common/lib/tool-floors.sh`](../common/lib/tool-floors.sh) rather than written
into the validator, so renaming one cannot leave the check hunting for a name
that no longer exists. A mise pin is read the way mise reads it: the key may be
backend-qualified, and the version is a prefix rather than an exact number, so
a pin of `3` provisions the newest 3.x and satisfies the floor above. A pin the
check cannot interpret fails the build rather than being skipped.

Two minimums this repository enforces are deliberately stated where they are
enforced instead, because neither is a tool the toolchain provisions or
preflights. The Bash minimum in
[`scripts/bootstrap-macos.sh`](../scripts/bootstrap-macos.sh) and
[`common/lib/modern-bash.sh`](../common/lib/modern-bash.sh) is the interpreter
every other check runs under, decided before a shared library can be sourced
and while the shell is still Apple's 3.2, so it cannot read a registry whose
reader it would have to start first. The kernel minimum in
[`platforms/fedora/scripts/install-asus-hardware.sh`](../platforms/fedora/scripts/install-asus-hardware.sh)
belongs to the distribution rather than to this repository, which can refuse to
enable the hardware but cannot raise it.

The Neovim spec-resolution suite inside `tests/test-neovim-tool-ownership.sh`
additionally needs a lazy.nvim checkout, because it resolves this repository's
plugin fragments through lazy.nvim itself instead of reading them. It uses
`DOTFILES_LAZY_NVIM` when that names a checkout, and otherwise the one a normal
install already leaves in `${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/lazy.nvim`.
A missing checkout fails the suite; it is never skipped.

`scripts/test-installer.sh` is a deprecated compatibility alias that forwards
to `./scripts/test.sh` unchanged; use `./scripts/test.sh`.

## Fast PR validation

`.github/workflows/validate.yml` is the workflow that runs on every pull
request and on pushes to `main`. It has four independent jobs:

| Job | Runner / image | What it runs |
| --- | --- | --- |
| `repository` (Repository validation) | `ubuntu-latest`, inside a pinned `fedora:44` container | `./scripts/lint.sh`, then a clone of the lazy.nvim revision `nvim-lazyvim/.config/nvim/lazy-lock.json` pins, `./scripts/test.sh`, and a whitespace check (`git diff --check`) against the PR's base |
| `cheatsheets` (Printable cheat sheets) | `ubuntu-latest`, inside the same pinned `fedora:44` container, with a LaTeX toolchain installed | `./docs/cheatsheets/verify.sh`, then asserts the compiled PDFs are left untracked |
| `windows` (Windows PowerShell validation) | `windows-latest` | `tests/test-windows-bootstrap.ps1`, `tests/test-windows-verifier.ps1`, and a `verify.ps1` smoke test against a fixture |
| `macos` (macOS 26 arm64 validation) | `macos-26` | `tests/integration/macos-dotnet-debug.sh`, `./scripts/lint.sh`, portable-verifier/shell-test/profile-state suites, a `--dry-run` macOS install, `tests/test-macos.sh`/`tests/test-macos-ai.sh`/`tests/test-ocaml-verification.sh`, and the same ranged whitespace check the `repository` job runs |

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
product's override variables (`DNF_REPO_DIR`, `OS_RELEASE_FILE`, ...). The goal
is the same result on a developer workstation as in the pinned CI container.
For example, `tests/test-hardening.sh` sets `HARDENING_ROOT` to its fake root so
the hardening profile's owned drop-ins are read and written there; without it, a
machine with the profile installed answers the suite's missing-drop-in checks
from its real `/etc`.

### Shared shell startup and ergonomics

`tests/test-shell-startup.sh` covers the shared Zsh profile (issues #157 and
#168). It sources the tracked `zsh/.zshenv` and `zsh/.config/zsh/.zshrc` in a
real `zsh -f` under a sandboxed HOME and asserts behavior, not configuration
text:

- sourcing startup three times leaves `PATH` byte-identical, with no duplicate
  entries and `~/.local/bin` still in front, on its own and layered under the
  Parrot and macOS platform PATH files;
- macOS keeps Homebrew coreutils `gnubin` as the last entry;
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

`./scripts/benchmark-shell-startup.sh` measures interactive and
non-interactive startup and can enforce a budget with `--interactive-ms` /
`--non-interactive-ms`. It is deliberately **not** in `./scripts/test.sh`:
wall-clock timing is machine- and load-dependent, so a timing assertion in the
fast suite would be a flaky gate rather than evidence.

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
single regex over everything.

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
  fail identically in every run, so each case breaks exactly one fact (a
  Starship configuration for the wrong flavour, a missing Delta override, Mason
  package or Catppuccin tmux plugin, a Homebrew `dotnet` ahead of the mise
  shim, a command that resolves but cannot run) and asserts exactly one more
  failure, naming it. A Catppuccin tmux checkout moved past the pin is the
  exception: it warns, naming both versions, and adds no failure.

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
