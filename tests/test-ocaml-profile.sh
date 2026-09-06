#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

mock_bin="$test_root/bin"
command_log="$test_root/opam.log"
mock_state="$test_root/opam-state"
mkdir -p "$mock_bin" "$test_root/home" "$test_root/config"

cat >"$mock_bin/opam" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$COMMAND_LOG"

case "$1 ${2:-}" in
  'var root')
    [[ -f "$MOCK_STATE/initialized" ]]
    ;;
  'init --bare')
    mkdir -p "$MOCK_STATE"
    : >"$MOCK_STATE/initialized"
    ;;
  'update --yes')
    ;;
  'switch list')
    [[ -f "$MOCK_STATE/switch" ]] && cat "$MOCK_STATE/switch"
    ;;
  'switch create')
    mkdir -p "$MOCK_STATE"
    printf '%s\n' "$3" >"$MOCK_STATE/switch"
    ;;
  'switch set')
    ;;
  'install --switch')
    ;;
  'exec --switch')
    shift 3
    [[ "$1" == -- ]] && shift

    if [[ "$1 ${2:-}" == 'ocamlc -version' ]]; then
      printf '5.5.0\n'
    fi
    ;;
  *)
    printf 'Unexpected mocked opam command: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$mock_bin/opam"

test_environment=(
  env
  "HOME=$test_root/home"
  "XDG_CONFIG_HOME=$test_root/config"
  "PATH=$mock_bin:$PATH"
  "COMMAND_LOG=$command_log"
  "MOCK_STATE=$mock_state"
)

"${test_environment[@]}" "$repo_root/common/install-ocaml.sh" >/dev/null

state_file="$test_root/config/dotfiles/ocaml.conf"
grep -Fxq 'switch=dotfiles-ocaml-5.5.0' "$state_file"
grep -Fxq 'compiler=5.5.0' "$state_file"
grep -Fxq 'init --bare --no-setup --yes' "$command_log"
grep -Fxq 'switch create dotfiles-ocaml-5.5.0 5.5.0 --yes' "$command_log"
grep -Fxq \
  'install --switch dotfiles-ocaml-5.5.0 --yes dune earlybird ocaml-lsp-server ocamlformat utop' \
  "$command_log"

"${test_environment[@]}" "$repo_root/common/verify-ocaml.sh" >/dev/null
"${test_environment[@]}" "$repo_root/common/install-ocaml.sh" >/dev/null

[[ "$(grep -Fc 'switch create dotfiles-ocaml-5.5.0' "$command_log")" == 1 ]]

if "${test_environment[@]}" env OCAML_COMPILER_VERSION=trunk \
  "$repo_root/common/install-ocaml.sh" >/dev/null 2>&1; then
  printf 'Invalid OCaml compiler version was accepted.\n' >&2
  exit 1
fi

# shellcheck disable=SC2016 # The test asserts the literal shell configuration.
grep -Fq 'source "$HOME/.opam/opam-init/init.zsh"' \
  "$repo_root/zsh/.config/zsh/.zshrc"

printf 'Optional OCaml profile ownership and idempotency checks passed.\n'
