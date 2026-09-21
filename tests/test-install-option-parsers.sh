#!/usr/bin/env bash
# The platform installers' argv parsers against config/install-options.tsv
# (#242). Neither may gain a flag the other does not know: a parser-only flag
# is never remembered by --rerun, and a manifest-only flag stops every install
# on its platform.
#
# Each negative case edits a scratch copy of the repository and runs that
# copy's validator, or points the validator at a scratch manifest through
# INSTALL_OPTION_MANIFEST. This checkout is never modified.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap

# scratch_tree: a disposable copy of this checkout, without its Git metadata.
scratch_tree() {
  test_new_root
  tree="$TEST_ROOT/tree"
  mkdir -p "$tree"
  cp -R "$repo_root/." "$tree/"
  rm -rf -- "$tree/.git"
}

# replace_line FILE OLD NEW: replace one exact line. A line that is not there
# exactly once fails the suite, so a reworded installer cannot turn a negative
# case into a vacuous pass.
replace_line() {
  python3 - "$@" <<'PYTHON'
import pathlib
import sys

path, old, new = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
lines = path.read_text(encoding="utf-8").split("\n")
if lines.count(old) != 1:
    sys.exit(f"expected exactly one line {old!r} in {path}")
lines[lines.index(old)] = new
path.write_text("\n".join(lines), encoding="utf-8")
PYTHON
}

fedora_kde_arm='  --kde) install_kde=enabled; shift ;; --no-kde) install_kde=disabled; shift ;;'
fedora_tailscale_arm='  --tailscale) install_tailscale=true; shift ;; --no-tailscale) install_tailscale=false; shift ;;'
wsl_tailscale_arm="  --tailscale | --no-tailscale) die '--tailscale is not supported on Fedora WSL: install Tailscale on the Windows host instead.' ;;"

run_capture python3 "$repo_root/scripts/validate-install-options.py"
assert_success
printf 'PASS: every installer parser agrees with the option manifest\n'

# --- A flag the parser accepts but the manifest never declares ---------------

scratch_tree
replace_line "$tree/platforms/fedora/install.sh" "$fedora_kde_arm" \
  "$fedora_kde_arm
  --turbo) install_turbo=true; shift ;; --no-turbo) install_turbo=false; shift ;;"
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "fedora: platforms/fedora/install.sh accepts --turbo, which the manifest does not declare"
assert_contains "$TEST_OUTPUT" "accepts --no-turbo"
printf 'PASS: a parser flag missing from the manifest fails, by name\n'

# --- A manifest option the parser never implements ---------------------------

test_new_root
manifest="$TEST_ROOT/install-options.tsv"
cp "$repo_root/config/install-options.tsv" "$manifest"
printf 'fedora\tfooopt\tboolean\t--fooopt\t--no-fooopt\tfalse\t-\t-\tFoo option\n' >>"$manifest"
run_capture env "INSTALL_OPTION_MANIFEST=$manifest" \
  python3 "$repo_root/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "fedora: the manifest declares --fooopt, but platforms/fedora/install.sh has no case arm for it"
assert_contains "$TEST_OUTPUT" "declares --no-fooopt"
printf 'PASS: a manifest option the parser does not implement fails, by name\n'

scratch_tree
replace_line "$tree/platforms/fedora/install.sh" "$fedora_tailscale_arm" \
  '  --no-tailscale) install_tailscale=false; shift ;;'
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "fedora: the manifest declares --tailscale, but platforms/fedora/install.sh has no case arm for it"
assert_not_contains "$TEST_OUTPUT" "--no-tailscale"
printf 'PASS: a deleted parser arm fails, naming only the flag that lost it\n'

scratch_tree
replace_line "$tree/platforms/fedora/install.sh" "$fedora_kde_arm" \
  "  --kde) die 'no KDE today' ;; --no-kde) install_kde=disabled; shift ;;"
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "fedora: the manifest declares --kde, but platforms/fedora/install.sh rejects it"
printf 'PASS: a manifest option the parser rejects fails, by name\n'

# --- Deliberate rejections stay deliberate -----------------------------------

scratch_tree
replace_line "$tree/platforms/fedora-wsl/install.sh" "$wsl_tailscale_arm" ''
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "fedora-wsl: --tailscale is listed in REJECTED_FLAGS, but platforms/fedora-wsl/install.sh has no case arm that rejects it"
printf 'PASS: a documented rejection whose arm disappeared fails, by name\n'

scratch_tree
replace_line "$tree/platforms/fedora-wsl/install.sh" "$wsl_tailscale_arm" \
  '  --tailscale | --no-tailscale) shift ;;'
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "fedora-wsl: --tailscale is listed in REJECTED_FLAGS, but platforms/fedora-wsl/install.sh accepts it"
printf 'PASS: a rejected flag the parser starts accepting fails, by name\n'

scratch_tree
replace_line "$tree/platforms/macos/install.sh" \
  '  --non-interactive) interactive=false; shift ;;' \
  "  --non-interactive) interactive=false; shift ;;
  --sway | --no-sway) die 'Sway is a Linux session.' ;;"
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "macos: platforms/macos/install.sh rejects --sway; list it in REJECTED_FLAGS with the reason"
printf 'PASS: an undocumented rejection fails, by name\n'

printf 'Installer option parser validation passed.\n'
