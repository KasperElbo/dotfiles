#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

mock_bin="$test_root/bin"
command_log="$test_root/nvim.log"
mkdir -p "$mock_bin" "$test_root/home" "$test_root/data"

cat >"$mock_bin/nvim" <<'EOF'
#!/usr/bin/env bash
printf 'bootstrap=%s nvim' "${DOTFILES_MASON_BOOTSTRAP:-}" >>"$COMMAND_LOG"
printf ' <%s>' "$@" >>"$COMMAND_LOG"
printf '\n' >>"$COMMAND_LOG"

for argument in "$@"; do
  if [[ "$argument" == '+Lazy! restore' && \
    "${MOCK_NVIM_HANG_LAZY:-false}" == "true" ]]; then
    sleep 10
  fi

  if [[ "$argument" == */common/bootstrap-mason.lua ]]; then
    [[ "${MOCK_NVIM_FAIL_MASON:-false}" != "true" ]] || exit 23
    for package in $DOTFILES_MASON_PACKAGES; do
      mkdir -p "$XDG_DATA_HOME/nvim/mason/packages/$package"
    done
  fi
done
EOF
chmod +x "$mock_bin/nvim"

test_environment=(
  env
  "HOME=$test_root/home"
  "XDG_DATA_HOME=$test_root/data"
  "PATH=$mock_bin:$PATH"
  "COMMAND_LOG=$command_log"
  "NEOVIM_BOOTSTRAP_TIMEOUT=1m"
)

"${test_environment[@]}" "$repo_root/common/install-neovim-tools.sh" >/dev/null
"${test_environment[@]}" "$repo_root/common/install-neovim-tools.sh" >/dev/null

[[ "$(grep -Fc '<+Lazy! restore>' "$command_log")" == 2 ]] || {
  printf 'Expected a bounded LazyVim restore on every run\n' >&2
  exit 1
}
[[ "$(grep -Fc '/common/bootstrap-mason.lua>' "$command_log")" == 1 ]] || {
  printf 'Expected Mason installation to be skipped after convergence\n' >&2
  exit 1
}
grep -Fq 'bootstrap=1 nvim' "$command_log"

while IFS= read -r package; do
  [[ -n "$package" ]] || continue
  [[ -d "$test_root/data/nvim/mason/packages/$package" ]] || {
    printf 'Mock provisioning omitted Mason package: %s\n' "$package" >&2
    exit 1
  }
done <"$repo_root/nvim-lazyvim/.config/nvim/mason-packages.txt"

failure_root="$test_root/failure-data"
if output="$(
  env HOME="$test_root/home" XDG_DATA_HOME="$failure_root" \
    PATH="$mock_bin:$PATH" COMMAND_LOG="$command_log" \
    NEOVIM_BOOTSTRAP_TIMEOUT=1m MOCK_NVIM_FAIL_MASON=true \
    "$repo_root/common/install-neovim-tools.sh" 2>&1
)"; then
  printf 'Expected Mason provisioning failure to propagate\n' >&2
  exit 1
fi
[[ "$output" == *"Installing Mason editor tools failed with exit status 23"* ]] || {
  printf 'Mason failure was not surfaced clearly:\n%s\n' "$output" >&2
  exit 1
}

if output="$(
  env HOME="$test_root/home" XDG_DATA_HOME="$test_root/timeout-data" \
    PATH="$mock_bin:$PATH" COMMAND_LOG="$command_log" \
    NEOVIM_BOOTSTRAP_TIMEOUT=1s MOCK_NVIM_HANG_LAZY=true \
    "$repo_root/common/install-neovim-tools.sh" 2>&1
)"; then
  printf 'Expected the LazyVim restore timeout to propagate\n' >&2
  exit 1
fi
[[ "$output" == *"Restoring LazyVim plugins timed out after 1s"* ]] || {
  printf 'LazyVim timeout was not surfaced clearly:\n%s\n' "$output" >&2
  exit 1
}

printf 'Neovim bootstrap convergence checks passed.\n'
