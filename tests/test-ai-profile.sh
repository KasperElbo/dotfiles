#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_isolate_path git jq sha256sum
test_new_root
test_root="$TEST_ROOT"

# A component that failed may have written no profile file at all, which is
# the stronger outcome rather than a reason to skip the check. Naming it here
# is what lets assert_file_not_contains stay strict everywhere else, where a
# missing file means the assertion stopped checking anything.
assert_not_recorded() {
  local conf="$1"
  local entry="$2"
  [[ ! -e "$conf" ]] || assert_file_not_contains "$conf" "$entry"
}

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
# The verifier's duplicate-package probe of the mise-managed Node prefix.
test_stub_allow "$test_root" mise exec -- npm ls --global --depth=0 --parseable
test_stub_allow "$test_root" mise exec -- npm prefix --global
test_stub_allow "$test_root" mise uninstall npm:@anthropic-ai/claude-code
for mise_tool in claude herdr codex gnhf gh-axi chrome-devtools-axi \
  lavish-axi tasks-axi quota-axi backpass acpx; do
  test_stub_allow "$test_root" mise which "$mise_tool"
done
# The resolved-version lookup, asked per declared spec.
for mise_spec in npm:@anthropic-ai/claude-code herdr npm:@openai/codex \
  npm:gnhf npm:gh-axi npm:chrome-devtools-axi npm:lavish-axi npm:tasks-axi \
  npm:quota-axi npm:backpass npm:acpx; do
  test_stub_allow "$test_root" mise ls "$mise_spec" --json
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
  'claude --version' | 'npm config get ignore-scripts' | 'npm config get omit' | \
    'npm ls --global --depth=0 --parseable' | 'npm prefix --global')
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
ls)
  # mise ls <spec> --json: an array of version entries, empty when the tool
  # was never installed. A shim is what an install here produces.
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
# The global prefix, with the same knobs as test_stub_npm_global in
# tests/lib/test.sh. A run that names no prefix has none modelled, so the
# listing is refused like any other unmodelled call rather than invented.
if [[ -n "${TEST_NPM_GLOBAL_PREFIX:-}" ]]; then
  case "$*" in
  'ls --global --depth=0 --parseable')
    printf '%s/lib\n' "$TEST_NPM_GLOBAL_PREFIX"
    for package in ${TEST_NPM_GLOBAL_PACKAGES:-}; do
      printf '%s/lib/node_modules/%s\n' "$TEST_NPM_GLOBAL_PREFIX" "$package"
    done
    exit 0
    ;;
  'prefix --global')
    printf '%s\n' "$TEST_NPM_GLOBAL_PREFIX"
    exit 0
    ;;
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
# Both logins the tracked Zsh package produces, answered through the
# verifier's own marker. .zshenv is read by every top-level Zsh and puts
# ~/.local/bin first; mise is activated in .zshrc, so only the INTERACTIVE
# login carries the shims. A fixture that answered both the same way would
# model away the defect the second probe exists to catch.
if [[ $# -eq 2 && "$2" == 'printf "login-path:%s\n" "$PATH"' ]]; then
  case "$1" in
  -lic)
    printf 'login-path:%s\n' "$MISE_SHIMS_DIR:$HOME/.local/bin:$PATH"
    exit 0
    ;;
  -lc)
    printf 'login-path:%s\n' "$HOME/.local/bin:/usr/bin:/bin"
    exit 0
    ;;
  esac
fi
# check_login_environment's probe, answered from the ~/.zshenv this home
# actually has, which is what a fresh login reads. .zshenv is Zsh and this is
# Bash, so only its plain `export NAME=value` lines are read; the variable the
# probe asks about is one of them. A home with no .zshenv is one this suite
# never deployed the zsh package into, so there is no login to model there and
# the probe is refused like any other unmodelled call: answering "<unset>"
# would fail every case that is about something else.
if [[ $# -eq 2 && "$1" == -lc &&
  "$2" == "printf 'login-env:%s\n' \"\${"*"-<unset>}\"" &&
  -r "$HOME/.zshenv" ]]; then
  name="${2#*\$\{}"
  name="${name%%-<unset>*}"
  if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    assignment="$(grep -E "^export $name=" "$HOME/.zshenv" | tail -n 1)"
    if [[ -n "$assignment" ]]; then
      printf 'login-env:%s\n' "${assignment#*=}"
    else
      printf 'login-env:<unset>\n'
    fi
    exit 0
  fi
fi
printf 'strict zsh fixture rejected unsupported argv: %s\n' "$*" >&2
exit 96
EOF
chmod +x "$mock_bin/zsh"

# These tools are prerequisites only; this scenario intentionally never invokes
# them. If production starts doing so, the fixture must explicitly model the
# new contract instead of silently succeeding.
#
# jq is deliberately not among them any more: the installer reads and rewrites
# Claude Code's settings file with it, so the suite uses the host's real jq
# (linked onto the isolated PATH above) and asserts the resulting JSON.
for command_name in gh tmux; do
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
# other than the exact bounded-transfer contract in common/lib/fetch.sh. The
# staged installer is written to the --output path, never piped, so a test that
# passes proves the download-then-execute path and not a curl|sh pipeline.
#
# Behaviour knobs, so the same fixture can model every failure the staged
# installer has to reject:
#   MOCK_CURL_FAIL_URL      substring; curl exits non-zero for a matching URL
#   MOCK_CURL_EMPTY_URL     substring; curl exits 0 having written nothing
#   MOCK_CURL_GARBAGE_URL   substring; curl writes an HTML error page
#   MOCK_CURL_MUTATE_URL    substring; the staged script installs the wrong tool
cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
reject() {
  printf 'strict curl fixture rejected unsupported argv: %s\n' "$*" >&2
  exit 96
}

