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

# Everything the audit named as a trust source is actually registered.
for source_id in terra-repo terra-signing-key rpmfusion-free-release \
  rpmfusion-nonfree-release tailscale-repo mise-installer starship-installer \
  homebrew-installer homebrew-formulae scoop-installer catppuccin-tmux \
  catppuccin-kde firstmate-repo treehouse-installer no-mistakes-installer \
  npm-registry opam-repository lazyvim-plugins mason-registry \
  validation-image-fedora; do
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
git -C "$fixture_repo" add scripts/unregistered-source.sh
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
git -C "$fixture_repo" add scripts/unregistered-clone.sh
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
git -C "$fixture_repo" add scripts/unregistered-image.sh
if lint_output="$(lint_fixture)"; then
  printf 'The linter accepted an unregistered validation image.\n' >&2
  exit 1
fi
assert_contains "$lint_output" 'unregistered container-image network source'
rm -f -- "$fixture_repo/scripts/unregistered-image.sh"
git -C "$fixture_repo" add -A
printf 'PASS: an unregistered container image fails the linter\n'

# A presence check or a package-list entry is not an invocation and must not
# require an annotation, or the linter becomes noise people learn to ignore.
cat >"$fixture_repo/scripts/mentions-curl.sh" <<'EOF'
#!/usr/bin/env bash
packages=(bat curl eza)
require_command curl
printf 'curl is required.\n'
EOF
git -C "$fixture_repo" add scripts/mentions-curl.sh
lint_fixture >/dev/null
rm -f -- "$fixture_repo/scripts/mentions-curl.sh"
git -C "$fixture_repo" add -A
printf 'PASS: naming curl without invoking it needs no annotation\n'

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
