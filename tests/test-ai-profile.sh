#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

mock_bin="$test_root/bin"
home="$test_root/home"
config="$home/.config"
data="$home/.local/share"
mise_data="$data/mise"
mise_shims="$mise_data/shims"
mise_installs="$mise_data/installs"
mkdir -p "$mock_bin" "$mise_shims" "$mise_installs" "$home" "$config" "$data"

# Mocks mise closely enough to exercise install-ai.sh/verify-ai.sh without a
# real mise install: 'mise --yes install' materializes a shim for each tool
# declared in the AI profile's untracked conf.d file (so codex only appears
# when actually declared). A command resolves through mise's shim directory,
# while 'mise which' reports the underlying installed executable, matching
# real mise behavior.
cat >"$mock_bin/mise" <<'EOF'
#!/usr/bin/env bash
conf_file="$XDG_CONFIG_HOME/mise/conf.d/ai.toml"

make_shim() {
  install_bin="$MISE_INSTALLS_DIR/$1/latest/bin/$1"
  mkdir -p "$(dirname "$install_bin")"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$install_bin"
  chmod +x "$install_bin"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$install_bin" >"$MISE_SHIMS_DIR/$1"
  chmod +x "$MISE_SHIMS_DIR/$1"
}

case "${1:-}" in
--yes)
  if [[ "${2:-}" == install ]]; then
    mkdir -p "$MISE_SHIMS_DIR"
    grep -Fq 'claude-code' "$conf_file" 2>/dev/null && make_shim claude
    grep -Fq 'herdr' "$conf_file" 2>/dev/null && make_shim herdr
    grep -Fq 'openai/codex' "$conf_file" 2>/dev/null && make_shim codex
    grep -Fq '"npm:gnhf"' "$conf_file" 2>/dev/null && make_shim gnhf
    grep -Fq '"npm:gh-axi"' "$conf_file" 2>/dev/null && make_shim gh-axi
    grep -Fq '"npm:chrome-devtools-axi"' "$conf_file" 2>/dev/null && make_shim chrome-devtools-axi
    grep -Fq '"npm:lavish-axi"' "$conf_file" 2>/dev/null && make_shim lavish-axi
    grep -Fq '"npm:tasks-axi"' "$conf_file" 2>/dev/null && make_shim tasks-axi
    grep -Fq '"npm:quota-axi"' "$conf_file" 2>/dev/null && make_shim quota-axi
    grep -Fq '"npm:backpass"' "$conf_file" 2>/dev/null && make_shim backpass
    grep -Fq '"npm:acpx"' "$conf_file" 2>/dev/null && make_shim acpx
  fi
  exit 0
  ;;
which)
  name="${2:-}"
  install_bin="$MISE_INSTALLS_DIR/$name/latest/bin/$name"
  if [[ -x "$install_bin" ]]; then
    printf '%s\n' "$install_bin"
    exit 0
  else
    exit 1
  fi
  ;;
esac
exit 0
EOF
chmod +x "$mock_bin/mise"

for command_name in gh tmux jq; do
  cat >"$mock_bin/$command_name" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$mock_bin/$command_name"
done

# Mocks Treehouse's and No Mistakes' real install scripts closely enough to
# exercise install-ai.sh without the network: given a URL containing the
# tool's name, print a tiny installer script to stdout, which install-ai.sh
# pipes into 'sh' itself (matching the real 'curl ... | sh' invocation).
cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "$arg" in
  http*) url="$arg" ;;
  esac
done
emit_installer() {
  printf '#!/usr/bin/env sh\n'
  printf 'mkdir -p "$HOME/.local/bin"\n'
  printf 'printf "#!/usr/bin/env sh\\nexit 0\\n" >"$HOME/.local/bin/%s"\n' "$1"
  printf 'chmod +x "$HOME/.local/bin/%s"\n' "$1"
}
if [[ "$url" == *treehouse* ]]; then
  emit_installer treehouse
elif [[ "$url" == *no-mistakes* ]]; then
  emit_installer no-mistakes
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
  "CODEX_HOME=$home/.codex"
  "XDG_CONFIG_HOME=$config"
  "XDG_DATA_HOME=$data"
  "PATH=$home/.local/bin:$mise_shims:$mock_bin:$PATH"
  "MISE_DATA_DIR=$mise_data"
  "MISE_SHIMS_DIR=$mise_shims"
  "MISE_INSTALLS_DIR=$mise_installs"
  "FIRSTMATE_REPO_URL=$firstmate_origin"
)

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || {
    printf 'Expected output to contain %q:\n%s\n' "$needle" "$haystack" >&2
    exit 1
  }
}

