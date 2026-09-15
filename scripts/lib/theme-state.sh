#!/usr/bin/env bash

# Deprecated sourced compatibility shim.
#
# The shared theme-state writer is now common/lib/theme-shared-state.sh, named
# for what it does rather than sharing a filename with the Fedora desktop
# theming library. This shim keeps working; see
# docs/architecture/repository-conventions.md for the removal policy.

# shellcheck source=../../common/lib/deprecation.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/deprecation.sh"
deprecated_wrapper "scripts/lib/theme-state.sh" "common/lib/theme-shared-state.sh"

# shellcheck source=../../common/lib/theme-shared-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/theme-shared-state.sh"
