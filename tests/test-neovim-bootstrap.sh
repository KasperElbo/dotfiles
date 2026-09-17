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
# Answered before anything is logged: the installer's floor check asks this,
# and it must not count as a bootstrap invocation.
if [[ "${1:-}" == --version ]]; then
  printf 'NVIM v%s\n' "${MOCK_NVIM_VERSION:-0.12.5}"
  exit 0
fi
printf 'bootstrap=%s nvim' "${DOTFILES_MASON_BOOTSTRAP:-}" >>"$COMMAND_LOG"
printf ' <%s>' "$@" >>"$COMMAND_LOG"
printf '\n' >>"$COMMAND_LOG"

for argument in "$@"; do
  if [[ "$argument" == '+Lazy! restore mason.nvim' ]]; then
    mkdir -p "$XDG_DATA_HOME/nvim/lazy/mason.nvim"
  fi

  if [[ "$argument" == '+Lazy! restore' && \
    "${MOCK_NVIM_HANG_LAZY:-false}" == "true" ]]; then
    sleep 10
  fi

  # Model the real LazyVim failure: a normal Treesitter restore would race if
  # it ran before the blocking Mason phase had made tree-sitter-cli available.
  if [[ "$argument" == '+Lazy! restore' && \
    "${MOCK_NVIM_TREE_SITTER_RACE:-false}" == "true" && \
    ! -x "$XDG_DATA_HOME/nvim/mason/bin/tree-sitter" ]]; then
    printf 'Package is already installing\n'
  fi

  if [[ "$argument" == */common/bootstrap-mason.lua ]]; then
    [[ "${MOCK_NVIM_FAIL_MASON:-false}" != "true" ]] || exit 23
    printf 'mason-targets=%s\n' "$DOTFILES_MASON_PACKAGES" >>"$COMMAND_LOG"
    mkdir -p "$XDG_DATA_HOME/nvim/mason/bin"
    for target in $DOTFILES_MASON_PACKAGES; do
      # Mason stores a package under its name whether or not the request
      # carried an "@version" pin.
      package="${target%%@*}"
      mkdir -p "$XDG_DATA_HOME/nvim/mason/packages/$package"
      if [[ "$package" == tree-sitter-cli ]]; then
        cat >"$XDG_DATA_HOME/nvim/mason/bin/tree-sitter" <<'TREEEOF'
#!/usr/bin/env bash
exit 0
TREEEOF
        chmod +x "$XDG_DATA_HOME/nvim/mason/bin/tree-sitter"
      fi
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

[[ "$(grep -Fc '<+Lazy! restore mason.nvim>' "$command_log")" == 2 ]] || {
  printf 'Expected a targeted Mason restore before every inventory check\n' >&2
  exit 1
}
[[ "$(grep -Fc '<+Lazy! restore>' "$command_log")" == 2 ]] || {
  printf 'Expected one normal LazyVim restore after Mason on every run\n' >&2
  exit 1
}
[[ "$(grep -Fc '/common/bootstrap-mason.lua>' "$command_log")" == 1 ]] || {
  printf 'Expected Mason installation to be skipped after convergence\n' >&2
  exit 1
}
grep -Fq 'bootstrap=1 nvim <--headless> <+Lazy! restore mason.nvim>' "$command_log"
grep -Fq 'bootstrap=0 nvim <--headless> <+Lazy! restore>' "$command_log"

while IFS= read -r package; do
  [[ -n "$package" ]] || continue
  [[ -d "$test_root/data/nvim/mason/packages/$package" ]] || {
    printf 'Mock provisioning omitted Mason package: %s\n' "$package" >&2
    exit 1
  }
done <"$repo_root/nvim-lazyvim/.config/nvim/mason-packages.txt"
[[ -x "$test_root/data/nvim/mason/bin/tree-sitter" ]] || {
  printf 'tree-sitter-cli was not exposed through the Mason bin directory\n' >&2
  exit 1
}

# Packages recorded in the pin file must be requested at that exact version so
# a registry release that advertises an unpublished upstream build cannot break
# a real installation. Everything else must stay unpinned.
pin_file="$repo_root/common/mason-package-versions.txt"
mason_targets="$(grep -F 'mason-targets=' "$command_log" | head -n1)"
while read -r pinned_package pinned_version _; do
  [[ -n "$pinned_package" ]] || continue
  grep -Fxq "$pinned_package" \
    "$repo_root/nvim-lazyvim/.config/nvim/mason-packages.txt" || continue
  [[ "$mason_targets" == *" $pinned_package@$pinned_version"* ||
    "$mason_targets" == *"=$pinned_package@$pinned_version"* ]] || {
    printf 'Mason install did not request the pinned version of %s (%s):\n%s\n' \
      "$pinned_package" "$pinned_version" "$mason_targets" >&2
    exit 1
  }
  [[ -d "$test_root/data/nvim/mason/packages/$pinned_package" ]] || {
    printf 'Pinned Mason package was not installed under its plain name: %s\n' \
      "$pinned_package" >&2
    exit 1
  }
