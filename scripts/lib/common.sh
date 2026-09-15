#!/usr/bin/env bash

# Deprecated sourced compatibility shim for common/lib/common.sh.
#
# The name shadows the library it forwards to, which is exactly the confusion
# it now warns about. It keeps working; see
# docs/architecture/repository-conventions.md for the removal policy.

# shellcheck source=../../common/lib/deprecation.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/deprecation.sh"
deprecated_wrapper "scripts/lib/common.sh" "common/lib/common.sh"

# shellcheck source=../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/common.sh"
