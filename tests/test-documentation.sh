#!/usr/bin/env bash
# Documentation architecture and drift gates (#159).
#
# Each negative case below builds a tree that is valid except for one defect,
# so a check that quietly stops working fails here rather than passing
# vacuously.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap

validator="$repo_root/scripts/validate-docs.py"

# new_tree: a minimal documentation tree that passes every rule.
new_tree() {
  test_new_root
  tree="$TEST_ROOT/tree"
  mkdir -p "$tree/docs/reference" "$tree/docs/platforms" "$tree/config"
  git -C "$tree" init --quiet --initial-branch=main
  cat >"$tree/README.md" <<'EOF'
# Example

See [the index](docs/README.md).
EOF
  cat >"$tree/docs/README.md" <<'EOF'
# Documentation index

- [platforms/fedora.md](platforms/fedora.md)
- [reference/options.md](reference/options.md)
EOF
  cat >"$tree/docs/platforms/fedora.md" <<'EOF'
# Fedora

Install it:

```bash
./install.sh --platform fedora --kde --dry-run
```

See [the options](../reference/options.md#options).
EOF
  cat >"$tree/docs/reference/options.md" <<'EOF'
# Options

## Options

Nothing here yet.
EOF
  printf 'platform\toption\tkind\ton_flag\toff_flag\tdefault\tvalues\tcapability\tsummary\n' \
    >"$tree/config/install-options.tsv"
  printf 'fedora\tkde\tboolean\t--kde\t--no-kde\tfalse\t-\tkde\tKDE integration\n' \
    >>"$tree/config/install-options.tsv"
  printf 'macos\ttheme\tvalue\t--theme\t-\tmacchiato\tlatte|mocha\t-\tFlavour\n' \
    >>"$tree/config/install-options.tsv"
  git -C "$tree" add -A
}

# --- This repository passes ------------------------------------------------

run_capture python3 "$validator"
assert_success
printf 'PASS: this repository satisfies the documentation rules\n'

new_tree
run_capture python3 "$validator" --root "$tree"
assert_success
printf 'PASS: a clean fixture tree satisfies the documentation rules\n'

# --- Broken internal links -------------------------------------------------

new_tree
printf '\nSee [gone](../reference/missing.md).\n' >>"$tree/docs/platforms/fedora.md"
git -C "$tree" add -A
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "broken link: ../reference/missing.md"
printf 'PASS: a broken internal documentation link fails\n'

new_tree
printf '\nSee [gone](../reference/options.md#no-such-heading).\n' >>"$tree/docs/platforms/fedora.md"
git -C "$tree" add -A
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "link anchor does not exist"
printf 'PASS: a link to a heading that does not exist fails\n'

# --- Orphan documents ------------------------------------------------------

new_tree
printf '# Stranded\n\nNothing points here.\n' >"$tree/docs/platforms/stranded.md"
git -C "$tree" add -A
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "nothing links to this document"
printf 'PASS: a document nothing links to fails\n'

# --- Stale issue claims ----------------------------------------------------

new_tree
printf '\nThis is waiting for #123 to land.\n' >>"$tree/docs/platforms/fedora.md"
git -C "$tree" add -A
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "states a capability as pending"
printf 'PASS: a capability documented as waiting for an issue fails\n'

new_tree
printf '\nSupport is blocked on #99 for now.\n' >>"$tree/docs/reference/options.md"
git -C "$tree" add -A
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "states a capability as pending"
printf 'PASS: a capability documented as blocked on an issue fails\n'

# --- Platform-support claims -----------------------------------------------

new_tree
# shellcheck disable=SC2016 # Literal Markdown fence, not a command substitution.
printf '\n```bash\n./install.sh --platform macos --kde\n```\n' >>"$tree/docs/platforms/fedora.md"
git -C "$tree" add -A
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "\`--kde\` is not an option of --platform macos"
printf 'PASS: advertising another platform-only flag fails\n'

new_tree
# shellcheck disable=SC2016 # Literal Markdown fence, not a command substitution.
printf '\n```bash\n./install.sh --platform macos --theme mocha --dry-run\n```\n' >>"$tree/docs/platforms/fedora.md"
git -C "$tree" add -A
run_capture python3 "$validator" --root "$tree"
assert_success
printf 'PASS: a command using that platform own options is accepted\n'

# Transient execution controls are not universal. --dev-workflows is rejected
# by the CTF guest's own parser, and --smoke-test is a Fedora WSL spelling, so
# a document that advertises either against the wrong platform is as wrong as
# one advertising an option that does not exist.
new_tree
# shellcheck disable=SC2016 # Literal Markdown fence, not a command substitution.
printf '\n```bash\n./install.sh --platform fedora --kde --dev-workflows\n```\n' \
  >>"$tree/docs/platforms/fedora.md"
git -C "$tree" add -A
run_capture python3 "$validator" --root "$tree"
assert_success
printf 'PASS: a transient control the platform accepts is accepted\n'

new_tree
# shellcheck disable=SC2016 # Literal Markdown fence, not a command substitution.
printf '\n```bash\n./install.sh --platform macos --smoke-test\n```\n' \
  >>"$tree/docs/platforms/fedora.md"
git -C "$tree" add -A
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "\`--smoke-test\` is not an option of --platform macos"
printf 'PASS: a transient control the platform rejects fails\n'

# --- Generated documentation must be current -------------------------------

matrix="$repo_root/docs/reference/capability-matrix.md"
options="$repo_root/docs/reference/installer-options.md"
verifiers="$repo_root/docs/reference/verifiers.md"

run_capture python3 "$repo_root/scripts/render-capability-matrix.py" --check
assert_success
run_capture python3 "$repo_root/scripts/render-installer-options.py" --check
assert_success
run_capture python3 "$repo_root/scripts/render-verifier-reference.py" --check
assert_success
printf 'PASS: generated normative documentation is current\n'

# A manifest change that is not regenerated must fail, and must not be
# repaired silently by the checker.
scratch="$TEST_ROOT/generated"
mkdir -p "$scratch"
cp "$matrix" "$scratch/capability-matrix.md"
cp "$options" "$scratch/installer-options.md"
cp "$verifiers" "$scratch/verifiers.md"
restore_generated() {
  cp "$scratch/capability-matrix.md" "$matrix"
  cp "$scratch/installer-options.md" "$options"
  cp "$scratch/verifiers.md" "$verifiers"
}
test_install_cleanup_trap restore_generated

printf '\nAn edit the manifest does not justify.\n' >>"$matrix"
run_capture python3 "$repo_root/scripts/render-capability-matrix.py" --check
assert_failure
assert_contains "$TEST_OUTPUT" "stale"
restore_generated

printf '\nAn edit the manifest does not justify.\n' >>"$options"
run_capture python3 "$repo_root/scripts/render-installer-options.py" --check
assert_failure
assert_contains "$TEST_OUTPUT" "stale"
restore_generated

printf '\nAn edit the manifest does not justify.\n' >>"$verifiers"
run_capture python3 "$repo_root/scripts/render-verifier-reference.py" --check
assert_failure
assert_contains "$TEST_OUTPUT" "stale"
restore_generated
printf 'PASS: a hand-edited generated document is rejected, not repaired\n'

# The real drift case: a manifest row changes and nothing is regenerated.
manifest_copy="$TEST_ROOT/install-options.tsv"
cp "$repo_root/config/install-options.tsv" "$manifest_copy"
restore_manifest() {
  cp "$manifest_copy" "$repo_root/config/install-options.tsv"
  restore_generated
}
test_install_cleanup_trap restore_manifest

printf 'fedora\tinvented\tboolean\t--invented\t--no-invented\tfalse\t-\t-\tAn option that was added without regenerating docs\n' \
  >>"$repo_root/config/install-options.tsv"
run_capture python3 "$repo_root/scripts/render-installer-options.py" --check
assert_failure
assert_contains "$TEST_OUTPUT" "stale"
restore_manifest
printf 'PASS: an installer-option manifest change that is not regenerated fails\n'

capabilities_copy="$TEST_ROOT/capabilities.tsv"
cp "$repo_root/config/capabilities.tsv" "$capabilities_copy"
restore_capabilities() {
  cp "$capabilities_copy" "$repo_root/config/capabilities.tsv"
  restore_manifest
}
test_install_cleanup_trap restore_capabilities

python3 - "$repo_root/config/capabilities.tsv" <<'PYTHON'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
for index, line in enumerate(lines):
    fields = line.split("\t")
    if fields[0] == "kde" and fields[1] == "fedora":
        fields[7] = "a-different-provider"
        lines[index] = "\t".join(fields)
        break
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PYTHON
run_capture python3 "$repo_root/scripts/render-capability-matrix.py" --check
assert_failure
assert_contains "$TEST_OUTPUT" "stale"
restore_capabilities
printf 'PASS: a provider change that is not regenerated fails\n'

python3 - "$repo_root/config/capabilities.tsv" <<'PYTHON'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
for index, line in enumerate(lines):
    fields = line.split("\t")
    if fields[0] == "kde" and fields[1] == "fedora":
        fields[10] = "platforms/fedora/scripts/verify-hardening.sh"
        lines[index] = "\t".join(fields)
        break
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PYTHON
run_capture python3 "$repo_root/scripts/render-verifier-reference.py" --check
assert_failure
assert_contains "$TEST_OUTPUT" "stale"
restore_capabilities
printf 'PASS: a verifier change that is not regenerated fails\n'

# --- Verification and troubleshooting cover the tools they hand people ------

assert_file_contains "$repo_root/docs/troubleshooting.md" "./doctor"
assert_file_contains "$repo_root/docs/troubleshooting.md" "Stow conflict"
assert_file_contains "$repo_root/docs/workflows/verification.md" "./doctor"
assert_file_contains "$repo_root/docs/workflows/verification.md" "reference/verifiers.md"
for flag in --codex --firstmate --gnhf --backpass; do
  assert_file_contains "$repo_root/docs/troubleshooting.md" "$flag"
done
printf 'PASS: troubleshooting and verification name doctor, Stow conflicts and every AI sub-flag\n'

# --- Every generated artifact is current and drift-proof --------------------

# The renderers that splice into a hand-written page. Each must agree with its
# manifest now, and must reject an edit made between its own markers: a page
# that is half prose and half generated is only safe if the generated half
# cannot be quietly rewritten by hand.
spliced_renderers=(
  "render-action-reference.py docs/reference/keybindings.md"
  "render-package-ownership.py docs/architecture/package-ownership.md"
  "render-install-flows.py docs/architecture/installation.md"
  "render-file-ownership.py docs/architecture/file-ownership.md"
)

spliced_scratch="$TEST_ROOT/spliced"
mkdir -p "$spliced_scratch"

for entry in "${spliced_renderers[@]}"; do
  read -r renderer target <<<"$entry"
  run_capture python3 "$repo_root/scripts/$renderer" --check
  assert_success
done
printf 'PASS: every spliced generated block is current\n'

for entry in "${spliced_renderers[@]}"; do
  read -r renderer target <<<"$entry"
  backup="$spliced_scratch/$(basename "$target")"
  cp "$repo_root/$target" "$backup"

  # Insert the edit immediately after the BEGIN marker, so it lands inside the
  # generated region rather than in the hand-written prose around it.
  python3 - "$repo_root/$target" <<'PYTHON'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
for index, line in enumerate(lines):
    if line.startswith("<!-- BEGIN GENERATED"):
        lines.insert(index + 1, "An edit the manifest does not justify.\n")
        break
else:
    raise SystemExit(f"no BEGIN GENERATED marker in {path}")
path.write_text("".join(lines), encoding="utf-8")
PYTHON

  run_capture python3 "$repo_root/scripts/$renderer" --check
  cp "$backup" "$repo_root/$target"
  assert_failure
  assert_contains "$TEST_OUTPUT" "stale"
done
printf 'PASS: a hand edit inside a generated block is rejected\n'

# Drift the manifests the new renderers read, and confirm each one notices.
# These are the exact drifts the documentation audit found by hand.
cp "$repo_root/docs/architecture/package-ownership.md" "$spliced_scratch/package-ownership.md"
cp "$repo_root/nvim-lazyvim/.config/nvim/mason-packages.txt" "$spliced_scratch/mason-packages.txt"
restore_mason() {
  cp "$spliced_scratch/mason-packages.txt" \
    "$repo_root/nvim-lazyvim/.config/nvim/mason-packages.txt"
  cp "$spliced_scratch/package-ownership.md" \
    "$repo_root/docs/architecture/package-ownership.md"
  restore_capabilities
}
test_install_cleanup_trap restore_mason

printf 'an-invented-language-server\n' \
  >>"$repo_root/nvim-lazyvim/.config/nvim/mason-packages.txt"
run_capture python3 "$repo_root/scripts/render-package-ownership.py" --check
assert_failure
assert_contains "$TEST_OUTPUT" "stale"
restore_mason
printf 'PASS: a Mason inventory change that is not regenerated fails\n'

cp "$repo_root/docs/architecture/file-ownership.md" "$spliced_scratch/file-ownership.md"
cp "$repo_root/platforms/macos/scripts/stow.sh" "$spliced_scratch/macos-stow.sh"
restore_stow() {
  cp "$spliced_scratch/macos-stow.sh" "$repo_root/platforms/macos/scripts/stow.sh"
  cp "$spliced_scratch/file-ownership.md" "$repo_root/docs/architecture/file-ownership.md"
  restore_mason
}
test_install_cleanup_trap restore_stow

python3 - "$repo_root/platforms/macos/scripts/stow.sh" <<'PYTHON'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(
    text.replace("packages=(zsh-platform", "packages=(an-invented-package zsh-platform", 1),
    encoding="utf-8",
)
PYTHON
run_capture python3 "$repo_root/scripts/render-file-ownership.py" --check
assert_failure
assert_contains "$TEST_OUTPUT" "stale"
restore_stow
printf 'PASS: a Stow package added without regenerating fails\n'

cp "$repo_root/docs/architecture/installation.md" "$spliced_scratch/installation.md"
cp "$repo_root/platforms/parrot-ctf/install.sh" "$spliced_scratch/parrot-install.sh"
restore_installer() {
  cp "$spliced_scratch/parrot-install.sh" "$repo_root/platforms/parrot-ctf/install.sh"
  cp "$spliced_scratch/installation.md" "$repo_root/docs/architecture/installation.md"
  restore_stow
}
test_install_cleanup_trap restore_installer

python3 - "$repo_root/platforms/parrot-ctf/install.sh" <<'PYTHON'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
for index, line in enumerate(lines):
    if line.startswith("plan_add verify "):
        lines.insert(index, "plan_add invented 'An unplanned step' apply : apply_invented : '' ''\n")
        break
else:
    raise SystemExit("no verify step in the Parrot installer")
path.write_text("".join(lines), encoding="utf-8")
PYTHON
run_capture python3 "$repo_root/scripts/render-install-flows.py" --check
assert_failure
assert_contains "$TEST_OUTPUT" "stale"
restore_installer
printf 'PASS: an install step added without regenerating fails\n'

# --- The generated-artifact list is complete --------------------------------

# One list, not three. Every renderer lint runs must appear in it, so adding a
# generator without documenting it fails here rather than going unnoticed.
conventions="$repo_root/docs/architecture/repository-conventions.md"
assert_file_contains "$conventions" "## Generated artifacts"
while read -r renderer; do
  assert_file_contains "$conventions" "scripts/$renderer"
done < <(grep -o 'scripts/render-[a-z-]*\.py' "$repo_root/scripts/lint.sh" |
  sed 's|scripts/||' | sort -u)
assert_file_contains "$conventions" "scripts/update-starship-themes.sh"
printf 'PASS: every generator lint runs is in the generated-artifact list\n'

# --- The theme-hook extension contract is written down ----------------------

# The one genuinely reusable extension surface in the theme subsystem. Before
# this section, writing a hook meant reading the command's source and copying
# an existing hook, and the two things easiest to get wrong -- that a hook is
# sourced inside a subshell under errexit, and which boundary function to use
# -- were written down nowhere. Each name below is part of the contract, so
# removing one from the page is a change the author has to make deliberately.
theming="$repo_root/docs/workflows/theming.md"
assert_file_contains "$theming" "## Writing a theme hook"
for boundary in theme_action theme_action_required theme_action_skipped \
  theme_capability_permits theme_capability_known_absent \
  theme_note_ghostty_handled; do
  assert_file_contains "$theming" "$boundary"
done
for scoped in flavour preserve_wallpaper DOTFILES_ROOT; do
  assert_file_contains "$theming" "$scoped"
done
assert_file_contains "$theming" "errexit"
assert_file_contains "$theming" "theme-hooks.d"
printf 'PASS: the theme-hook contract states its scope, ordering and boundaries\n'

# --- Document roles are stated ---------------------------------------------

assert_file_contains "$repo_root/docs/README.md" "## Document roles"
assert_file_contains "$repo_root/docs/README.md" "reference/capability-matrix.md"
assert_file_contains "$repo_root/docs/README.md" "cheatsheets/"
printf 'PASS: the documentation index states the document roles\n'

# --- The README is an entry point, not the manual --------------------------

readme_lines="$(wc -l <"$repo_root/README.md")"
if ((readme_lines > 400)); then
  _test_die "README.md is $readme_lines lines; it is an entry point, not the operating manual"
fi
assert_file_contains "$repo_root/README.md" "docs/README.md"
printf 'PASS: the README stays an entry point (%s lines)\n' "$readme_lines"


# --- A platform that ships a wallpaper hook is not described as lacking one ---
#
# The prose naming which platforms theme the desktop is the one thing no drift
# gate reads, and it fell a release behind when macOS gained a hook: four pages
# still said macOS had none while the hook was replacing the wallpaper on every
# display. Tie the claim to the artifact, so the next platform to gain a hook
# cannot leave the prose behind.
python3 - "$repo_root" <<'PY_WALLPAPER'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])

