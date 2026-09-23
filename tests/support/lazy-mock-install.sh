#!/usr/bin/env bash
set -euo pipefail

# Leave behind what a finished Lazy plugin install leaves behind, so a fixture
# produces evidence check_lazy_plugin_state accepts and a suite can damage on
# purpose.
#
# Usage: lazy-mock-install.sh [--omit <plugin>]... <lockfile> <data_home>
#
# <lockfile> is the profile's lazy-lock.json, the same file the verifier reads.
# Taking the commits from it rather than from a list here is the point: a
# fixture that invented its own commits would model a machine no lock file
# describes, and would keep passing if the tracked lock file changed.
#
# <data_home> is XDG_DATA_HOME; plugins are written under <data_home>/nvim/lazy,
# which is where Neovim's stdpath("data") puts them.
#
# --omit leaves a plugin out, which is how a suite models the tree a verifier
# must report rather than credit.
#
# markdown-preview.nvim also gets a package.json naming its version and what
# its build leaves behind (markdown-preview-mock-build.sh). --no-preview-server
# leaves the build out, which is the tree a headless install whose build never
# finished left on every platform.
#
# Each plugin is a Git checkout whose HEAD is the pinned commit. The commit
# object itself is not created: the lock file names real upstream commits, and
# no fixture can conjure their contents. Writing the id into .git/HEAD is what
# a detached checkout at that commit looks like to `git rev-parse HEAD`, which
# is the question the verifier asks. A check that grew to read the object
# itself would need this fixture to grow with it, and should.

omitted=()
preview_server=true
while [[ "${1:-}" == --omit || "${1:-}" == --no-preview-server ]]; do
  if [[ "$1" == --no-preview-server ]]; then
    preview_server=false
    shift
    continue
  fi
  omitted+=("${2:?--omit requires a plugin name}")
  shift 2
done

lockfile="${1:?lock file is required}"
data_home="${2:?XDG_DATA_HOME is required}"

command -v jq >/dev/null 2>&1 ||
  { printf 'lazy-mock-install.sh requires jq\n' >&2; exit 1; }
[[ -r "$lockfile" ]] ||
  { printf 'lazy-mock-install.sh cannot read the lock file: %s\n' "$lockfile" >&2; exit 1; }

support_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
lazy_root="$data_home/nvim/lazy"
mkdir -p "$lazy_root"

installed=0
while IFS=$'\t' read -r plugin commit; do
  [[ -n "$plugin" && -n "$commit" ]] || continue
  for skip in ${omitted[@]+"${omitted[@]}"}; do
    [[ "$plugin" != "$skip" ]] || continue 2
  done

  # A hand-built .git is what keeps this usable for the whole plugin set: one
  # `git init` per plugin is dozens of processes per fixture. These four
  # entries are what git needs to read the repository and answer rev-parse.
  git_dir="$lazy_root/$plugin/.git"
  mkdir -p "$git_dir/objects" "$git_dir/refs/heads"
  printf '%s\n' "$commit" >"$git_dir/HEAD"
  printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n' >"$git_dir/config"
  if [[ "$plugin" == markdown-preview.nvim ]]; then
    printf '{ "name": "markdown-preview", "version": "0.0.10" }\n' \
      >"$lazy_root/$plugin/package.json"
    if [[ "$preview_server" == true ]]; then
      "$support_dir/markdown-preview-mock-build.sh" "$lazy_root/$plugin"
    fi
  fi
  installed=$((installed + 1))
done < <(jq -r 'to_entries[] | [.key, .value.commit] | @tsv' "$lockfile")

((installed > 0)) ||
  { printf 'lazy-mock-install.sh installed nothing from %s\n' "$lockfile" >&2; exit 1; }
