#!/usr/bin/env bash
set -euo pipefail

# Deterministic mise context (issue #149).
#
# mise composes its configuration from the global config and from every
# mise.toml/.mise.toml between the working directory and the filesystem root.
# A dotfiles bootstrap started inside an unrelated project must not inherit
# that project's tools. These tests run the real installers from several
# working directories against a mise fixture that implements mise's documented
# discovery rules, and require the resolved tool set to be identical every
# time -- and never to contain the fixture project's sentinel tool.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"

home="$test_root/home"
config="$home/.config"
data="$home/.local/share"
state="$test_root/state"
mise_data="$data/mise"
mise_shims="$mise_data/shims"
mise_installs="$mise_data/installs"
mock_bin="$test_root/bin"
user_bin="$home/.local/bin"
resolved_log="$test_root/resolved-tools.log"
context_log="$test_root/mise-context.log"
sentinel="dotfiles-sentinel-tool"

mkdir -p "$mise_shims" "$mise_installs" "$config/mise/conf.d" "$data" \
  "$mock_bin" "$user_bin" "$state"

# The global manifest a bootstrap is supposed to install, and nothing else.
cat >"$config/mise/config.toml" <<'EOF'
[tools]
node = "22"
python = "3.13"
EOF

# A mise fixture that implements the documented discovery rules: the global
# config plus every mise.toml/.mise.toml from $PWD upwards, stopping at (and
# excluding) MISE_CEILING_PATHS. It logs both the working directory it was
# called from and the tool set it resolved, so a regression in either the
# neutral directory or the ceiling shows up as a changed tool set.
cat >"$user_bin/mise" <<'EOF'
#!/usr/bin/env bash
set -u

printf '%s\n' "$PWD" >>"${MISE_CONTEXT_LOG:-/dev/null}"

config_files() {
  local directory ceiling fragment
  ceiling="${MISE_CEILING_PATHS:-}"

  [[ ! -f "$XDG_CONFIG_HOME/mise/config.toml" ]] ||
    printf '%s\n' "$XDG_CONFIG_HOME/mise/config.toml"
  for fragment in "$XDG_CONFIG_HOME"/mise/conf.d/*.toml; do
    [[ ! -f "$fragment" ]] || printf '%s\n' "$fragment"
  done

  directory="$PWD"
  while :; do
    [[ -z "$ceiling" || "$directory" != "$ceiling" ]] || break
    for fragment in "$directory/mise.toml" "$directory/.mise.toml"; do
      [[ ! -f "$fragment" ]] || printf '%s\n' "$fragment"
    done
    [[ "$directory" != / ]] || break
    directory="$(dirname -- "$directory")"
  done
}

resolved_tools() {
  local file
  while IFS= read -r file; do
    awk '
      /^\[tools\]$/ { in_tools = 1; next }
      /^\[/ { in_tools = 0 }
      in_tools && /=/ {
        key = $0
        sub(/[[:space:]]*=.*/, "", key)
        sub(/^[[:space:]]*/, "", key)
        gsub(/"/, "", key)
        if (key != "") print key
      }
    ' "$file"
  done < <(config_files) | sort -u
}

make_shim() {
  local install_bin="$MISE_INSTALLS_DIR/$1/latest/bin/$1"
  mkdir -p "$(dirname -- "$install_bin")"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$install_bin"
  chmod +x "$install_bin"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$install_bin" >"$MISE_SHIMS_DIR/$1"
  chmod +x "$MISE_SHIMS_DIR/$1"
}

case "${1:-}" in
--yes)
  [[ "${2:-}" == install ]] || exit 96
  mkdir -p "$MISE_SHIMS_DIR"
  : >"${MISE_RESOLVED_LOG:-/dev/null}"
  while IFS= read -r tool; do
    printf '%s\n' "$tool" >>"${MISE_RESOLVED_LOG:-/dev/null}"
    # Scoped npm packages ship a command whose name is not the package name.
    case "$tool" in
    npm:@anthropic-ai/claude-code) make_shim claude ;;
    npm:@openai/codex) make_shim codex ;;
    npm:*) make_shim "${tool#npm:}" ;;
    *) make_shim "$tool" ;;
    esac
  done < <(resolved_tools)
  exit 0
  ;;
exec)
  [[ "${2:-}" == -- ]] || exit 96
  shift 2
  PATH="$MISE_SHIMS_DIR:$PATH" exec "$@"
  ;;
which)
  [[ $# -eq 2 ]] || exit 96
  install_bin="$MISE_INSTALLS_DIR/$2/latest/bin/$2"
  [[ -x "$install_bin" ]] || exit 1
  printf '%s\n' "$install_bin"
  ;;
uninstall) exit 0 ;;
*) exit 96 ;;
esac
EOF
chmod +x "$user_bin/mise"

cat >"$mock_bin/zsh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$HOME/.local/bin:$MISE_SHIMS_DIR:$PATH"
EOF
chmod +x "$mock_bin/zsh"

cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
output=""
url=""
while (($#)); do
  case "$1" in
  --output) output="${2:-}"; shift 2 ;;
  --) url="${2:-}"; shift "$#" ;;
  *) shift ;;
  esac
done
[[ -n "$output" && -n "$url" ]] || exit 96
case "$url" in
*treehouse*) name=treehouse ;;
*no-mistakes*) name=no-mistakes ;;
*) exit 96 ;;
esac
{
  printf '#!/usr/bin/env sh\n'
  printf 'mkdir -p "$HOME/.local/bin"\n'
  printf 'printf "#!/usr/bin/env sh\\nexit 0\\n" >"$HOME/.local/bin/%s"\n' "$name"
  printf 'chmod +x "$HOME/.local/bin/%s"\n' "$name"
} >"$output"
EOF
chmod +x "$mock_bin/curl"