# The display name each platform goes by in prose. A hook whose platform is not
# listed here is a new platform: fail rather than skip, so this check cannot be
# silently outgrown.
DISPLAY = {"fedora": "Fedora", "fedora-wsl": "Fedora WSL", "macos": "macOS"}

hooks = sorted(
    root.glob("platforms/*/stow/theme-hooks/.config/dotfiles/theme-hooks.d/*.sh")
)
if not hooks:
    sys.exit("no theme hooks found; the glob in tests/test-documentation.sh is stale")

unknown = [h.stem for h in hooks if h.stem not in DISPLAY]
if unknown:
    sys.exit(
        "theme hook for an unknown platform: "
        + ", ".join(unknown)
        + "; add its prose name to DISPLAY in tests/test-documentation.sh"
    )

hooked = [h.stem for h in hooks]
wallpaper = [h.stem for h in hooks if "wallpaper" in h.read_text(encoding="utf-8")]
if sorted(wallpaper) != ["fedora", "macos"]:
    sys.exit(
        "expected exactly the Fedora and macOS hooks to set a wallpaper, found: "
        + ", ".join(sorted(wallpaper) or ["none"])
    )

# "no <platform> theme hook" in any casing.
def denies_hook(text: str, name: str) -> bool:
    return re.search(rf"\bno {re.escape(name)} theme hook\b", text, re.IGNORECASE) is not None