done < <(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$pin_file")

[[ "$mason_targets" == *' stylua '* || "$mason_targets" == *' stylua' ]] || {
  printf 'Unpinned Mason packages must be requested without a version:\n%s\n' \
    "$mason_targets" >&2
  exit 1
}

parrot_data="$test_root/parrot-data"
"${test_environment[@]}" XDG_DATA_HOME="$parrot_data" \
  "$repo_root/common/install-neovim-tools.sh" --profile parrot-ctf >/dev/null
"${test_environment[@]}" XDG_DATA_HOME="$parrot_data" \
  "$repo_root/common/install-neovim-tools.sh" --profile parrot-ctf >/dev/null
mapfile -t actual_parrot_packages < <(
  find "$parrot_data/nvim/mason/packages" -mindepth 1 -maxdepth 1 \
    -type d -printf '%f\n' | sort
)
mapfile -t expected_parrot_packages < <(
  sort "$repo_root/nvim-lazyvim/.config/nvim/profiles/parrot-ctf/mason-packages.txt"
)
[[ "${actual_parrot_packages[*]}" == "${expected_parrot_packages[*]}" ]] || {
  printf 'Reduced Parrot Mason inventory changed during bootstrap.\n' >&2
  exit 1
}

race_root="$test_root/race-data"
race_log="$test_root/race.log"
if ! output="$(
  env HOME="$test_root/home" XDG_DATA_HOME="$race_root" \
    PATH="$mock_bin:$PATH" COMMAND_LOG="$race_log" \
    NEOVIM_BOOTSTRAP_TIMEOUT=1m MOCK_NVIM_TREE_SITTER_RACE=true \
    "$repo_root/common/install-neovim-tools.sh" 2>&1
)"; then
  printf 'Ordered tree-sitter bootstrap unexpectedly failed:\n%s\n' "$output" >&2
  exit 1
fi
[[ "$output" != *"Package is already installing"* ]] || {
  printf 'Normal LazyVim restore ran before tree-sitter-cli converged:\n%s\n' "$output" >&2
  exit 1
}
prepare_line="$(grep -nF '<+Lazy! restore mason.nvim>' "$race_log" | head -n1 | cut -d: -f1)"
mason_line="$(grep -nF '/common/bootstrap-mason.lua>' "$race_log" | head -n1 | cut -d: -f1)"
restore_line="$(grep -nF '<+Lazy! restore>' "$race_log" | head -n1 | cut -d: -f1)"
if [[ -z "$prepare_line" || -z "$mason_line" || -z "$restore_line" ]] ||
  ! ((prepare_line < mason_line && mason_line < restore_line)); then
  printf 'Expected Mason preparation -> blocking inventory -> normal Lazy restore ordering\n' >&2
  cat "$race_log" >&2
  exit 1
fi

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

timeout_root="$test_root/timeout-data"
if output="$(
  env HOME="$test_root/home" XDG_DATA_HOME="$timeout_root" \
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

# A Neovim below the documented floor must stop before any headless phase,
# naming the version and the floor. Below it, Mason fails partway through with
# a Lua error that names neither Neovim nor a version.
below_floor_log="$test_root/below-floor.log"
if "${test_environment[@]}" MOCK_NVIM_VERSION=0.9.5 \
  COMMAND_LOG="$below_floor_log" XDG_DATA_HOME="$test_root/below-floor-data" \
  "$repo_root/common/install-neovim-tools.sh" >"$test_root/below-floor.out" 2>&1; then
  printf 'A Neovim below the floor unexpectedly bootstrapped.\n' >&2
  exit 1
fi
grep -Fq 'nvim 0.9.5 is older than the required 0.12' "$test_root/below-floor.out"
[[ ! -s "$below_floor_log" ]] || {
  printf 'The floor check must refuse before any nvim --headless call:\n%s\n' \
    "$(cat "$below_floor_log")" >&2
  exit 1
}
printf 'Neovim bootstrap convergence checks passed.\n'