# FirstMate prerequisites are checked before the installer writes any profile
# state or asks mise to install tools. Platform installers normally provide
# these commands, but the portable entry point must also fail atomically when
# called on its own in an incomplete environment.
missing_jq_bin="$test_root/missing-jq-bin"
missing_jq_home="$test_root/missing-jq-home"
mkdir -p "$missing_jq_bin" "$missing_jq_home"
for command_name in bash dirname git; do
  ln -s "$(command -v "$command_name")" "$missing_jq_bin/$command_name"
done
for command_name in mise gh tmux curl; do
  ln -s "$mock_bin/$command_name" "$missing_jq_bin/$command_name"
done
if missing_jq_output="$(env \
  HOME="$missing_jq_home" CODEX_HOME="$missing_jq_home/.codex" \
  XDG_CONFIG_HOME="$missing_jq_home/.config" \
  XDG_DATA_HOME="$missing_jq_home/.local/share" \
  PATH="$missing_jq_bin" MISE_DATA_DIR="$mise_data" \
  MISE_SHIMS_DIR="$mise_shims" MISE_INSTALLS_DIR="$mise_installs" \
  FIRSTMATE_REPO_URL="$firstmate_origin" \
  "$repo_root/common/install-ai.sh" --firstmate 2>&1)"; then
  printf 'install-ai.sh accepted --firstmate without jq\n' >&2
  exit 1
fi
assert_contains "$missing_jq_output" 'Required command not found: jq'
[[ ! -e "$missing_jq_home/.config/mise/conf.d/ai.toml" ]]
[[ ! -e "$missing_jq_home/.config/dotfiles/ai.conf" ]]
[[ ! -e "$missing_jq_home/.claude/CLAUDE.md" ]]

conf_file="$config/mise/conf.d/ai.toml"
state_file="$config/dotfiles/ai.conf"
treehouse_target="$home/.local/bin/treehouse"
agents_source="$repo_root/common/assets/AGENTS.md"
claude_md_target="$home/.claude/CLAUDE.md"
codex_agents_target="$home/.codex/AGENTS.md"
opencode_agents_target="$config/opencode/AGENTS.md"

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
grep -Fq '"npm:@anthropic-ai/claude-code" = { version = "latest", npm_args = "--ignore-scripts=false" }' "$conf_file"
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
grep -Fqx 'no_mistakes=disabled' "$state_file"
grep -Fqx 'gh_axi=disabled' "$state_file"
grep -Fqx 'chrome_devtools_axi=disabled' "$state_file"
grep -Fqx 'lavish_axi=disabled' "$state_file"
grep -Fqx 'tasks_axi=disabled' "$state_file"
grep -Fqx 'quota_axi=disabled' "$state_file"
grep -Fqx 'gnhf=disabled' "$state_file"
grep -Fqx 'backpass=disabled' "$state_file"
grep -Fqx 'acpx=disabled' "$state_file"

[[ ! -e "$treehouse_target" ]] || {
  printf 'Treehouse was installed without --firstmate: %s\n' "$treehouse_target" >&2
  exit 1
}

for target in "$claude_md_target" "$codex_agents_target" "$opencode_agents_target"; do
  [[ -L "$target" ]] || {
    printf 'Expected a symlink at %s\n' "$target" >&2
    exit 1
  }
  [[ "$(readlink "$target")" == "$agents_source" ]] || {
    printf '%s does not link to %s\n' "$target" "$agents_source" >&2
    exit 1
  }
done

if ! verify_core_output="$("${test_environment[@]}" "$repo_root/common/verify-ai.sh" 2>&1)"; then
  printf '%s\n' "$verify_core_output" >&2
  printf 'verify-ai.sh (core) failed\n' >&2
  exit 1
fi
assert_contains "$verify_core_output" 'claude is mise-managed'
assert_contains "$verify_core_output" 'claude launches successfully: claude --version'
assert_contains "$verify_core_output" 'herdr is mise-managed'
assert_contains "$verify_core_output" 'codex is not installed'
assert_contains "$verify_core_output" 'FirstMate is not installed'
assert_contains "$verify_core_output" 'FirstMate toolchain is not installed'
assert_contains "$verify_core_output" 'Treehouse is not installed'
assert_contains "$verify_core_output" 'No Mistakes is not installed'
assert_contains "$verify_core_output" 'gnhf is not installed'
assert_contains "$verify_core_output" 'lavish-axi is not installed'
assert_contains "$verify_core_output" 'backpass is not installed'
assert_contains "$verify_core_output" \
  "Claude Code (CLAUDE.md): $claude_md_target -> $agents_source"