# A sentence saying some list of platforms has no repository-managed wallpaper.
# The name has to appear as its own item, so "Fedora WSL" in that list does not
# count as a claim about "Fedora".
DENIAL = re.compile(r"[^.]*\bno\b[^.]*repository-managed wallpaper[^.]*\.", re.IGNORECASE)

def denies_wallpaper(text: str, name: str) -> bool:
    for sentence in DENIAL.findall(text):
        flat = " ".join(sentence.split())
        for match in re.finditer(rf"\b{re.escape(name)}\b", flat, re.IGNORECASE):
            trailing = flat[match.end():]
            if name == "Fedora" and re.match(r"\s+WSL\b", trailing):
                continue
            return True
    return False

pages = sorted(root.joinpath("docs").rglob("*.md")) + [root / "README.md"]
problems = []
for page in pages:
    text = page.read_text(encoding="utf-8")
    where = page.relative_to(root)
    for platform in hooked:
        if denies_hook(text, DISPLAY[platform]):
            problems.append(f"{where}: says there is no {DISPLAY[platform]} theme hook, but {platform} ships one")
    for platform in wallpaper:
        if denies_wallpaper(text, DISPLAY[platform]):
            problems.append(
                f"{where}: says {DISPLAY[platform]} has no repository-managed wallpaper, "
                f"but its theme hook sets one"
            )