expected=(--fail --show-error --silent --location --proto '=https' --tlsv1.2)
(($# >= ${#expected[@]})) || reject "$@"
for index in "${!expected[@]}"; do
  [[ "${@:index+1:1}" == "${expected[index]}" ]] || reject "$@"
done
shift "${#expected[@]}"

output=""
url=""
while (($#)); do
  case "$1" in
  --connect-timeout | --max-time)
    [[ "${2:-}" =~ ^[0-9]+$ ]] || reject "$@"
    shift 2
    ;;
  --output)
    output="${2:-}"
    shift 2
    ;;
  --)
    url="${2:-}"
    shift "$#"
    ;;
  *) reject "$@" ;;
  esac
done
[[ -n "$output" && -n "$url" ]] || reject "$output" "$url"

# The staged file must already exist, mode 0600, before any byte is written.
[[ -f "$output" ]] || {
  printf 'strict curl fixture: destination was not pre-created: %s\n' "$output" >&2
  exit 95
}
if [[ "$(stat -c '%a' "$output" 2>/dev/null || stat -f '%Lp' "$output")" != 600 ]]; then
  printf 'strict curl fixture: destination is not mode 0600: %s\n' "$output" >&2
  exit 95
fi

if [[ -n "${MOCK_CURL_FAIL_URL:-}" && "$url" == *"$MOCK_CURL_FAIL_URL"* ]]; then
  printf 'curl: (22) simulated transport failure\n' >&2
  exit 22
fi
if [[ -n "${MOCK_CURL_EMPTY_URL:-}" && "$url" == *"$MOCK_CURL_EMPTY_URL"* ]]; then
  exit 0
fi
if [[ -n "${MOCK_CURL_GARBAGE_URL:-}" && "$url" == *"$MOCK_CURL_GARBAGE_URL"* ]]; then
  printf '<html><body>503 Service Unavailable</body></html>\n' >"$output"
  exit 0
fi

# What an upstream installer is handed. Recorded by the fixture because the
# staging directory it lives in is deleted the moment the script returns, so
# afterwards there is nothing left to inspect.
emit_environment_report() {
  printf 'report="$HOME/staged-%s-report"\n' "$1"
  printf ': >"$report"\n'
  printf 'printf "curl_home=%%s\\n" "${CURL_HOME:-unset}" >>"$report"\n'
  printf 'if [ -f "${CURL_HOME:-/nonexistent}/netrc" ]; then\n'
  # GNU first, then BSD, as elsewhere in this repository: GNU "stat -f" is
  # filesystem status and succeeds, so a BSD-first probe never falls back.
  printf '  printf "netrc_mode=%%s\\n" \\\n'
  printf '    "$(stat -c %%a "$CURL_HOME/netrc" 2>/dev/null || stat -f %%Lp "$CURL_HOME/netrc")" >>"$report"\n'
  # A verdict, never the value: the fixture compares against what the suite
  # says it passed, so no secret-shaped string reaches a file or the log.
  printf '  printf "netrc_hosts=%%s\\n" \\\n'
  printf '    "$(awk "/^machine /{ printf \\"%%s \\", \\$2 }" "$CURL_HOME/netrc")" >>"$report"\n'
  printf '  printf "netrc_lines=%%s\\n" "$(grep -c . "$CURL_HOME/netrc")" >>"$report"\n'
  printf '  if grep -Fq -- "$MOCK_EXPECTED_SECRET" "$CURL_HOME/netrc"; then\n'
  printf '    printf "netrc_value=as-passed\\n" >>"$report"\n'
  printf '  else\n'
  printf '    printf "netrc_value=mismatch\\n" >>"$report"\n'
  printf '  fi\n'
  printf '  if [ -f "$CURL_HOME/.curlrc" ]; then printf "curlrc=present\\n" >>"$report"; fi\n'
  printf 'else\n'
  printf '  printf "netrc=absent\\n" >>"$report"\n'
  printf 'fi\n'
}

emit_installer() {
  {
    printf '#!/usr/bin/env sh\n'
    emit_environment_report "$1"
    printf 'mkdir -p "$HOME/.local/bin"\n'
    printf 'printf "#!/usr/bin/env sh\\nexit 0\\n" >"$HOME/.local/bin/%s"\n' "$1"
    printf 'chmod +x "$HOME/.local/bin/%s"\n' "$1"
  } >"$output"
}

# The layout No Mistakes actually uses on darwin/arm64: the binary goes into
# the upstream's own directory and a launcher symlink is left on PATH. Nothing
# about that is macOS-specific -- any upstream may choose it -- so the fixture
# can emit it for either component.
emit_launcher_installer() {
  {
    printf '#!/usr/bin/env sh\n'
    printf 'mkdir -p "$HOME/.%s/bin" "$HOME/.local/bin"\n' "$1"
    printf 'printf "#!/usr/bin/env sh\\nexit 0\\n" >"$HOME/.%s/bin/%s"\n' "$1" "$1"
    printf 'chmod +x "$HOME/.%s/bin/%s"\n' "$1" "$1"
    printf 'ln -sf "$HOME/.%s/bin/%s" "$HOME/.local/bin/%s"\n' "$1" "$1" "$1"
  } >"$output"
}

