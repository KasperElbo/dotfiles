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

# A refusal names what it refused. The bare `exit 96` this replaced was
# indistinguishable from any other failure, so a mise call added to the
# installer failed the suite without saying which call it was.
reject() {
  printf 'strict mise fixture rejected unsupported argv:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  exit 96
}

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
  [[ "${2:-}" == install && $# -eq 2 ]] || reject "$@"
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
  [[ "${2:-}" == -- && $# -ge 3 ]] || reject "$@"
  shift 2
  PATH="$MISE_SHIMS_DIR:$PATH" exec "$@"
  ;;
ls)
  # mise ls <spec> --json, the resolved-version lookup. This stub answers
  # from the shims it made, so it reports a version exactly for what it
  # installed.
  [[ $# -eq 3 && "$3" == --json ]] || reject "$@"
  name="${2#npm:}"
  name="${name##*/}"
  case "$name" in
  claude-code) name=claude ;;
  esac
  if [[ -x "$MISE_SHIMS_DIR/$name" ]]; then
    printf '[{"version":"1.2.3","requested_version":"latest",'
    printf '"install_path":"%s/%s/latest",' "$MISE_INSTALLS_DIR" "$name"
    printf '"installed":true,"active":true}]\n'
  else
    printf '[]\n'
  fi
  exit 0
  ;;
which)
  [[ $# -eq 2 ]] || reject "$@"
  install_bin="$MISE_INSTALLS_DIR/$2/latest/bin/$2"
  [[ -x "$install_bin" ]] || exit 1
  printf '%s\n' "$install_bin"
  ;;
uninstall)
  [[ $# -eq 2 ]] || reject "$@"
  exit 0
  ;;
*) reject "$@" ;;
esac
EOF
chmod +x "$user_bin/mise"

cat >"$mock_bin/zsh" <<'EOF'
#!/usr/bin/env bash
# The verifier asks both logins for their PATH through a marker. .zshenv is
# read by both; the zsh package's .zprofile puts mise's shims behind
# ~/.local/bin in every login, so a login that is not interactive carries them
# only when this home has that file.
login_shims=""
[[ ! -e "${XDG_CONFIG_HOME:-$HOME/.config}/zsh/.zprofile" ]] ||
  login_shims="$MISE_SHIMS_DIR:"
case "${1:-}" in
-lc) printf 'login-path:%s\n' "$HOME/.local/bin:$login_shims/usr/bin:/bin" ;;
*) printf 'login-path:%s\n' "$HOME/.local/bin:$MISE_SHIMS_DIR:$PATH" ;;
esac
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

for command_name in gh tmux; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$mock_bin/$command_name"
  chmod +x "$mock_bin/$command_name"
done

# jq is the real one: the installer reads and rewrites Claude Code's settings
# file with it, and a stub that exits 0 without output would let every JSON
# assertion pass while writing nothing.
ln -sf "$(command -v jq)" "$mock_bin/jq"

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

# --- Verification never writes to the context (issue #345) ------------------
#
# docs/workflows/verification.md promises that nothing in the verification path
# changes the machine. The context is repository-owned, which bounds the damage
# but does not make it correct: a verifier that rebuilt the context would erase
# exactly the contamination worth reporting and then pass. Preparation is now
# install-time only, and these cases hold verification to the promise by
# snapshotting the context tree around a real verifier run.

context_dir="$state/dotfiles/mise-context"

# One line per entry, path and content digest, plus the directory's own
# existence on the first line, so a created, deleted, renamed or rewritten file
# all change the snapshot.
snapshot_context() {
  local entry

  if [[ ! -d "$context_dir" ]]; then
    printf 'absent\n'
    return 0
  fi

  printf 'present\n'
  while IFS= read -r -d '' entry; do
    printf '%s\t%s\n' "${entry#"$context_dir/"}" \
      "$(sha256sum <"$entry" | cut -d ' ' -f 1)"
  done < <(find "$context_dir" -mindepth 1 \( -type f -o -type l \) -print0 |
    sort -z)
}

prepare_context_as_installer() {
  run_from "$home" bash -c '
    # shellcheck source=/dev/null
    source "$1/common/lib/common.sh"
    mise_prepare_context >/dev/null
  ' _ "$repo_root"
}

# The negative control for every "unchanged" assertion below. A snapshot that
# cannot see the mutation it forbids would pass all of them while the verifier
# quietly rebuilt the context, so the mutation is performed deliberately once
# and the snapshot is required to notice.
rm -rf "$context_dir"
mkdir -p "$context_dir"
printf '[tools]\ncontrol = "1"\n' >"$context_dir/mise.toml"
control_before="$(snapshot_context)"
assert_contains "$control_before" 'mise.toml'
prepare_context_as_installer
control_after="$(snapshot_context)"
[[ "$control_before" != "$control_after" ]] ||
  _test_die 'the context snapshot cannot see install-time preparation, so it proves nothing about verification'
assert_not_contains "$control_after" 'mise.toml'
printf 'PASS: the snapshot detects the context mutation the verification cases forbid\n'

# Each filename install-time preparation removes, one case each: the verifier
# must report it and leave it exactly where it was.
for stray in mise.toml .mise.toml mise.local.toml .mise.local.toml; do
  rm -rf "$context_dir"
  mkdir -p "$context_dir"
  printf '[tools]\nstray-in-%s = "1"\n' "$stray" >"$context_dir/$stray"
  stray_digest="$(sha256sum <"$context_dir/$stray" | cut -d ' ' -f 1)"
  context_before="$(snapshot_context)"

  verify_output="$(run_from "$caller_project" \
    "$repo_root/common/verify-ai.sh" 2>&1 || true)"

  context_after="$(snapshot_context)"
  assert_eq "$context_before" "$context_after" \
    "verification changed a mise context contaminated with $stray"
  assert_path_exists "$context_dir/$stray"
  assert_eq "$stray_digest" "$(sha256sum <"$context_dir/$stray" | cut -d ' ' -f 1)" \
    "verification rewrote $stray in the mise context"
  assert_contains "$verify_output" 'mise resolution is not deterministic'
  assert_contains "$verify_output" "$stray"
  printf 'PASS: verification reports a context contaminated with %s and leaves it in place\n' "$stray"
done

# A missing context is the installer's business, not the verifier's.
rm -rf "$context_dir"
context_before="$(snapshot_context)"
assert_eq 'absent' "$context_before" 'the missing-context case did not start from a missing context'
verify_output="$(run_from "$caller_project" \
  "$repo_root/common/verify-ai.sh" 2>&1 || true)"
assert_eq "$context_before" "$(snapshot_context)" \
  'verification created the missing mise context'
assert_path_missing "$context_dir"
assert_contains "$verify_output" 'mise resolution is not deterministic'
assert_contains "$verify_output" 'does not exist'
printf 'PASS: verification reports a missing context instead of creating one\n'

# A clean context passes, and unrelated files in it are neither read as
# configuration nor disturbed.
prepare_context_as_installer
printf 'not a tool declaration\n' >"$context_dir/notes.txt"
context_before="$(snapshot_context)"
verify_output="$(run_from "$caller_project" \
  "$repo_root/common/verify-ai.sh" 2>&1 || true)"
assert_eq "$context_before" "$(snapshot_context)" \
  'verification changed a clean mise context'
assert_contains "$verify_output" 'The deterministic mise context is present and declares no tools'
assert_not_contains "$verify_output" 'mise resolution is not deterministic'
printf 'PASS: verification leaves a clean context untouched and says so\n'

# run_mise itself is the shared gate, so it refuses instead of repairing
# however it is reached.
rm -rf "$context_dir"
mkdir -p "$context_dir"
printf '[tools]\nstray = "1"\n' >"$context_dir/mise.toml"
run_mise_output="$(run_from "$home" bash -c '
  # shellcheck source=/dev/null
  source "$1/common/lib/common.sh"
  run_mise "$1/tests/fixtures/does-not-exist" --version
' _ "$repo_root" 2>&1 || true)"
assert_contains "$run_mise_output" 'Refusing to run mise'
assert_path_exists "$context_dir/mise.toml"
printf 'PASS: run_mise refuses a contaminated context rather than repairing it\n'

# Every verifier that can reach run_mise must ask about the context first,
# directly or through the shared checks that call it.
verifiers_reaching_mise=()
while IFS= read -r -d '' verifier; do
  body="$(cat "$verifier")"
  case "$body" in
  *run_mise*| *check_mise_owned*| *check_no_global_npm_duplicate*) ;;
  *) continue ;;
  esac
  verifiers_reaching_mise+=("$verifier")
  # The entry points a person runs, not common/lib/verify.sh, which defines
  # the check and would otherwise satisfy this loop by existing.
done < <(find "$repo_root/common" "$repo_root/platforms" -type f -name 'verify*.sh' \
  -not -path "$repo_root/common/lib/*" -print0 | sort -z)

((${#verifiers_reaching_mise[@]} > 0)) ||
  _test_die 'no verifier was found to reach mise, so this coverage check proves nothing'

for verifier in "${verifiers_reaching_mise[@]}"; do
  body="$(cat "$verifier")"
  case "$body" in
  *check_mise_context*) ;;
  *)
    _test_die "verifier reaches mise without checking the deterministic context: ${verifier#"$repo_root/"}"
    ;;
  esac
done
printf 'PASS: all %d verifiers that reach mise check the deterministic context (%s)\n' \
  "${#verifiers_reaching_mise[@]}" \
  "$(printf '%s ' "${verifiers_reaching_mise[@]#"$repo_root/"}" | sed 's/ $//')"

printf 'Read-only verification of the mise context passed.\n'