if problems:
    sys.exit("\n".join(problems))

print(f"PASS: no page denies a theme hook a platform ships ({', '.join(hooked)})")
PY_WALLPAPER

# --- The FocusGained promise has a transport ---------------------------------
#
# Two pages tell the user that refocusing the Neovim window picks up a new
# flavour, and the autocmd that does it is registered in the shared colorscheme
# fragment. Neither is worth anything inside tmux unless tmux forwards focus:
# the option defaults to off, and with it off tmux does not even ask the
# terminal for focus reporting. The promise, the consumer and the transport are
# three files that have to agree, so assert all three together.
focus_promises=(docs/troubleshooting.md docs/workflows/theming.md)
for page in "${focus_promises[@]}"; do
  assert_file_contains "$repo_root/$page" 'FocusGained'
done
assert_file_contains \
  "$repo_root/nvim-lazyvim/.config/nvim/lua/plugins/colorscheme.lua" \
  'FocusGained'
if ! grep -Eq '^set -g focus-events on$' "$repo_root/tmux/.tmux.conf"; then
  _test_die "docs promise a FocusGained reload, but tmux/.tmux.conf does not set focus-events on, so the event never reaches a pane"
fi
printf 'PASS: the documented FocusGained reload has a tmux transport\n'

# --- Counted claims are checked against the artifacts, not restated ----------
#
# Four prose claims name a number or a list that the tree already decides: the
# generators that read config/capabilities.tsv, the manifests under config/,
# the installed theme hooks, and whether a GitHub plugin exists to back the
# Octo mappings. Each was wrong on main at some point (#316), and each is wrong
# again the moment a file is added or removed, so assert them against the file
# set rather than against a remembered number.