# The same layout, with the binary missing: a launcher that points at nothing
# is an install that did not happen, however convincing the PATH entry looks.
emit_dangling_launcher_installer() {
  {
    printf '#!/usr/bin/env sh\n'
    printf 'mkdir -p "$HOME/.local/bin"\n'
    printf 'ln -sf "$HOME/.%s/bin/%s" "$HOME/.local/bin/%s"\n' "$1" "$1" "$1"
  } >"$output"
}

case "$url" in
*treehouse*)
  if [[ -n "${MOCK_CURL_MUTATE_URL:-}" && "$url" == *"$MOCK_CURL_MUTATE_URL"* ]]; then
    emit_installer something-else
  else
    emit_installer treehouse
  fi
  ;;
*no-mistakes*)
  case "${MOCK_NO_MISTAKES_LAYOUT:-direct}" in
  launcher) emit_launcher_installer no-mistakes ;;
  dangling-launcher) emit_dangling_launcher_installer no-mistakes ;;
  *) emit_installer no-mistakes ;;
  esac
  ;;
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
  # A Node prefix carries npm itself, so the healthy listing is not empty and
  # the duplicate probe is seen to pass over a package it must not flag.
  "TEST_NPM_GLOBAL_PREFIX=$test_root/node-prefix"
  "TEST_NPM_GLOBAL_PACKAGES=npm"
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

# Prerequisites are checked before the installer writes any profile state or
# asks mise to install tools. Platform installers normally provide these
# commands, but the portable entry point must also fail atomically when called
# on its own in an incomplete environment. jq is a core prerequisite now, not a
# FirstMate-only one: without it the profile cannot declare the update block in
# Claude Code's settings file, and an install that silently skipped that would
# leave the tool free to reinstall itself outside mise.
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
assert_path_missing "$missing_jq_home/.claude/settings.json"

# The same refusal without --firstmate: jq is needed by the core profile.
rm -rf "${missing_jq_home:?}"/.config "${missing_jq_home:?}"/.claude
if missing_jq_output="$(env \
  HOME="$missing_jq_home" CODEX_HOME="$missing_jq_home/.codex" \
  XDG_CONFIG_HOME="$missing_jq_home/.config" \
  XDG_DATA_HOME="$missing_jq_home/.local/share" \
  PATH="$missing_jq_bin" MISE_DATA_DIR="$mise_data" \
  MISE_SHIMS_DIR="$mise_shims" MISE_INSTALLS_DIR="$mise_installs" \
  "$repo_root/common/install-ai.sh" 2>&1)"; then
  _test_die 'install-ai.sh accepted a core install without jq'
  exit 1
fi
assert_contains "$missing_jq_output" 'Required command not found: jq'
assert_path_missing "$missing_jq_home/.config/mise/conf.d/ai.toml"
printf 'PASS: install-ai.sh refuses to run without jq\n'

treehouse_source_url="https://kunchenguid.github.io/treehouse/install.sh"
no_mistakes_source_url="https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh"
conf_file="$config/mise/conf.d/ai.toml"
state_file="$config/dotfiles/ai.conf"
treehouse_target="$home/.local/bin/treehouse"
agents_source="$repo_root/common/assets/AGENTS.md"
claude_md_target="$home/.claude/CLAUDE.md"
claude_settings_target="$home/.claude/settings.json"
codex_agents_target="$home/.codex/AGENTS.md"
opencode_agents_target="$config/opencode/AGENTS.md"

# assert_claude_update_keys <settings-file>: both keys the profile declares are
# present with the value Claude Code's own gate accepts. Read with jq rather
# than grepped, so a key that landed as a nested string or a number fails here.
assert_claude_update_keys() {
  local file="$1" key
  assert_path_exists "$file"
  for key in DISABLE_UPDATES DISABLE_AUTOUPDATER; do
    assert_eq '1' "$(jq -r --arg key "$key" '.env[$key] // "<unset>"' "$file")" \
      "$key in $file"
  done
}

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

# The block that keeps Claude Code's updater out of the mise-managed Node
# prefix. It has to be in the tool's own settings file, because that is the one
# place read by a launch this repository did not start.
assert_claude_update_keys "$claude_settings_target"
printf 'PASS: the core install declares the update block in %s\n' \
  "$claude_settings_target"

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
assert_contains "$verify_core_output" \
  "DISABLE_UPDATES=1 in $claude_settings_target"
assert_contains "$verify_core_output" \
  "DISABLE_AUTOUPDATER=1 in $claude_settings_target"

# --- Claude Code's settings file is merged, never overwritten --------------
#
# Claude Code writes this file itself and so does the user, so every other key
# has to survive, the merge has to be idempotent, and a file this repository
# cannot parse has to be reported rather than guessed at.

settings_before="$(cat "$claude_settings_target")"
jq '.model = "opus" | .env.MY_OWN = "kept" | .permissions = {"allow": ["Bash"]}' \
  <<<"$settings_before" >"$claude_settings_target"
"${test_environment[@]}" "$repo_root/common/install-ai.sh" >/dev/null
assert_claude_update_keys "$claude_settings_target"
assert_eq 'opus' "$(jq -r '.model' "$claude_settings_target")" \
  'an unrelated top-level key must survive the merge'
