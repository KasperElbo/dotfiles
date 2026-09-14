#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"

mock_bin="$test_root/bin"
home="$test_root/home"
config="$home/.config"
data="$home/.local/share"
mise_data="$data/mise"
mise_shims="$mise_data/shims"
mise_installs="$mise_data/installs"
mkdir -p "$mise_shims" "$mise_installs" "$config" "$data"

# Stateful mise behavior stays local to this suite behind the shared exact-argv
# contract. This keeps the fixture realistic without allowing a new mise call
# to pass merely because the handler happens to understand its subcommand.
test_stub_init "$test_root"
test_stub_install "$test_root" mise
test_stub_allow "$test_root" mise --yes install
test_stub_allow "$test_root" mise --yes install npm:@anthropic-ai/claude-code
test_stub_allow "$test_root" mise exec -- claude --version
test_stub_allow "$test_root" mise exec -- npm config get ignore-scripts
test_stub_allow "$test_root" mise exec -- npm config get omit
test_stub_allow "$test_root" mise uninstall npm:@anthropic-ai/claude-code
for mise_tool in claude herdr codex gnhf gh-axi chrome-devtools-axi \
  lavish-axi tasks-axi quota-axi backpass acpx; do
  test_stub_allow "$test_root" mise which "$mise_tool"
done

cat >"$test_root/handlers/mise" <<'EOF'
#!/usr/bin/env bash
conf_file="$XDG_CONFIG_HOME/mise/conf.d/ai.toml"

reject() {
  printf 'strict mise fixture rejected unsupported argv:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  exit 96
}

make_shim() {
  install_bin="$MISE_INSTALLS_DIR/$1/latest/bin/$1"
  mkdir -p "$(dirname "$install_bin")"
  if [[ "$1" == claude ]]; then
    cat >"$install_bin" <<'SCRIPT'
#!/usr/bin/env bash
if [[ -n "${CLAUDE_NATIVE_BROKEN_FILE:-}" && -e "$CLAUDE_NATIVE_BROKEN_FILE" ]]; then
  printf 'Error: claude native binary not installed.\n' >&2
  exit 1
fi
printf '1.0.0 (Claude Code)\n'
SCRIPT
  else
    printf '#!/usr/bin/env bash\nexit 0\n' >"$install_bin"
  fi
  chmod +x "$install_bin"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$install_bin" >"$MISE_SHIMS_DIR/$1"
  chmod +x "$MISE_SHIMS_DIR/$1"
}

case "${1:-}" in
--yes)
  [[ "${2:-}" == install ]] || reject "$@"
  if [[ $# -ne 2 && ! ( $# -eq 3 && "${3:-}" == npm:@anthropic-ai/claude-code ) ]]; then
    reject "$@"
  fi
  if [[ "${3:-}" == npm:@anthropic-ai/claude-code &&
    "${CLAUDE_REPAIR_RESULT:-success}" == success ]]; then
    rm -f -- "${CLAUDE_NATIVE_BROKEN_FILE:-}"
  fi
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
  exit 0
  ;;
exec)
  [[ "${2:-}" == -- && $# -ge 3 ]] || reject "$@"
  shift 2
  case "$*" in
  'claude --version' | 'npm config get ignore-scripts' | 'npm config get omit')
    PATH="$MISE_SHIMS_DIR:$PATH" exec "$@"
    ;;
  *)
    reject exec -- "$@"
    ;;
  esac
  ;;
uninstall)
  [[ $# -eq 2 && "${2:-}" == npm:@anthropic-ai/claude-code ]] || reject "$@"
  printf 'claude-uninstall\n' >>"${MISE_OPERATION_LOG:-/dev/null}"
  rm -rf -- "$MISE_INSTALLS_DIR/claude" "$MISE_SHIMS_DIR/claude"
  exit 0
  ;;
which)
  [[ $# -eq 2 ]] || reject "$@"
  name="$2"
  case "$name" in
  claude | herdr | codex | gnhf | gh-axi | chrome-devtools-axi | lavish-axi | \
    tasks-axi | quota-axi | backpass | acpx) ;;
  *) reject "$@" ;;
  esac
  install_bin="$MISE_INSTALLS_DIR/$name/latest/bin/$name"
  if [[ -x "$install_bin" ]]; then
    printf '%s\n' "$install_bin"
    exit 0
  fi
  exit 1
  ;;
*)
  reject "$@"
  ;;
esac
EOF
chmod +x "$test_root/handlers/mise"