claim_checks="$TEST_ROOT/claim-checks.py"
cat >"$claim_checks" <<'PY_CLAIMS'
"""Check the documented counts and lists against the real file set."""

import json
import pathlib
import re
import sys

WORDS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
    "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
}


def spelled(page, text, pattern, what, problems):
    """The single spelled-out number in `pattern`, or None with a problem logged."""
    found = re.findall(pattern, text, re.IGNORECASE)
    if len(found) != 1:
        problems.append(
            f"{page}: expected exactly one sentence stating {what}, found {len(found)}"
        )
        return None
    word = found[0].lower()
    if word not in WORDS:
        problems.append(f"{page}: cannot read {word!r} as a number in the {what}")
        return None
    return WORDS[word]


def generators(root, problems):
    page = "docs/capabilities.md"
    text = (root / page).read_text(encoding="utf-8")
    reading = sorted(
        path.name
        for path in (root / "scripts").glob("render-*.py")
        if "capabilities.tsv" in path.read_text(encoding="utf-8")
    )
    named = sorted(set(re.findall(r"scripts/(render-[a-z-]+\.py)", text)))
    for name in sorted(set(reading) - set(named)):
        problems.append(
            f"{page}: scripts/{name} reads config/capabilities.tsv but the page "
            f"does not tell a contributor to regenerate it"
        )
    for name in sorted(set(named) - set(reading)):
        problems.append(
            f"{page}: names scripts/{name}, which does not read config/capabilities.tsv"
        )
    stated = spelled(
        page, text, r"\b([A-Za-z]+) generators read `config/capabilities\.tsv`",
        "how many generators read config/capabilities.tsv", problems,
    )
    if stated is not None and stated != len(reading):
        problems.append(
            f"{page}: says {stated} generators read config/capabilities.tsv, "
            f"but {len(reading)} do: {', '.join(reading)}"
        )