assert_contains "$verify_core_output" \
  "Codex (AGENTS.md): $codex_agents_target -> $agents_source"
assert_contains "$verify_core_output" \
  "OpenCode (AGENTS.md): $opencode_agents_target -> $agents_source"

# --- Idempotency: rerunning changes nothing --------------------------------

first_sum="$(sha256sum "$conf_file" "$state_file")"
"${test_environment[@]}" "$repo_root/common/install-ai.sh" >/dev/null
second_sum="$(sha256sum "$conf_file" "$state_file")"
[[ "$first_sum" == "$second_sum" ]] || {
  printf 'Rerunning install-ai.sh (core) changed tracked state\n' >&2
  exit 1
}

for target in "$claude_md_target" "$codex_agents_target" "$opencode_agents_target"; do
  [[ "$(readlink "$target")" == "$agents_source" ]] || {
    printf 'Rerunning install-ai.sh (core) changed the %s symlink\n' "$target" >&2
    exit 1
  }
done

# --- Codex + FirstMate + GNHF + backpass subcomponents ----------------------

if ! "${test_environment[@]}" "$repo_root/common/install-ai.sh" \
  --codex --firstmate --gnhf --backpass >"$test_root/install-full.log" 2>&1; then
  cat "$test_root/install-full.log" >&2
  printf 'install-ai.sh (--codex --firstmate --gnhf --backpass) failed\n' >&2
  exit 1
fi

grep -Fq '"npm:@openai/codex" = "latest"' "$conf_file"
grep -Fq '"npm:gnhf" = "latest"' "$conf_file"
for tool in gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi backpass acpx; do
  grep -Fq "\"npm:$tool\" = \"latest\"" "$conf_file"
done
# lavish-axi is wanted by both --firstmate and --backpass; it must appear
# exactly once in the generated TOML, not as a duplicate key.
[[ "$(grep -Fc '"npm:lavish-axi"' "$conf_file")" == 1 ]] || {
  printf 'lavish-axi declared more than once in %s\n' "$conf_file" >&2
  exit 1
}
grep -Fqx 'codex=mise-npm' "$state_file"
grep -Fqx 'firstmate=cloned' "$state_file"
grep -Fqx 'treehouse=installed' "$state_file"
grep -Fqx 'no_mistakes=installed' "$state_file"
grep -Fqx 'gh_axi=mise-npm' "$state_file"
grep -Fqx 'chrome_devtools_axi=mise-npm' "$state_file"
grep -Fqx 'lavish_axi=mise-npm' "$state_file"
grep -Fqx 'tasks_axi=mise-npm' "$state_file"
grep -Fqx 'quota_axi=mise-npm' "$state_file"
grep -Fqx 'gnhf=mise-npm' "$state_file"
grep -Fqx 'backpass=mise-npm' "$state_file"
grep -Fqx 'acpx=mise-npm' "$state_file"
[[ -d "$data/firstmate/.git" ]] || {
  printf 'FirstMate was not cloned to %s\n' "$data/firstmate" >&2
  exit 1
}
[[ -x "$treehouse_target" ]] || {
  printf 'Treehouse was not installed to %s\n' "$treehouse_target" >&2
  exit 1
}
no_mistakes_target="$home/.local/bin/no-mistakes"
[[ -x "$no_mistakes_target" ]] || {
  printf 'No Mistakes was not installed to %s\n' "$no_mistakes_target" >&2
  exit 1
}

if ! verify_full_output="$("${test_environment[@]}" "$repo_root/common/verify-ai.sh" 2>&1)"; then
  printf '%s\n' "$verify_full_output" >&2
  printf 'verify-ai.sh (--codex --firstmate --gnhf --backpass) failed\n' >&2
  exit 1
