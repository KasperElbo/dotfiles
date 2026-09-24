#!/usr/bin/env bash
set -euo pipefail

# A verifier's interactive login probe must leave the terminal with the
# verifier. An interactive Zsh with job control takes the terminal's foreground
# group, and when its -c string ends in an external command it execs that
# command in place, so the terminal was never handed back: the installer went
# on as a background job until something changed terminal settings and the
# kernel stopped it ("zsh: suspended (tty output)" at `ng test`, 24 September
# 2026). Only a real Zsh on a real terminal shows this, so this runs the probe
# on a pseudo-terminal and asks the terminal afterwards.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_isolate_path python3 zsh
test_new_root
home="$TEST_ROOT/home"
mkdir -p "$home/.config/zsh"
# .zshenv and .zshrc of their own, so no host startup file takes part.
printf 'export ZDOTDIR="$HOME/.config/zsh"\n' >"$home/.zshenv"
printf 'probe_rc_read=yes\n' >"$home/.config/zsh/.zshrc"

probe() {
  HOME="$home" "$repo_root/tests/support/foreground-after.py" \
    "source '$repo_root/common/lib/common.sh' && source '$repo_root/common/lib/verify.sh' && $1"
}

# The control: the same shape without the helper loses the terminal, so the
# pseudo-terminal can see the defect at all.
answer="$(probe "zsh -lic 'sh -c :'")"
[[ "$answer" == "foreground lost" ]] ||
  _test_die "a bare interactive zsh probe kept the terminal ($answer); this test cannot see the defect"
printf 'PASS: control: a bare interactive zsh probe ending in a command loses the terminal\n'

answer="$(probe "verify_login_zsh -lic 'sh -c :'")"
[[ "$answer" == "foreground kept" ]] ||
  _test_die "verify_login_zsh -lic left the terminal with the probe ($answer)"
printf 'PASS: an interactive login probe ending in a command leaves the terminal with the verifier\n'

# Still interactive, so the probe still reads .zshrc, which is what -i is for.
answer="$(probe "[[ \"\$(verify_login_zsh -lic 'print -r -- \$probe_rc_read')\" == yes ]]")"
[[ "$answer" == "foreground kept" ]] ||
  _test_die "the interactive login probe did not read .zshrc or lost the terminal ($answer)"
printf 'PASS: the interactive login probe still reads .zshrc\n'