def manifests(root, problems):
    page = "README.md"
    text = (root / page).read_text(encoding="utf-8")
    present = sorted(path.name for path in (root / "config").glob("*.tsv"))
    stated = spelled(
        page, text, r"\b([A-Za-z]+) manifests under `config/`",
        "how many manifests config/ holds", problems,
    )
    if stated is not None and stated != len(present):
        problems.append(
            f"{page}: says {stated} manifests under config/, but it holds "
            f"{len(present)}: {', '.join(present)}"
        )
    tabled = sorted(set(re.findall(r"^\| `config/([a-z-]+\.tsv)` \|", text, re.M)))
    for name in sorted(set(present) - set(tabled)):
        problems.append(f"{page}: the manifest table does not list config/{name}")
    for name in sorted(set(tabled) - set(present)):
        problems.append(f"{page}: the manifest table lists config/{name}, which does not exist")


def hooks(root, problems):
    page = "docs/workflows/theming.md"
    text = (root / page).read_text(encoding="utf-8")
    shipped = sorted(
        path.stem
        for path in root.glob(
            "platforms/*/stow/theme-hooks/.config/dotfiles/theme-hooks.d/*.sh"
        )
    )
    stated = spelled(
        page, text, r"\ball ([A-Za-z]+) existing hooks\b",
        "how many theme hooks exist", problems,
    )
    if stated is not None and stated != len(shipped):
        problems.append(
            f"{page}: says all {stated} existing hooks, but platforms/ ships "
            f"{len(shipped)}: {', '.join(shipped)}"
        )