assert_eq 'kept' "$(jq -r '.env.MY_OWN' "$claude_settings_target")" \
  'an unrelated env key must survive the merge'
assert_eq 'Bash' "$(jq -r '.permissions.allow[0]' "$claude_settings_target")" \
  'a nested structure must survive the merge'
printf 'PASS: the merge preserves keys this repository did not write\n'

settings_merged="$(cat "$claude_settings_target")"
"${test_environment[@]}" "$repo_root/common/install-ai.sh" >/dev/null
assert_eq "$settings_merged" "$(cat "$claude_settings_target")" \
  'rerunning install-ai.sh rewrote a settings file that was already correct'
printf 'PASS: an already-declared settings file is left byte-identical\n'

# A settings file this repository cannot parse is left alone and reported, and
# the install does not claim success: the block it exists to establish is not
# there, and a green install would hide exactly the state that lets Claude Code
# reinstall itself outside mise.
printf 'not json {\n' >"$claude_settings_target"
unparseable_log="$test_root/install-unparseable-settings.log"
if "${test_environment[@]}" "$repo_root/common/install-ai.sh" \
  >"$unparseable_log" 2>&1; then
  cat "$unparseable_log" >&2
  printf 'install-ai.sh reported success with an unparseable settings file\n' >&2
  exit 1
fi
assert_eq 'not json {' "$(cat "$claude_settings_target")" \
  'an unparseable settings file must be left exactly as it was'
assert_file_contains "$unparseable_log" 'it is not valid JSON'
assert_file_contains "$unparseable_log" 'is not valid JSON, so Claude Code reads no settings from it'
printf 'PASS: an unparseable settings file is reported, never rewritten\n'

printf '{"env": "not-an-object"}\n' >"$claude_settings_target"
env_not_object_log="$test_root/install-env-not-object.log"
if "${test_environment[@]}" "$repo_root/common/install-ai.sh" \
  >"$env_not_object_log" 2>&1; then
  cat "$env_not_object_log" >&2
  printf 'install-ai.sh reported success with an unusable env key\n' >&2
  exit 1
fi
assert_eq '{"env": "not-an-object"}' "$(cat "$claude_settings_target")" \
  'a settings file whose env is not an object must be left as it was'
assert_file_contains "$env_not_object_log" 'is not an object'
printf 'PASS: an env key of the wrong shape is reported, never rewritten\n'

printf '%s\n' "$settings_merged" >"$claude_settings_target"
"${test_environment[@]}" "$repo_root/common/install-ai.sh" >/dev/null
assert_claude_update_keys "$claude_settings_target"

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

# The zsh package as Stow deploys it, so the login-environment probe below is
# answered from the repository's own .zshenv rather than from the fixture.
ln -s "$repo_root/zsh/.zshenv" "$home/.zshenv"

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
assert_contains "$verify_full_output" 'DISABLE_UPDATES=1 in a fresh Zsh login'
assert_contains "$verify_full_output" \
  'No AI package is duplicated in the active Node prefix'

# --- The same full profile, with everything the verifier owns broken ---------
#
# Each ownership check above has to be seen failing as well, or an inverted
# predicate would still read green. One run breaks all of them at once, because
# every case here is a whole verifier run, and asserts the exact set of
# failures so each one is the check failing for the reason given here:
#
# - ~/.zshenv is a copy from before it exported DISABLE_UPDATES, rather than
#   the Stow link that a restow would have refreshed;
# - Claude Code has a second, unpinned copy in the mise-managed Node prefix,
#   which is what its own updater writes when nothing stops it;
# - mise has no installed version behind the optional tools' shims -- a prune,
#   or an install that failed after reshimming -- so every name still resolves
#   on PATH and only asking mise tells a tool from a dangling shim;
# - Treehouse is gone from its command path;
# - a mise shim named no-mistakes, which PATH puts ahead of ~/.local/bin, runs
#   instead of the copy the installer recorded.
#
# Claude Code, Herdr and Codex keep their installs, so the mise failures are
# exactly the tools this section is about.
broken_installs="$test_root/broken-mise-installs"
mkdir -p "$broken_installs"
for tool in claude herdr codex; do
  cp -R "$mise_installs/$tool" "$broken_installs/$tool"
done
assert_file_line "$repo_root/zsh/.zshenv" 'export DISABLE_UPDATES=1'
rm -- "$home/.zshenv"
grep -v '^export DISABLE_UPDATES=' "$repo_root/zsh/.zshenv" >"$home/.zshenv"
mv -- "$treehouse_target" "$test_root/treehouse.moved"
cat >"$mise_shims/no-mistakes" <<'EOF'
#!/usr/bin/env bash
printf 'duplicate no-mistakes fixture must never run: %s\n' "$*" >&2
exit 96
EOF
chmod +x "$mise_shims/no-mistakes"

if broken_full_output="$("${test_environment[@]}" \
  "MISE_INSTALLS_DIR=$broken_installs" \
  "TEST_NPM_GLOBAL_PACKAGES=npm @anthropic-ai/claude-code" \
  "$repo_root/common/verify-ai.sh" 2>&1)"; then
  printf '%s\n' "$broken_full_output" >&2
  printf 'verify-ai.sh passed a full profile whose ownership is broken\n' >&2
  exit 1
