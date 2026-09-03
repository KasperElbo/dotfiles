#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"
# shellcheck source=../scripts/lib/power-profiles.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/power-profiles.sh"

command_log="$(mktemp)"
trap 'rm -f -- "$command_log"' EXIT

# The production helper calls systemctl through sudo; this test intercepts sudo
# separately and uses this function only for read-only state queries.
# shellcheck disable=SC2032
systemctl() {
  if [[ "$1" == "is-enabled" ]]; then
    case "$2" in
    power-profiles-daemon.service)
      printf 'disabled\n'
      ;;
    tuned-ppd.service)
      printf 'not-found\n'
      return 1
      ;;
    tuned.service)
      printf 'masked-runtime\n'
      return 1
      ;;
    esac

    return
  fi

  return 2
}

sudo() {
  printf '%s\n' "$*" >>"$command_log"
}

mask_conflicting_power_profile_services >/dev/null

grep -Fqx \
  'systemctl mask --now power-profiles-daemon.service' \
  "$command_log"
grep -Fqx \
  'systemctl mask --now tuned.service' \
  "$command_log"

if grep -Fq 'tuned-ppd.service' "$command_log"; then
  printf 'An absent power-profile service was masked\n' >&2
  exit 1
fi

printf 'Power-profile service regression tests passed.\n'