cat >"$mock_bin/npm" <<'EOF'
#!/usr/bin/env bash
if [[ $# -eq 3 && "$1" == config && "$2" == get ]]; then
  case "$3" in
  ignore-scripts) printf '%s\n' "${MOCK_NPM_IGNORE_SCRIPTS:-false}"; exit 0 ;;
  omit) printf '%s\n' "${MOCK_NPM_OMIT:-}"; exit 0 ;;
  esac
fi
printf 'strict npm fixture rejected unsupported argv: %s\n' "$*" >&2
exit 96
EOF
chmod +x "$mock_bin/npm"

# Model the PATH produced by the installed Zsh configuration independently of
# the stale shell PATH that launches the installer/verifier.
cat >"$mock_bin/zsh" <<'EOF'
#!/usr/bin/env bash
if [[ $# -eq 2 && "$1" == -lic && "$2" == 'printf "%s\\n" "$PATH"' ]]; then
  printf '%s\n' "$HOME/.local/bin:$MISE_SHIMS_DIR:$PATH"
  exit 0
fi
printf 'strict zsh fixture rejected unsupported argv: %s\n' "$*" >&2
exit 96
EOF
chmod +x "$mock_bin/zsh"

# These tools are prerequisites only; this scenario intentionally never invokes
# them. If production starts doing so, the fixture must explicitly model the
# new contract instead of silently succeeding.
for command_name in gh tmux jq; do
  cat >"$mock_bin/$command_name" <<'EOF'
#!/usr/bin/env bash
printf 'strict prerequisite fixture rejected unexpected invocation: %s %s\n' \
  "${0##*/}" "$*" >&2
exit 96
EOF
  chmod +x "$mock_bin/$command_name"
done

# Mocks Treehouse's and No Mistakes' real install scripts closely enough to
# exercise install-ai.sh without the network, while rejecting any curl shape
# other than the exact curl|sh contract used by install_via_own_script.
cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ $# -ne 5 || "$1" != --fail || "$2" != --show-error ||
  "$3" != --silent || "$4" != --location ]]; then
  printf 'strict curl fixture rejected unsupported argv: %s\n' "$*" >&2
  exit 96
fi
url="$5"
emit_installer() {
  printf '#!/usr/bin/env sh\n'
  printf 'mkdir -p "$HOME/.local/bin"\n'
  printf 'printf "#!/usr/bin/env sh\\nexit 0\\n" >"$HOME/.local/bin/%s"\n' "$1"
  printf 'chmod +x "$HOME/.local/bin/%s"\n' "$1"
}
case "$url" in
*treehouse*) emit_installer treehouse ;;
*no-mistakes*) emit_installer no-mistakes ;;
*)
  printf 'strict curl fixture rejected unexpected URL: %s\n' "$url" >&2
  exit 96
  ;;
esac
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
  # Deliberately omit ~/.local/bin and mise shims: this is the stale shell
  # inherited by a first installer run before the final Zsh config is loaded.
  "PATH=$mock_bin:$PATH"
  "MISE_DATA_DIR=$mise_data"
  "MISE_SHIMS_DIR=$mise_shims"
  "MISE_INSTALLS_DIR=$mise_installs"
  "FIRSTMATE_REPO_URL=$firstmate_origin"
)

# Prove the suite's stateful commands still fail closed at their shared/local
# contract boundaries.
run_capture env XDG_CONFIG_HOME="$config" MISE_DATA_DIR="$mise_data" \
  MISE_SHIMS_DIR="$mise_shims" MISE_INSTALLS_DIR="$mise_installs" \
  PATH="$mock_bin:$PATH" mise install unexpected
assert_status 96
run_capture env PATH="$mock_bin:$PATH" curl --silent https://example.invalid
assert_status 96
run_capture env PATH="$mock_bin:$PATH" gh auth status
assert_status 96

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
  _test_die 'install-ai.sh accepted --firstmate without jq'
  exit 1
fi
assert_contains "$missing_jq_output" 'Required command not found: jq'
assert_path_missing "$missing_jq_home/.config/mise/conf.d/ai.toml"
assert_path_missing "$missing_jq_home/.config/dotfiles/ai.conf"
assert_path_missing "$missing_jq_home/.claude/CLAUDE.md"

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

assert_path_exists "$conf_file"
assert_file_contains "$conf_file" \
  '"npm:@anthropic-ai/claude-code" = { version = "latest", npm_args = "--ignore-scripts=false --include=optional" }'
assert_file_contains "$conf_file" 'herdr = "latest"'
assert_file_not_contains "$conf_file" 'openai/codex'