fi
assert_verifier_failures "$broken_full_output" \
  'DISABLE_UPDATES is unset in a fresh Zsh login' \
  "@anthropic-ai/claude-code is also installed globally with npm under $test_root/node-prefix" \
  'gnhf is not backed by an executable reported by mise: <none>' \
  'gh-axi is not backed by an executable reported by mise: <none>' \
  'chrome-devtools-axi is not backed by an executable reported by mise: <none>' \
  'tasks-axi is not backed by an executable reported by mise: <none>' \
  'quota-axi is not backed by an executable reported by mise: <none>' \
  'lavish-axi is not backed by an executable reported by mise: <none>' \
  'backpass is not backed by an executable reported by mise: <none>' \
  'acpx is not backed by an executable reported by mise: <none>' \
  "treehouse is missing or not executable: $treehouse_target" \
  "no-mistakes on PATH ($mise_shims/no-mistakes) is not $no_mistakes_target"

rm -- "$mise_shims/no-mistakes" "$home/.zshenv"
rm -rf -- "$broken_installs"
mv -- "$test_root/treehouse.moved" "$treehouse_target"
ln -s "$repo_root/zsh/.zshenv" "$home/.zshenv"
printf 'PASS: every ownership check of the full profile fails when its owner is broken\n'

# --- A copy that wins the login mise never activates (issue #396, GAP-33) ---
#
# The configured login PATH is captured from an INTERACTIVE login, which is
# the one shell where mise activation necessarily wins: the tracked Zsh
# package activates mise in .zshrc, while .zshenv -- read by every top-level
# Zsh -- puts ~/.local/bin first and adds no mise paths. So a non-mise copy in
# ~/.local/bin was reported as mise-owned, although it is what the next
# non-interactive login runs.
printf '#!/usr/bin/env bash\nexit 0\n' >"$home/.local/bin/claude"
chmod +x "$home/.local/bin/claude"
if login_shadow_output="$(env \
  HOME="$home" XDG_CONFIG_HOME="$config" XDG_DATA_HOME="$data" \
  CODEX_HOME="$home/.codex" \
  MISE_DATA_DIR="$mise_data" MISE_SHIMS_DIR="$mise_shims" \
  MISE_INSTALLS_DIR="$mise_installs" \
  PATH="$mise_shims:$home/.local/bin:$mock_bin:$PATH" \
  VERIFY_CONFIGURED_LOGIN_PATH="$mise_shims:$home/.local/bin:$mock_bin:$PATH" \
  VERIFY_NONINTERACTIVE_LOGIN_PATH="$home/.local/bin:$mock_bin" \
  "$repo_root/common/verify-ai.sh" 2>&1)"; then
  printf '%s\n' "$login_shadow_output" >&2
  printf 'verify-ai.sh accepted a non-mise claude that the non-interactive login runs\n' >&2
  exit 1
fi
assert_contains "$login_shadow_output" \
  'claude resolves outside mise in a login that is not interactive'
rm -f -- "$home/.local/bin/claude"

# The same two logins with nothing shadowing must pass, so the assertion above
# is about the copy in ~/.local/bin and not about the second probe existing.
if ! login_clean_output="$(env \
  HOME="$home" XDG_CONFIG_HOME="$config" XDG_DATA_HOME="$data" \
  CODEX_HOME="$home/.codex" \
  MISE_DATA_DIR="$mise_data" MISE_SHIMS_DIR="$mise_shims" \
  MISE_INSTALLS_DIR="$mise_installs" \
  PATH="$mise_shims:$home/.local/bin:$mock_bin:$PATH" \
  VERIFY_CONFIGURED_LOGIN_PATH="$mise_shims:$home/.local/bin:$mock_bin:$PATH" \
  VERIFY_NONINTERACTIVE_LOGIN_PATH="$home/.local/bin:$mock_bin" \
  "$repo_root/common/verify-ai.sh" 2>&1)"; then
  printf '%s\n' "$login_clean_output" >&2
  printf 'verify-ai.sh failed a machine whose non-interactive login shadows nothing\n' >&2
  exit 1
fi
assert_contains "$login_clean_output" 'claude is mise-managed'

# --- A record that does not state a selection (issue #396, GAP-32) ----------
#
# profile_state_required_keys requires only claude_code, herdr, codex and
# firstmate of an ai record, so an ai.conf written before the other keys
# existed is still valid and readable. Reading an absent key into a bare
# variable turned it into the empty string, which lost every "== installed",
# "== cloned" and "== mise-npm" comparison: the verifier printed "FirstMate
# cloned" and "lavish-axi is not installed (neither FirstMate nor backpass
# selected)" in the SAME run -- a combination no installation can produce,
# since install-ai.sh forces lavish-axi on with either -- exited 0, and
# skipped the provenance comparison removal depends on.
state_file="$config/dotfiles/ai.conf"
cp "$state_file" "$test_root/ai.conf.complete"
legacy_keys="$(grep -E '^(profile|claude_code|herdr|codex|firstmate|treehouse|gnhf)=' \
  "$test_root/ai.conf.complete")"
[[ -n "$legacy_keys" ]] ||
  _test_die 'the installed ai.conf carried none of the pre-19e8db8 keys, so this case proves nothing'
printf '%s\n' "$legacy_keys" >"$state_file"

if legacy_output="$("${test_environment[@]}" "$repo_root/common/verify-ai.sh" 2>&1)"; then
  printf '%s\n' "$legacy_output" >&2
  printf 'verify-ai.sh passed a record that does not state a selection\n' >&2
  exit 1