fi
assert_contains "$verify_full_output" 'codex is mise-managed'
assert_contains "$verify_full_output" 'gnhf is mise-managed'
assert_contains "$verify_full_output" 'FirstMate cloned'
assert_contains "$verify_full_output" "treehouse: $treehouse_target"
assert_contains "$verify_full_output" 'treehouse on PATH resolves to the installed copy'
assert_contains "$verify_full_output" "no-mistakes: $no_mistakes_target"
assert_contains "$verify_full_output" 'no-mistakes on PATH resolves to the installed copy'
assert_contains "$verify_full_output" 'gh-axi is mise-managed'
assert_contains "$verify_full_output" 'chrome-devtools-axi is mise-managed'
assert_contains "$verify_full_output" 'lavish-axi is mise-managed'
assert_contains "$verify_full_output" 'tasks-axi is mise-managed'
assert_contains "$verify_full_output" 'quota-axi is mise-managed'
assert_contains "$verify_full_output" 'backpass is mise-managed'
assert_contains "$verify_full_output" 'acpx is mise-managed'

# A genuinely competing executable ahead of mise's shim must still fail.
shadow_bin="$test_root/shadow-bin"
mkdir -p "$shadow_bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$shadow_bin/claude"
chmod +x "$shadow_bin/claude"
if shadow_output="$(env \
  HOME="$home" XDG_CONFIG_HOME="$config" XDG_DATA_HOME="$data" \
  CODEX_HOME="$home/.codex" \
  MISE_DATA_DIR="$mise_data" MISE_SHIMS_DIR="$mise_shims" \
  MISE_INSTALLS_DIR="$mise_installs" \
  PATH="$shadow_bin:$home/.local/bin:$mise_shims:$mock_bin:$PATH" \
  "$repo_root/common/verify-ai.sh" 2>&1)"; then
  printf 'verify-ai.sh accepted a command shadowing mise: %s\n' \
    "$shadow_bin/claude" >&2
  exit 1
fi
assert_contains "$shadow_output" 'claude resolves outside mise'

# Ownership alone is insufficient if an npm lifecycle step was skipped and
# left Claude Code's platform-native binary unlinked.
claude_install="$mise_installs/claude/latest/bin/claude"
printf '#!/usr/bin/env bash\nexit 1\n' >"$claude_install"
chmod +x "$claude_install"
if broken_claude_output="$("${test_environment[@]}" \
  "$repo_root/common/verify-ai.sh" 2>&1)"; then
  printf 'verify-ai.sh accepted a Claude Code executable that cannot launch\n' >&2
  exit 1
fi
assert_contains "$broken_claude_output" \
  "claude is installed but 'claude --version' failed"
printf '#!/usr/bin/env bash\nexit 0\n' >"$claude_install"
chmod +x "$claude_install"

# Rerunning updates (git pull --ff-only, and reruns the Treehouse installer)
# rather than re-cloning or failing.
"${test_environment[@]}" "$repo_root/common/install-ai.sh" \
  --codex --firstmate --gnhf --backpass >/dev/null

# --- backpass alone (no --firstmate) still gets lavish-axi ------------------

backpass_only_home="$test_root/backpass-only-home"
mkdir -p "$backpass_only_home"
backpass_only_environment=(
  env
  "HOME=$backpass_only_home"
  "CODEX_HOME=$backpass_only_home/.codex"
  "XDG_CONFIG_HOME=$backpass_only_home/.config"
  "XDG_DATA_HOME=$backpass_only_home/.local/share"
  "PATH=$backpass_only_home/.local/bin:$mise_shims:$mock_bin:$PATH"
  "MISE_DATA_DIR=$mise_data"
  "MISE_SHIMS_DIR=$mise_shims"
  "MISE_INSTALLS_DIR=$mise_installs"
)
if ! "${backpass_only_environment[@]}" "$repo_root/common/install-ai.sh" \
  --backpass >"$test_root/install-backpass-only.log" 2>&1; then
  cat "$test_root/install-backpass-only.log" >&2
  printf 'install-ai.sh (--backpass, no --firstmate) failed\n' >&2
  exit 1
fi
backpass_only_conf="$backpass_only_home/.config/mise/conf.d/ai.toml"
grep -Fq '"npm:lavish-axi" = "latest"' "$backpass_only_conf"
grep -Fq '"npm:backpass" = "latest"' "$backpass_only_conf"
if grep -Fq '"npm:gh-axi"' "$backpass_only_conf"; then
  printf 'FirstMate-only tools declared without --firstmate\n' >&2
  exit 1
fi
if ! backpass_only_verify="$("${backpass_only_environment[@]}" \
  "$repo_root/common/verify-ai.sh" 2>&1)"; then
  printf '%s\n' "$backpass_only_verify" >&2
  printf 'verify-ai.sh (--backpass, no --firstmate) failed\n' >&2
  exit 1