for command_name in gh tmux jq; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$mock_bin/$command_name"
  chmod +x "$mock_bin/$command_name"
done

# The caller's project: a real directory tree carrying a conflicting
# .mise.toml, copied from the tracked fixture so the sentinel lives in one
# reviewable place.
caller_project="$test_root/unrelated-project"
cp -R "$repo_root/tests/fixtures/unrelated-project" "$caller_project"
assert_file_contains "$caller_project/.mise.toml" "$sentinel"
nested_project="$caller_project/nested/deeper"
mkdir -p "$nested_project"

run_from() {
  local directory="$1"
  shift
  (
    cd -- "$directory" || exit 1
    env \
      HOME="$home" CODEX_HOME="$home/.codex" \
      XDG_CONFIG_HOME="$config" XDG_DATA_HOME="$data" \
      XDG_STATE_HOME="$state" \
      PATH="$user_bin:$mock_bin:$PATH" \
      MISE_DATA_DIR="$mise_data" MISE_SHIMS_DIR="$mise_shims" \
      MISE_INSTALLS_DIR="$mise_installs" \
      MISE_RESOLVED_LOG="$resolved_log" MISE_CONTEXT_LOG="$context_log" \
      "$@"
  )
}

# --- The fixture itself must be able to see the sentinel -------------------
#
# Without this, a test that "proves" the sentinel is never installed could be
# passing because the fixture cannot resolve project config at all.

: >"$resolved_log"
(
  cd -- "$caller_project" || exit 1
  env XDG_CONFIG_HOME="$config" MISE_DATA_DIR="$mise_data" \
    MISE_SHIMS_DIR="$mise_shims" MISE_INSTALLS_DIR="$mise_installs" \
    MISE_RESOLVED_LOG="$resolved_log" \
    "$user_bin/mise" --yes install
)
assert_file_contains "$resolved_log" "$sentinel"
printf 'PASS: the fixture does resolve project-local config when nothing isolates it\n'

# --- Global bootstrap from four working directories -------------------------

expected_tools="node
python"

for label_and_directory in \
  "the caller's unrelated project:$caller_project" \
  "a nested unrelated project:$nested_project" \
  "\$HOME:$home" \
  "the dotfiles checkout:$repo_root"; do
  label="${label_and_directory%%:*}"
  directory="${label_and_directory#*:}"

  : >"$resolved_log"
  : >"$context_log"
  run_from "$directory" "$repo_root/common/install-mise.sh" >/dev/null

  assert_file_not_contains "$resolved_log" "$sentinel"
  assert_eq "$expected_tools" "$(sort -u "$resolved_log")" \
    "resolved global tool set differed when run from $label"
  assert_eq "$state/dotfiles/mise-context" "$(sort -u "$context_log")" \
    "mise was not invoked from the deterministic context when run from $label"
  printf 'PASS: global mise bootstrap from %s resolves only the global manifest\n' "$label"
done

# --- AI bootstrap from inside the caller's project --------------------------

: >"$resolved_log"
: >"$context_log"
run_from "$caller_project" "$repo_root/common/install-ai.sh" --codex \
  >"$test_root/install-ai.log" 2>&1 ||
  { cat "$test_root/install-ai.log" >&2; exit 1; }

assert_file_not_contains "$resolved_log" "$sentinel"
assert_file_contains "$resolved_log" 'npm:@anthropic-ai/claude-code'
assert_file_contains "$resolved_log" 'npm:@openai/codex'
assert_file_contains "$resolved_log" 'herdr'
assert_file_contains "$resolved_log" 'node'
assert_eq "$state/dotfiles/mise-context" "$(sort -u "$context_log")" \
  'the AI bootstrap invoked mise outside the deterministic context'
printf 'PASS: AI bootstrap from an unrelated project installs no sentinel tool\n'

# --- Verification uses the same context -------------------------------------

: >"$context_log"
run_from "$caller_project" "$repo_root/common/verify-ai.sh" >/dev/null 2>&1 || true
assert_eq "$state/dotfiles/mise-context" "$(sort -u "$context_log")" \
  'verification resolved mise outside the deterministic context'
printf 'PASS: AI verification resolves mise in the deterministic context\n'

# --- Dry-run output names the manifest being applied ------------------------

dry_run_output="$(run_from "$caller_project" \
  "$repo_root/common/install-ai.sh" --dry-run)"
assert_contains "$dry_run_output" "global: $config/mise/config.toml"
assert_contains "$dry_run_output" "fragments: $config/mise/conf.d/*.toml"
assert_contains "$dry_run_output" 'directory config: none'
assert_contains "$dry_run_output" "$state/dotfiles/mise-context"
printf 'PASS: dry-run states which logical mise config is applied\n'

# --- The context directory stays empty of tool declarations ----------------

context_dir="$state/dotfiles/mise-context"
printf '[tools]\nstray = "1"\n' >"$context_dir/mise.toml"
: >"$resolved_log"
run_from "$caller_project" "$repo_root/common/install-mise.sh" >/dev/null
assert_path_missing "$context_dir/mise.toml"
assert_file_not_contains "$resolved_log" 'stray'
assert_file_not_contains "$resolved_log" "$sentinel"
assert_file_contains "$resolved_log" 'node'
printf 'PASS: a stray config in the context directory is removed, not honoured\n'

printf 'Deterministic mise context tests passed.\n'