fi
assert_contains "$legacy_output" 'FirstMate cloned'
assert_contains "$legacy_output" \
  'records FirstMate or backpass as selected but does not record lavish-axi'
assert_not_contains "$legacy_output" \
  'lavish-axi is not installed (neither FirstMate nor backpass selected)'
# A selection that was never recorded is not a selection that was declined, so
# the recovery is to record it rather than to delete the component.
assert_contains "$legacy_output" 'No Mistakes is present'
assert_contains "$legacy_output" 'does not record whether it was selected (no_mistakes is absent)'
assert_not_contains "$legacy_output" \
  "No Mistakes is not selected but $no_mistakes_target is still present"
cp "$test_root/ai.conf.complete" "$state_file"
printf 'PASS: an AI record that does not state a selection is reported as such, not as "not selected"\n'

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

# --- Staged installation: provenance is recorded ----------------------------

assert_file_line "$state_file" "requested=codex,firstmate,gnhf,backpass"
assert_file_line "$state_file" "firstmate_source=$firstmate_origin"
recorded_commit="$(git -C "$data/firstmate" rev-parse HEAD)"
assert_file_line "$state_file" "firstmate_commit=$recorded_commit"
assert_file_line "$state_file" "treehouse_source=$treehouse_source_url"
assert_file_line "$state_file" "no_mistakes_source=$no_mistakes_source_url"
assert_file_line "$state_file" \
  "treehouse_target_digest=$(sha256sum "$treehouse_target" | cut -d' ' -f1)"
assert_file_line "$state_file" \
  "no_mistakes_target_digest=$(sha256sum "$no_mistakes_target" | cut -d' ' -f1)"
# The recorded path is always the resolved one, which is the command path
# itself for an upstream that installs there -- spelled canonically, so a test
# root under a symlinked temporary directory still compares equal.
local_bin_canonical="$(cd -P -- "$home/.local/bin" && pwd)"
assert_file_line "$state_file" "treehouse_target_path=$local_bin_canonical/treehouse"
assert_file_line "$state_file" "no_mistakes_target_path=$local_bin_canonical/no-mistakes"
printf 'PASS: staged installation records source, resolved commit, and digests\n'

# --- An upstream that installs elsewhere and links onto PATH ----------------
#
# No Mistakes on darwin/arm64 installs its binary under ~/.no-mistakes/bin and
# leaves a launcher symlink on PATH. The command path is what this repository
# promises; the layout behind it belongs to the upstream. Demanding a regular
# file at the command path asserted the other upstream's layout and failed the
# only supported macOS install of a component this repository advertises.

launcher_home="$test_root/launcher-home"
mkdir -p "$launcher_home"
launcher_environment=(
  env
  "HOME=$launcher_home" "CODEX_HOME=$launcher_home/.codex"
  "XDG_CONFIG_HOME=$launcher_home/.config"
  "XDG_DATA_HOME=$launcher_home/.local/share"
  "XDG_STATE_HOME=$launcher_home/.local/state"
  "PATH=$mock_bin:$PATH"
  "MISE_DATA_DIR=$mise_data" "MISE_SHIMS_DIR=$mise_shims"
  "MISE_INSTALLS_DIR=$mise_installs"
  "FIRSTMATE_REPO_URL=$firstmate_origin"
  MOCK_NO_MISTAKES_LAYOUT=launcher
)
launcher_command="$launcher_home/.local/bin/no-mistakes"
launcher_state="$launcher_home/.config/dotfiles/ai.conf"

if ! launcher_output="$("${launcher_environment[@]}" \
  "$repo_root/common/install-ai.sh" --firstmate 2>&1)"; then
  printf '%s\n' "$launcher_output" >&2
  printf 'install-ai.sh rejected an upstream launcher-symlink layout\n' >&2
  exit 1
fi
[[ -L "$launcher_command" ]] || {
  printf 'the launcher fixture did not install a symlink at %s\n' "$launcher_command" >&2
  exit 1
}
# Canonical, because that is what resolving the launcher yields and therefore
# what the installer reports and records. A test root under a symlinked
# temporary directory -- /var/folders on macOS -- would otherwise compare two
# spellings of the same file.
launcher_binary="$(cd -P -- "$launcher_home/.no-mistakes/bin" && pwd)/no-mistakes"
assert_path_executable "$launcher_binary"
assert_contains "$launcher_output" "No Mistakes installed binary: $launcher_command -> $launcher_binary"

# Provenance is recorded for the binary the upstream produced, not for the
# launcher: the digest is the binary's, and the recorded path is what a later
# removal has to delete.
assert_file_line "$launcher_state" "no_mistakes_target_path=$launcher_binary"
assert_file_line "$launcher_state" \
  "no_mistakes_target_digest=$(sha256sum "$launcher_binary" | cut -d' ' -f1)"
# The other component installed straight to its command path in the same run,
# so both layouts are recorded by the same code.
assert_file_line "$launcher_state" \
  "treehouse_target_path=$(cd -P -- "$launcher_home/.local/bin" && pwd)/treehouse"

if ! launcher_verify="$("${launcher_environment[@]}" \
  "PATH=$launcher_home/.local/bin:$mise_shims:$mock_bin:$PATH" \
  "$repo_root/common/verify-ai.sh" 2>&1)"; then
  printf '%s\n' "$launcher_verify" >&2
  printf 'verify-ai.sh failed an upstream launcher-symlink layout\n' >&2
  exit 1