fi
assert_contains "$backpass_only_verify" 'lavish-axi is mise-managed'
assert_contains "$backpass_only_verify" 'backpass is mise-managed'
assert_contains "$backpass_only_verify" 'FirstMate is not installed'

# --- Shared agent instructions never overwrite an existing file/symlink ----

preexisting_home="$test_root/preexisting-home"
mkdir -p "$preexisting_home/.claude"
printf 'my own Claude instructions\n' >"$preexisting_home/.claude/CLAUDE.md"
preexisting_environment=(
  env
  "HOME=$preexisting_home"
  "CODEX_HOME=$preexisting_home/.codex"
  "XDG_CONFIG_HOME=$preexisting_home/.config"
  "XDG_DATA_HOME=$preexisting_home/.local/share"
  "PATH=$preexisting_home/.local/bin:$mise_shims:$mock_bin:$PATH"
  "MISE_DATA_DIR=$mise_data"
  "MISE_SHIMS_DIR=$mise_shims"
  "MISE_INSTALLS_DIR=$mise_installs"
)
if ! "${preexisting_environment[@]}" "$repo_root/common/install-ai.sh" \
  >"$test_root/install-preexisting.log" 2>&1; then
  cat "$test_root/install-preexisting.log" >&2
  printf 'install-ai.sh (pre-existing CLAUDE.md) failed\n' >&2
  exit 1
fi

[[ "$(cat "$preexisting_home/.claude/CLAUDE.md")" == 'my own Claude instructions' ]] || {
  printf 'install-ai.sh overwrote a pre-existing ~/.claude/CLAUDE.md\n' >&2
  exit 1
}
[[ ! -L "$preexisting_home/.claude/CLAUDE.md" ]] || {
  printf 'install-ai.sh replaced a pre-existing CLAUDE.md file with a symlink\n' >&2
  exit 1
}
[[ "$(readlink "$preexisting_home/.codex/AGENTS.md")" == "$agents_source" ]] || {
  printf 'install-ai.sh did not link Codex AGENTS.md when only CLAUDE.md pre-existed\n' >&2
  exit 1
}

if ! preexisting_verify="$("${preexisting_environment[@]}" \
  "$repo_root/common/verify-ai.sh" 2>&1)"; then
  printf '%s\n' "$preexisting_verify" >&2
  printf 'verify-ai.sh (pre-existing CLAUDE.md) failed\n' >&2
  exit 1
fi
assert_contains "$preexisting_verify" \
  "Claude Code (CLAUDE.md) ($preexisting_home/.claude/CLAUDE.md) is a plain file"
assert_contains "$preexisting_verify" \
  "Codex (AGENTS.md): $preexisting_home/.codex/AGENTS.md -> $agents_source"

# --- --validate forwards to verify-ai.sh ------------------------------------

"${test_environment[@]}" "$repo_root/common/install-ai.sh" --validate >/dev/null

# --- --dry-run changes nothing ----------------------------------------------

dry_home="$test_root/dry-home"
mkdir -p "$dry_home"
dry_run_output="$(
  env HOME="$dry_home" CODEX_HOME="$dry_home/.codex" \
    XDG_CONFIG_HOME="$dry_home/.config" \
    XDG_DATA_HOME="$dry_home/.local/share" PATH="$mock_bin:$PATH" \
    "$repo_root/common/install-ai.sh" --dry-run --codex --firstmate --gnhf --backpass
)"
assert_contains "$dry_run_output" 'Codex CLI:            true'
assert_contains "$dry_run_output" 'FirstMate crew stack: true'
assert_contains "$dry_run_output" 'GNHF (overnight run): true'
assert_contains "$dry_run_output" 'backpass:             true'
assert_contains "$dry_run_output" 'Install Treehouse'
assert_contains "$dry_run_output" 'Install No Mistakes'
assert_contains "$dry_run_output" 'backpass and acpx are now on PATH'
assert_contains "$dry_run_output" 'npm:gnhf'
assert_contains "$dry_run_output" 'npm:gh-axi, npm:chrome-devtools-axi, npm:tasks-axi, npm:quota-axi'
assert_contains "$dry_run_output" 'npm:backpass, npm:acpx'
assert_contains "$dry_run_output" 'Link the shared agent-instructions file'
assert_contains "$dry_run_output" "$dry_home/.claude/CLAUDE.md"
assert_contains "$dry_run_output" "$dry_home/.codex/AGENTS.md"
assert_contains "$dry_run_output" "$dry_home/.config/opencode/AGENTS.md"
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