assert_file_line "$state_file" 'profile=ai'
assert_file_line "$state_file" 'claude_code=mise-npm'
assert_file_line "$state_file" 'herdr=mise'
assert_file_line "$state_file" 'codex=disabled'
assert_file_line "$state_file" 'firstmate=disabled'
assert_file_line "$state_file" 'treehouse=disabled'
assert_file_line "$state_file" 'no_mistakes=disabled'
assert_file_line "$state_file" 'gh_axi=disabled'
assert_file_line "$state_file" 'chrome_devtools_axi=disabled'
assert_file_line "$state_file" 'lavish_axi=disabled'
assert_file_line "$state_file" 'tasks_axi=disabled'
assert_file_line "$state_file" 'quota_axi=disabled'
assert_file_line "$state_file" 'gnhf=disabled'
assert_file_line "$state_file" 'backpass=disabled'
assert_file_line "$state_file" 'acpx=disabled'

assert_path_missing "$treehouse_target"

for target in "$claude_md_target" "$codex_agents_target" "$opencode_agents_target"; do
  [[ -L "$target" ]] || {
    printf 'Expected a symlink at %s\n' "$target" >&2
    exit 1
  }
  assert_eq "$agents_source" "$(readlink "$target")" "$target symlink target"
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
assert_eq "$first_sum" "$second_sum" 'rerunning install-ai.sh (core) changed tracked state'

for target in "$claude_md_target" "$codex_agents_target" "$opencode_agents_target"; do
  assert_eq "$agents_source" "$(readlink "$target")" \
    "rerunning install-ai.sh changed $target"
done

# --- Codex + FirstMate + GNHF + backpass subcomponents ----------------------

if ! "${test_environment[@]}" "$repo_root/common/install-ai.sh" \
  --codex --firstmate --gnhf --backpass >"$test_root/install-full.log" 2>&1; then
  cat "$test_root/install-full.log" >&2
  printf 'install-ai.sh (--codex --firstmate --gnhf --backpass) failed\n' >&2
  exit 1
fi

assert_file_contains "$conf_file" '"npm:@openai/codex" = "latest"'
assert_file_contains "$conf_file" '"npm:gnhf" = "latest"'
for tool in gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi backpass acpx; do
  assert_file_contains "$conf_file" "\"npm:$tool\" = \"latest\""
done
# lavish-axi is wanted by both --firstmate and --backpass; it must appear
# exactly once in the generated TOML, not as a duplicate key.
assert_eq 1 "$(grep -Fc '"npm:lavish-axi"' "$conf_file")" \
  'lavish-axi declaration count'
assert_file_line "$state_file" 'codex=mise-npm'
assert_file_line "$state_file" 'firstmate=cloned'
assert_file_line "$state_file" 'treehouse=installed'
assert_file_line "$state_file" 'no_mistakes=installed'
assert_file_line "$state_file" 'gh_axi=mise-npm'
assert_file_line "$state_file" 'chrome_devtools_axi=mise-npm'
assert_file_line "$state_file" 'lavish_axi=mise-npm'
assert_file_line "$state_file" 'tasks_axi=mise-npm'
assert_file_line "$state_file" 'quota_axi=mise-npm'
assert_file_line "$state_file" 'gnhf=mise-npm'
assert_file_line "$state_file" 'backpass=mise-npm'
assert_file_line "$state_file" 'acpx=mise-npm'
assert_path_exists "$data/firstmate/.git"
assert_path_executable "$treehouse_target"
no_mistakes_target="$home/.local/bin/no-mistakes"
assert_path_executable "$no_mistakes_target"

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
  VERIFY_CONFIGURED_LOGIN_PATH="$shadow_bin:$home/.local/bin:$mise_shims:$mock_bin:$PATH" \
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

# --- Incomplete Claude native install: one bounded, narrow repair ----------

repair_home="$test_root/repair-home"
repair_data="$repair_home/.local/share"
repair_mise_data="$repair_data/mise"
repair_marker="$test_root/claude-native-broken"
repair_log="$test_root/repair-operations.log"
mkdir -p "$repair_home" "$repair_mise_data/shims" "$repair_mise_data/installs"
touch "$repair_marker"
repair_environment=(
  env
  "HOME=$repair_home"
  "CODEX_HOME=$repair_home/.codex"
  "XDG_CONFIG_HOME=$repair_home/.config"
  "XDG_DATA_HOME=$repair_data"
  "PATH=$mock_bin:$PATH"
  "MISE_DATA_DIR=$repair_mise_data"
  "MISE_SHIMS_DIR=$repair_mise_data/shims"
  "MISE_INSTALLS_DIR=$repair_mise_data/installs"
  "MISE_OPERATION_LOG=$repair_log"
  "CLAUDE_NATIVE_BROKEN_FILE=$repair_marker"
  "NPM_CONFIG_IGNORE_SCRIPTS=true"
  "NPM_CONFIG_OMIT=optional"
  "MOCK_NPM_IGNORE_SCRIPTS=true"
  "MOCK_NPM_OMIT=optional"
)