def octo(root, problems):
    page = "docs/workflows/git.md"
    text = (root / page).read_text(encoding="utf-8")
    locks = sorted(root.glob("nvim-lazyvim/.config/nvim/**/lazy-lock.json"))
    if not locks:
        problems.append("no lazy-lock.json found; the Octo check would pass vacuously")
        return
    installed = sorted(
        {
            name
            for lock in locks
            for name in json.loads(lock.read_text(encoding="utf-8"))
            if "octo" in name.lower()
        }
    )
    documented = sorted({b for b in ("<leader>gp", "<leader>gi") if b in text})
    if not installed and documented:
        problems.append(
            f"{page}: documents {', '.join(documented)}, which only octo.nvim "
            f"provides, but no lazy-lock.json installs it"
        )
    if installed and re.search(r"Octo[^.]*not installed", text):
        problems.append(
            f"{page}: says Octo is not installed, but a lockfile pins "
            f"{', '.join(installed)}"
        )


def main():
    root = pathlib.Path(sys.argv[1])
    which = sys.argv[2]
    problems = []
    {"generators": generators, "manifests": manifests, "hooks": hooks, "octo": octo}[
        which
    ](root, problems)
    if problems:
        print("\n".join(problems))
        return 1
    print(f"PASS: the documented {which} match the tree")
    return 0


raise SystemExit(main())
PY_CLAIMS

for claim in generators manifests hooks octo; do
  run_capture python3 "$claim_checks" "$repo_root" "$claim"
  assert_success
done
printf 'PASS: every counted documentation claim matches the tree\n'

# Negative controls. Each doctors one page, or the tree the page describes, and
# requires the check to name the drift.
claim_scratch="$TEST_ROOT/claims"
mkdir -p "$claim_scratch"

claim_negative() {
  local claim="$1" page="$2" needle="$3" backup
  shift 3
  backup="$claim_scratch/$(basename "$page").$claim"
  cp "$repo_root/$page" "$backup"
  "$@"
  run_capture python3 "$claim_checks" "$repo_root" "$claim"
  cp "$backup" "$repo_root/$page"
  assert_failure
  assert_contains "$TEST_OUTPUT" "$needle"
}

# One generator dropped from the list step 4 hands a contributor.
claim_negative generators docs/capabilities.md \
  'scripts/render-file-ownership.py reads config/capabilities.tsv but the page does not tell a contributor to regenerate it' \
  sed -i '/render-file-ownership\.py/d' "$repo_root/docs/capabilities.md"

# The generator count left behind after a seventh generator is added.
claim_negative generators docs/capabilities.md \
  'says 7 generators read config/capabilities.tsv, but 6 do' \
  sed -i 's/^   Six generators read/   Seven generators read/' \
  "$repo_root/docs/capabilities.md"

# The manifest count the README carried while config/ already held eight.
claim_negative manifests README.md \
  'says 7 manifests under config/, but it holds 8' \
  sed -i 's/^Eight manifests under/Seven manifests under/' "$repo_root/README.md"

# A manifest that exists but never made it into the table.
claim_negative manifests README.md \
  'the manifest table does not list config/tool-floors.tsv' \
  sed -i '/^| `config\/tool-floors\.tsv` |/d' "$repo_root/README.md"

# The hook count left behind when the third hook was added.
claim_negative hooks docs/workflows/theming.md \
  'says all 2 existing hooks, but platforms/ ships 3: fedora, fedora-wsl, macos' \
  sed -i 's/as all three existing hooks/as all two existing hooks/' \
  "$repo_root/docs/workflows/theming.md"

# The Octo mappings, restored to a page whose lockfiles install no Octo.
claim_negative octo docs/workflows/git.md \
  'documents <leader>gi, <leader>gp, which only octo.nvim provides, but no lazy-lock.json installs it' \
  sed -i 's/^<leader>gB    open current file\/line on GitHub$/<leader>gp    GitHub pull requests\n<leader>gi    GitHub issues\n<leader>gB    open current file\/line on GitHub/' \
  "$repo_root/docs/workflows/git.md"

printf 'PASS: each counted-claim check fails on its own drift\n'

printf '\nAll documentation checks passed.\n'