fi
assert_contains "$launcher_verify" "no-mistakes: $launcher_command -> $launcher_binary"
assert_contains "$launcher_verify" \
  "no-mistakes resolves to the recorded installed binary: $launcher_binary"
printf 'PASS: an upstream launcher symlink installs, records its binary, and verifies\n'

# A launcher pointing at nothing is an install that did not happen, whatever
# the PATH entry suggests. It must fail at the component responsible for it.
dangling_home="$test_root/dangling-home"
mkdir -p "$dangling_home"
if dangling_output="$(env \
  HOME="$dangling_home" CODEX_HOME="$dangling_home/.codex" \
  XDG_CONFIG_HOME="$dangling_home/.config" \
  XDG_DATA_HOME="$dangling_home/.local/share" \
  XDG_STATE_HOME="$dangling_home/.local/state" \
  PATH="$mock_bin:$PATH" MISE_DATA_DIR="$mise_data" \
  MISE_SHIMS_DIR="$mise_shims" MISE_INSTALLS_DIR="$mise_installs" \
  FIRSTMATE_REPO_URL="$firstmate_origin" \
  MOCK_NO_MISTAKES_LAYOUT=dangling-launcher \
  "$repo_root/common/install-ai.sh" --firstmate 2>&1)"; then
  printf '%s\n' "$dangling_output" >&2
  printf 'install-ai.sh accepted a launcher symlink with no binary behind it\n' >&2
  exit 1
fi
assert_contains "$dangling_output" \
  'No Mistakes target does not resolve to an existing file'
assert_not_recorded "$dangling_home/.config/dotfiles/ai.conf" 'no_mistakes=installed'
printf 'PASS: a launcher symlink with no binary behind it fails the component\n'

# --- The API credential an upstream installer is offered --------------------
#
# These upstreams resolve their own latest release through api.github.com, and
# read no token variable of their own, so a CI token in the environment is
# useless to them and the install dies on an exhausted anonymous quota. The
# installer offers it the one way curl scopes by host. What matters is the
# scope: one host, one mode, and nothing left behind.

credential_home="$test_root/credential-home"
mkdir -p "$credential_home"
credential_token='fixture-value-not-a-credential'
if ! credential_output="$(env \
  HOME="$credential_home" CODEX_HOME="$credential_home/.codex" \
  XDG_CONFIG_HOME="$credential_home/.config" \
  XDG_DATA_HOME="$credential_home/.local/share" \
  XDG_STATE_HOME="$credential_home/.local/state" \
  PATH="$mock_bin:$PATH" MISE_DATA_DIR="$mise_data" \
  MISE_SHIMS_DIR="$mise_shims" MISE_INSTALLS_DIR="$mise_installs" \
  FIRSTMATE_REPO_URL="$firstmate_origin" \
  GITHUB_TOKEN="$credential_token" \
  MOCK_EXPECTED_SECRET="$credential_token" \
  "$repo_root/common/install-ai.sh" --firstmate 2>&1)"; then
  printf '%s\n' "$credential_output" >&2
  printf 'install-ai.sh failed with a token in the environment\n' >&2
  exit 1
fi

credential_report="$credential_home/staged-treehouse-report"
# One host and one line: every other host the script contacts is sent nothing.
assert_file_contains "$credential_report" 'netrc_hosts=api.github.com '
assert_file_contains "$credential_report" 'netrc_lines=1'
assert_file_contains "$credential_report" 'netrc_value=as-passed'
assert_file_contains "$credential_report" 'netrc_mode=600'
assert_file_contains "$credential_report" 'curlrc=present'
assert_contains "$credential_output" \
  'Offering the GitHub API credential to Treehouse for api.github.com only'

# The credential lives in the staging directory, which is deleted the moment
# the installer returns -- so nothing on disk outlives the run that needed it.
credential_staging="$(sed -n 's/^curl_home=//p' "$credential_report")"
[[ -n "$credential_staging" && "$credential_staging" != unset ]] || {
  printf 'the staged installer was given no CURL_HOME\n' >&2
  exit 1
}
assert_path_missing "$credential_staging"
printf 'PASS: a staged installer is offered the token for api.github.com only, in a directory that does not outlive it\n'

# No token, nothing offered: a workstation install must not acquire a
# credential file, or a mechanism that exists for CI would follow users home.
plain_home="$test_root/plain-credential-home"
mkdir -p "$plain_home"
if ! env \
  HOME="$plain_home" CODEX_HOME="$plain_home/.codex" \
  XDG_CONFIG_HOME="$plain_home/.config" \
  XDG_DATA_HOME="$plain_home/.local/share" \
  XDG_STATE_HOME="$plain_home/.local/state" \
  PATH="$mock_bin:$PATH" MISE_DATA_DIR="$mise_data" \
  MISE_SHIMS_DIR="$mise_shims" MISE_INSTALLS_DIR="$mise_installs" \
  FIRSTMATE_REPO_URL="$firstmate_origin" \
  GITHUB_TOKEN='' GH_TOKEN='' \
  "$repo_root/common/install-ai.sh" --firstmate >"$test_root/plain-credential.log" 2>&1; then
  cat "$test_root/plain-credential.log" >&2
  printf 'install-ai.sh failed without a token in the environment\n' >&2
  exit 1
fi
assert_file_contains "$plain_home/staged-treehouse-report" 'netrc=absent'
assert_file_not_contains "$test_root/plain-credential.log" 'Offering the GitHub API credential'
printf 'PASS: with no token in the environment nothing is offered and nothing is written\n'