if ! repair_output="$("${repair_environment[@]}" \
  "$repo_root/common/install-ai.sh" 2>&1)"; then
  printf '%s\n' "$repair_output" >&2
  printf 'install-ai.sh did not repair incomplete Claude Code\n' >&2
  exit 1
fi
assert_contains "$repair_output" "platform-native binary is missing"
assert_contains "$repair_output" "ignore-scripts=true; omit=optional"
assert_contains "$repair_output" "NPM_CONFIG_IGNORE_SCRIPTS=true; NPM_CONFIG_OMIT=optional"
assert_contains "$repair_output" "Claude Code native installation repaired"
assert_eq 1 "$(grep -Fc claude-uninstall "$repair_log")" 'Claude repair uninstall count'
assert_path_missing "$repair_marker"

# Once healthy, an idempotent rerun must not uninstall Claude again.
"${repair_environment[@]}" "$repo_root/common/install-ai.sh" >/dev/null
assert_eq 1 "$(grep -Fc claude-uninstall "$repair_log")" \
  'healthy rerun must not uninstall Claude again'

# A failed repair is attempted once and then stops with the known recovery.
failed_home="$test_root/failed-repair-home"
failed_data="$failed_home/.local/share"
failed_mise_data="$failed_data/mise"
failed_marker="$test_root/claude-still-broken"
failed_log="$test_root/failed-repair-operations.log"
mkdir -p "$failed_home" "$failed_mise_data/shims" "$failed_mise_data/installs"
touch "$failed_marker"
if failed_repair_output="$(env \
  HOME="$failed_home" CODEX_HOME="$failed_home/.codex" \
  XDG_CONFIG_HOME="$failed_home/.config" XDG_DATA_HOME="$failed_data" \
  PATH="$mock_bin:$PATH" MISE_DATA_DIR="$failed_mise_data" \
  MISE_SHIMS_DIR="$failed_mise_data/shims" \
  MISE_INSTALLS_DIR="$failed_mise_data/installs" \
  MISE_OPERATION_LOG="$failed_log" CLAUDE_NATIVE_BROKEN_FILE="$failed_marker" \
  CLAUDE_REPAIR_RESULT=failure \
  "$repo_root/common/install-ai.sh" 2>&1)"; then
  printf 'install-ai.sh accepted Claude Code after a failed repair\n' >&2
  exit 1
fi
assert_contains "$failed_repair_output" "still broken after one repair attempt"
assert_contains "$failed_repair_output" "mise uninstall npm:@anthropic-ai/claude-code"
assert_contains "$failed_repair_output" "mise install"
assert_eq 1 "$(grep -Fc claude-uninstall "$failed_log")" 'failed Claude repair uninstall count'

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
assert_file_contains "$backpass_only_conf" '"npm:lavish-axi" = "latest"'
assert_file_contains "$backpass_only_conf" '"npm:backpass" = "latest"'
assert_file_not_contains "$backpass_only_conf" '"npm:gh-axi"'
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

assert_eq 'my own Claude instructions' "$(cat "$preexisting_home/.claude/CLAUDE.md")" \
  'pre-existing CLAUDE.md contents'
[[ ! -L "$preexisting_home/.claude/CLAUDE.md" ]] || {
  printf 'install-ai.sh replaced a pre-existing CLAUDE.md file with a symlink\n' >&2
  exit 1
}
assert_eq "$agents_source" "$(readlink "$preexisting_home/.codex/AGENTS.md")" \
  'Codex AGENTS.md target when CLAUDE.md pre-exists'

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
assert_file_contains "$test_root/combo.log" '--dry-run and --validate cannot be combined'

if "${test_environment[@]}" "$repo_root/common/install-ai.sh" --bogus \
  >"$test_root/unknown.log" 2>&1; then
  printf 'install-ai.sh accepted an unknown option\n' >&2
  exit 1
fi
assert_file_contains "$test_root/unknown.log" 'Unknown option: --bogus'

printf 'AI profile install/verify/idempotency tests passed.\n'
