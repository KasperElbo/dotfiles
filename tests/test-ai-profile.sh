#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

mock_bin="$test_root/bin"
mise_shims="$test_root/mise-shims"
home="$test_root/home"
config="$home/.config"
data="$home/.local/share"
mkdir -p "$mock_bin" "$mise_shims" "$home" "$config" "$data"

# Mocks mise closely enough to exercise install-ai.sh/verify-ai.sh without a
# real mise install: 'mise --yes install' materializes a shim for each tool
# declared in the AI profile's untracked conf.d file (so codex only appears
# when actually declared), and 'mise which' reports it the same way a real
# mise would, letting verify-ai.sh's ownership check exercise its real logic.
cat >"$mock_bin/mise" <<'EOF'
#!/usr/bin/env bash
conf_file="$XDG_CONFIG_HOME/mise/conf.d/ai.toml"

make_shim() {
  printf '#!/usr/bin/env bash\nexit 0\n' >"$MISE_SHIMS_DIR/$1"
  chmod +x "$MISE_SHIMS_DIR/$1"
}

case "${1:-}" in
--yes)
  if [[ "${2:-}" == install ]]; then
    mkdir -p "$MISE_SHIMS_DIR"
    grep -Fq 'claude-code' "$conf_file" 2>/dev/null && make_shim claude
    grep -Fq 'herdr' "$conf_file" 2>/dev/null && make_shim herdr
    grep -Fq 'openai/codex' "$conf_file" 2>/dev/null && make_shim codex
  fi
  exit 0
  ;;
which)
  name="${2:-}"
  if [[ -x "$MISE_SHIMS_DIR/$name" ]]; then
    printf '%s\n' "$MISE_SHIMS_DIR/$name"
    exit 0
  else
    exit 1
  fi
  ;;
esac
exit 0
EOF
chmod +x "$mock_bin/mise"

for command_name in gh tmux; do
  cat >"$mock_bin/$command_name" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$mock_bin/$command_name"
done

# Mocks Treehouse's real install.sh closely enough to exercise install-ai.sh
# without the network: given a URL containing "treehouse", print a tiny
# installer script to stdout, which install-ai.sh pipes into 'sh' itself
# (matching the real 'curl ... | sh' invocation).
cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "$arg" in
  http*) url="$arg" ;;
  esac
done
if [[ "$url" == *treehouse* ]]; then
  printf '#!/usr/bin/env sh\n'
  printf 'mkdir -p "$HOME/.local/bin"\n'
  printf 'printf "#!/usr/bin/env sh\\nexit 0\\n" >"$HOME/.local/bin/treehouse"\n'
  printf 'chmod +x "$HOME/.local/bin/treehouse"\n'
fi
EOF
chmod +x "$mock_bin/curl"

# A real local Git repository stands in for kunchenguid/firstmate so the
# clone/update path exercises real git, not a mock, without touching the
# network.
firstmate_origin="$test_root/firstmate-origin"
mkdir -p "$firstmate_origin"
git -C "$firstmate_origin" init -q
git -C "$firstmate_origin" config user.name Test
git -C "$firstmate_origin" config user.email test@example.invalid
printf '# FirstMate fixture\n' >"$firstmate_origin/README.md"
git -C "$firstmate_origin" add README.md
git -C "$firstmate_origin" commit -qm 'Initial commit'

test_environment=(
  env
  "HOME=$home"
  "XDG_CONFIG_HOME=$config"
  "XDG_DATA_HOME=$data"
  "PATH=$home/.local/bin:$mise_shims:$mock_bin:$PATH"
  "MISE_SHIMS_DIR=$mise_shims"
  "FIRSTMATE_REPO_URL=$firstmate_origin"
)

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || {
    printf 'Expected output to contain %q:\n%s\n' "$needle" "$haystack" >&2
    exit 1
  }
}

conf_file="$config/mise/conf.d/ai.toml"
state_file="$config/dotfiles/ai.conf"
treehouse_target="$home/.local/bin/treehouse"

# --- Core profile: Claude Code + Herdr only -------------------------------

if ! "${test_environment[@]}" "$repo_root/common/install-ai.sh" \
  >"$test_root/install-core.log" 2>&1; then
  cat "$test_root/install-core.log" >&2
  printf 'install-ai.sh (core) failed\n' >&2
  exit 1
fi

[[ -f "$conf_file" ]] || {
  printf 'AI mise conf.d file missing: %s\n' "$conf_file" >&2
  exit 1
}
grep -Fq '"npm:@anthropic-ai/claude-code" = "latest"' "$conf_file"
grep -Fq 'herdr = "latest"' "$conf_file"
if grep -Fq 'openai/codex' "$conf_file"; then
  printf 'Codex declared without --codex\n' >&2
  exit 1
fi

grep -Fqx 'profile=ai' "$state_file"
grep -Fqx 'claude_code=mise-npm' "$state_file"
grep -Fqx 'herdr=mise' "$state_file"
grep -Fqx 'codex=disabled' "$state_file"
grep -Fqx 'firstmate=disabled' "$state_file"
grep -Fqx 'treehouse=disabled' "$state_file"

