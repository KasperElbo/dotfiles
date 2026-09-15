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

run_capture python3 "$repo_root/scripts/render-capability-matrix.py" --check
assert_success
run_capture python3 "$repo_root/scripts/render-installer-options.py" --check
assert_success
printf 'PASS: generated normative documentation is current\n'

# A manifest change that is not regenerated must fail, and must not be
# repaired silently by the checker.
scratch="$TEST_ROOT/generated"
mkdir -p "$scratch"
cp "$matrix" "$scratch/capability-matrix.md"
cp "$options" "$scratch/installer-options.md"
restore_generated() {
  cp "$scratch/capability-matrix.md" "$matrix"
  cp "$scratch/installer-options.md" "$options"
}
trap 'restore_generated; test_cleanup' EXIT INT TERM

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
printf 'PASS: a hand-edited generated document is rejected, not repaired\n'

# The real drift case: a manifest row changes and nothing is regenerated.
manifest_copy="$TEST_ROOT/install-options.tsv"
cp "$repo_root/config/install-options.tsv" "$manifest_copy"
restore_manifest() {
  cp "$manifest_copy" "$repo_root/config/install-options.tsv"
  restore_generated
}
trap 'restore_manifest; test_cleanup' EXIT INT TERM

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
trap 'restore_capabilities; test_cleanup' EXIT INT TERM

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
trap 'restore_mason; test_cleanup' EXIT INT TERM

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
trap 'restore_stow; test_cleanup' EXIT INT TERM

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
trap 'restore_installer; test_cleanup' EXIT INT TERM

python3 - "$repo_root/platforms/parrot-ctf/install.sh" <<'PYTHON'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
for index, line in enumerate(lines):
    if line.startswith("plan_add verify "):
        lines.insert(index, "plan_add invented 'An unplanned step' apply : apply_invented : ''\n")
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

printf '\nAll documentation checks passed.\n'