# --- A failing download can never be masked by a successful consumer --------
#
# The original pipeline was 'curl ... | sh', whose exit status is the shell's.
# These scenarios each make the download fail in a different way and require
# the installer to stop before executing anything and before writing state that
# claims the component is installed.

staged_failure_case() {
  local label="$1"
  local expected="$2"
  local description="$3"
  shift 3

  local case_home="$test_root/staged-$label-home"
  mkdir -p "$case_home"
  local case_output
  if case_output="$(env \
    HOME="$case_home" CODEX_HOME="$case_home/.codex" \
    XDG_CONFIG_HOME="$case_home/.config" \
    XDG_DATA_HOME="$case_home/.local/share" \
    XDG_STATE_HOME="$case_home/.local/state" \
    PATH="$mock_bin:$PATH" MISE_DATA_DIR="$mise_data" \
    MISE_SHIMS_DIR="$mise_shims" MISE_INSTALLS_DIR="$mise_installs" \
    FIRSTMATE_REPO_URL="$firstmate_origin" \
    DOTFILES_FETCH_ATTEMPTS=2 DOTFILES_FETCH_RETRY_DELAY=0 \
    "$@" \
    "$repo_root/common/install-ai.sh" --firstmate 2>&1)"; then
    printf 'install-ai.sh accepted a %s installer\n' "$label" >&2
    printf '%s\n' "$case_output" >&2
    exit 1
  fi
  assert_contains "$case_output" "$expected"

  # Nothing may be left claiming success: no Treehouse binary, and no state
  # file recording the component as installed.
  assert_path_missing "$case_home/.local/bin/treehouse"
  assert_not_recorded "$case_home/.config/dotfiles/ai.conf" 'treehouse=installed'
  printf 'PASS: %s\n' "$description"
}

staged_failure_case transport 'Giving up on the Treehouse installer' \
  'a failing curl is not masked by a successful shell consumer' \
  MOCK_CURL_FAIL_URL=treehouse
staged_failure_case empty 'Download produced an empty file for the Treehouse installer' \
  'an empty download is never executed' \
  MOCK_CURL_EMPTY_URL=treehouse
staged_failure_case markup 'does not look like a shell script' \
  'content of the wrong shape is never executed' \
  MOCK_CURL_GARBAGE_URL=treehouse
staged_failure_case digest 'SHA-256 mismatch for the Treehouse installer' \
  'a wrong-digest download is never executed' \
  TREEHOUSE_INSTALL_SCRIPT_SHA256=0000000000000000000000000000000000000000000000000000000000000000

# A download that succeeds and executes, but does not produce the expected
# target, fails at the component responsible for it rather than several steps
# later. The verifier is not what catches this.
staged_failure_case wrong-target 'Treehouse did not install its expected target' \
  'an unexpected installed target fails at the responsible component' \
  MOCK_CURL_MUTATE_URL=treehouse

# The bounded retry policy is real: a transient failure inside the budget
# still succeeds, and the attempt count is capped.
transient_home="$test_root/transient-home"
transient_marker="$test_root/transient-marker"
mkdir -p "$transient_home"
cat >"$mock_bin/curl-transient" <<'EOF'
#!/usr/bin/env bash
# Fails once, then defers to the real fixture. Proves a safe fetch retries
# within its budget instead of giving up on the first transport error.
if [[ ! -e "$TRANSIENT_MARKER" ]]; then
  : >"$TRANSIENT_MARKER"
  printf 'curl: (56) simulated transient failure\n' >&2
  exit 56
fi
exec "$MOCK_CURL_REAL" "$@"
EOF
chmod +x "$mock_bin/curl-transient"
transient_bin="$test_root/transient-bin"
mkdir -p "$transient_bin"
for command_name in "$mock_bin"/*; do
  [[ "$(basename "$command_name")" != curl* ]] || continue
  ln -sf "$command_name" "$transient_bin/$(basename "$command_name")"
done
ln -sf "$mock_bin/curl-transient" "$transient_bin/curl"
if ! transient_output="$(env \
  HOME="$transient_home" CODEX_HOME="$transient_home/.codex" \
  XDG_CONFIG_HOME="$transient_home/.config" \
  XDG_DATA_HOME="$transient_home/.local/share" \
  XDG_STATE_HOME="$transient_home/.local/state" \
  PATH="$transient_bin:$PATH" MISE_DATA_DIR="$mise_data" \
  MISE_SHIMS_DIR="$mise_shims" MISE_INSTALLS_DIR="$mise_installs" \
  FIRSTMATE_REPO_URL="$firstmate_origin" \
  MOCK_CURL_REAL="$mock_bin/curl" TRANSIENT_MARKER="$transient_marker" \
  DOTFILES_FETCH_RETRY_DELAY=0 \
  "$repo_root/common/install-ai.sh" --firstmate 2>&1)"; then
  printf '%s\n' "$transient_output" >&2
  printf 'install-ai.sh did not retry a transient download failure\n' >&2
  exit 1
fi
assert_contains "$transient_output" 'attempt 1/3'
assert_path_executable "$transient_home/.local/bin/treehouse"
printf 'PASS: a transient safe fetch retries within the bounded policy\n'

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

dry_run_residue="$(find "$dry_home" -mindepth 1 -print -quit)"
if [[ -n "$dry_run_residue" ]]; then
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