[[ ! -e "$treehouse_target" ]] || {
  printf 'Treehouse was installed without --firstmate: %s\n' "$treehouse_target" >&2
  exit 1
}

if ! verify_core_output="$("${test_environment[@]}" "$repo_root/common/verify-ai.sh" 2>&1)"; then
  printf '%s\n' "$verify_core_output" >&2
  printf 'verify-ai.sh (core) failed\n' >&2
  exit 1
fi
assert_contains "$verify_core_output" 'claude is mise-managed'
assert_contains "$verify_core_output" 'herdr is mise-managed'
assert_contains "$verify_core_output" 'codex is not installed'
assert_contains "$verify_core_output" 'FirstMate is not installed'
assert_contains "$verify_core_output" 'Treehouse is not installed'

# --- Idempotency: rerunning changes nothing --------------------------------

first_sum="$(sha256sum "$conf_file" "$state_file")"
"${test_environment[@]}" "$repo_root/common/install-ai.sh" >/dev/null
second_sum="$(sha256sum "$conf_file" "$state_file")"
[[ "$first_sum" == "$second_sum" ]] || {
  printf 'Rerunning install-ai.sh (core) changed tracked state\n' >&2
  exit 1
}

# --- Codex + FirstMate subcomponents ---------------------------------------

if ! "${test_environment[@]}" "$repo_root/common/install-ai.sh" \
  --codex --firstmate >"$test_root/install-full.log" 2>&1; then
  cat "$test_root/install-full.log" >&2
  printf 'install-ai.sh (--codex --firstmate) failed\n' >&2
  exit 1
fi

grep -Fq '"npm:@openai/codex" = "latest"' "$conf_file"
grep -Fqx 'codex=mise-npm' "$state_file"
grep -Fqx 'firstmate=cloned' "$state_file"
grep -Fqx 'treehouse=installed' "$state_file"
[[ -d "$data/firstmate/.git" ]] || {
  printf 'FirstMate was not cloned to %s\n' "$data/firstmate" >&2
  exit 1
}
[[ -x "$treehouse_target" ]] || {
  printf 'Treehouse was not installed to %s\n' "$treehouse_target" >&2
  exit 1
}

if ! verify_full_output="$("${test_environment[@]}" "$repo_root/common/verify-ai.sh" 2>&1)"; then
  printf '%s\n' "$verify_full_output" >&2
  printf 'verify-ai.sh (--codex --firstmate) failed\n' >&2
  exit 1
fi
assert_contains "$verify_full_output" 'codex is mise-managed'
assert_contains "$verify_full_output" 'FirstMate cloned'
assert_contains "$verify_full_output" "treehouse: $treehouse_target"
assert_contains "$verify_full_output" 'treehouse on PATH resolves to the installed copy'

# Rerunning updates (git pull --ff-only, and reruns the Treehouse installer)
# rather than re-cloning or failing.
"${test_environment[@]}" "$repo_root/common/install-ai.sh" \
  --codex --firstmate >/dev/null

# --- --validate forwards to verify-ai.sh ------------------------------------

"${test_environment[@]}" "$repo_root/common/install-ai.sh" --validate >/dev/null

# --- --dry-run changes nothing ----------------------------------------------

dry_home="$test_root/dry-home"
mkdir -p "$dry_home"
dry_run_output="$(
  env HOME="$dry_home" XDG_CONFIG_HOME="$dry_home/.config" \
    XDG_DATA_HOME="$dry_home/.local/share" PATH="$mock_bin:$PATH" \
    "$repo_root/common/install-ai.sh" --dry-run --codex --firstmate
)"
assert_contains "$dry_run_output" 'Codex CLI:            true'
assert_contains "$dry_run_output" 'FirstMate crew stack: true'
assert_contains "$dry_run_output" 'Install Treehouse'
assert_contains "$dry_run_output" 'No changes were made.'

if find "$dry_home" -mindepth 1 -print -quit | grep -q .; then
  printf 'AI profile dry-run mutated state under %s\n' "$dry_home" >&2
  exit 1
fi

# --- Rejects unknown options and bad combinations ---------------------------

if "${test_environment[@]}" "$repo_root/common/install-ai.sh" --dry-run \
  --validate >"$test_root/combo.log" 2>&1; then
  printf 'install-ai.sh accepted --dry-run and --validate together\n' >&2
  exit 1
fi
grep -Fq -- '--dry-run and --validate cannot be combined' "$test_root/combo.log"

if "${test_environment[@]}" "$repo_root/common/install-ai.sh" --bogus \
  >"$test_root/unknown.log" 2>&1; then
  printf 'install-ai.sh accepted an unknown option\n' >&2
  exit 1
fi
grep -Fq 'Unknown option: --bogus' "$test_root/unknown.log"

printf 'AI profile install/verify/idempotency tests passed.\n'
