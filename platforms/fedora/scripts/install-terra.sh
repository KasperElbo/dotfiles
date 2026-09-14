#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/fedora.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/fedora.sh"

require_fedora
ensure_terra_repository

packages=(
  ghostty
  mise
  starship
)

# mise's own upstream install docs point Fedora users at a separate
# jdxcode/mise COPR repo. If that repo is also enabled, its mise package
# conflicts with the Terra-provided mise-zsh-completion package (which
# requires an exact matching mise version), and dnf silently skips
# installing/upgrading mise rather than choosing between the two repos.
# Exclude that repo for this transaction so Terra's mise always wins.
#
# --disablerepo is not a no-op for a repo DNF does not know: dnf5 rejects the
# whole transaction with "No matching repositories for ...". A clean Fedora
# machine has never enabled this COPR, so pass the flag only when the repo is
# actually configured.
mise_copr_repo="copr:copr.fedorainfracloud.org:jdxcode:mise"
repo_definition_dir="${DNF_REPO_DIR:-/etc/yum.repos.d}"
repository_arguments=()
if grep -Rqs -F -- "[$mise_copr_repo]" "$repo_definition_dir"; then
  info "Excluding the conflicting $mise_copr_repo repository"
  repository_arguments+=(--disablerepo="$mise_copr_repo")
fi

info "Installing Terra packages"

sudo dnf install -y \
  ${repository_arguments[@]+"${repository_arguments[@]}"} \
  "${packages[@]}"

success "Terra packages installed"
