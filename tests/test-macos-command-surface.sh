#!/usr/bin/env bash
# The commands macOS puts on a user's PATH, and the Bash they may assume (#256).
#
# The installer establishes the modern-Bash boundary for itself: the
# compatibility entry point runs under Apple's Bash 3.2 and reaches Homebrew
# Bash before scripts/install-main.sh. A stowed command is a separate execution
# surface. It is launched from a login shell, a key binding or automation, with
# whatever PATH that environment has, and nothing had established a boundary for
# it -- which is how `theme` came to enter install-selection.sh under Bash 3.2
# and fail on `declare -A` before running any of its own code.
#
# This suite is deliberately written in the Bash 3.2 dialect, because the macOS
# workflow runs it under /bin/bash, where a real Apple Bash is available and the
# interesting case can be exercised for real rather than modelled.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"

# --- The audit, derived from the manifest rather than from a list -------------

# The set of commands is read from config/capabilities.tsv so a new stow package
# on macOS is audited the moment it is declared, rather than when someone
# remembers to add it here. A prose audit would have been accurate once.
macos_packages="$(
  awk -F'\t' '$2 == "macos" && $15 == "implemented" && $10 != "-" && $10 != "" { print $10 }' \
    "$repo_root/config/capabilities.tsv" | tr ',' '\n' | sort -u
)"
[[ -n "$macos_packages" ]] ||
  { printf 'No macOS stow packages found; the audit would pass vacuously\n' >&2; exit 1; }

# A package lives either at the repository root or under the macOS platform.
package_dir() {
  if [[ -d "$repo_root/$1" ]]; then
    printf '%s\n' "$repo_root/$1"
  elif [[ -d "$repo_root/platforms/macos/stow/$1" ]]; then
    printf '%s\n' "$repo_root/platforms/macos/stow/$1"
  fi
}

commands=""
for package in $macos_packages; do
  directory="$(package_dir "$package")"
  [[ -n "$directory" && -d "$directory/.local/bin" ]] || continue
  for candidate in "$directory/.local/bin"/*; do
    [[ -f "$candidate" && -x "$candidate" ]] || continue
    commands="$commands$candidate"$'\n'
  done
done
commands="$(printf '%s' "$commands" | sed '/^$/d')"
[[ -n "$commands" ]] ||
  { printf 'No macOS commands found on the stowed PATH; the audit proves nothing\n' >&2; exit 1; }

# Each command is one of two things, and the classification is enforced rather
# than recorded: either it never loads a modern-Bash library and is safe under
# Apple's Bash as it stands, or it selects a supported Bash before the first
# such load. Making every shared script 3.2-compatible is explicitly not the
# goal; the baseline stays where it is.
#
# classify_command <path>: prints the category, or explains the violation and
# returns 1. Taking a path rather than reading the tree directly is what lets
# the fixtures below prove it can actually refuse.
classify_command() {
  local command_path="$1"
  local name first_library guard construct
  name="$(basename "$command_path")"
  first_library="$(
    grep -n '^\(source\|\.\) .*common/lib/' "$command_path" |
      grep -v 'modern-bash\.sh' | head -n 1 | cut -d: -f1 || true
  )"

  if [[ -z "$first_library" ]]; then
    # Category 1: no shared library, so nothing can require Bash 4. The dialect
    # is still checked, because the command runs under whatever Bash the user's
    # environment provides, and that may be Apple's.
    for construct in 'declare -[Aa]' 'local -[Aa]' '\bmapfile\b' '\breadarray\b'; do
      if sed -e 's/^[[:space:]]*#.*$//' "$command_path" | grep -Eq -- "$construct"; then
        printf '%s loads no shared library but uses %s, which Apple Bash 3.2 lacks;\n' \
          "$name" "$construct" >&2
        printf 'either stay inside that dialect or select a supported Bash first.\n' >&2
        return 1
      fi
    done
    printf 'is safe under Apple Bash as it stands (no shared library)\n'
    return 0
  fi

  # Category 2: modern-Bash-only, and therefore required to pass through the
  # boundary before the library that needs it is loaded.
  guard="$(grep -n '^modern_bash_reexec ' "$command_path" | head -n 1 | cut -d: -f1 || true)"
  if [[ -z "$guard" ]]; then
    printf '%s loads a shared library at line %s without selecting a supported Bash;\n' \
      "$name" "$first_library" >&2
    printf 'source common/lib/modern-bash.sh and call modern_bash_reexec first.\n' >&2
    return 1
  fi
  if ((guard >= first_library)); then
    printf '%s selects its Bash at line %s, after loading a library at line %s\n' \
      "$name" "$guard" "$first_library" >&2
    return 1
  fi
  printf 'selects a supported Bash before loading any shared library\n'
}

audited=0
while IFS= read -r command_path; do
  [[ -n "$command_path" ]] || continue
  category="$(classify_command "$command_path")" || exit 1
  printf 'PASS: %s %s\n' "$(basename "$command_path")" "$category"
  audited=$((audited + 1))
done <<<"$commands"
printf 'PASS: every macOS command on the stowed PATH is audited (%d)\n' "$audited"

# The classification must be able to refuse, or the audit above says nothing.
# Three fixtures, one per way a command can be wrong.
fixtures="$root/fixtures"
mkdir -p "$fixtures"

cat >"$fixtures/unguarded" <<'EOF_UNGUARDED'
#!/usr/bin/env bash
source "$repo_root/common/lib/install-lifecycle.sh"
EOF_UNGUARDED
! classify_command "$fixtures/unguarded" >/dev/null 2>&1 ||
  { printf 'A command loading a library with no guard was accepted\n' >&2; exit 1; }
printf 'PASS: a command loading a shared library with no guard is refused\n'

cat >"$fixtures/late-guard" <<'EOF_LATE'
#!/usr/bin/env bash
source "$repo_root/common/lib/install-lifecycle.sh"
modern_bash_reexec late "$0" "$@"
EOF_LATE
! classify_command "$fixtures/late-guard" >/dev/null 2>&1 ||
  { printf 'A command guarding after its library load was accepted\n' >&2; exit 1; }
printf 'PASS: a command that guards after loading a library is refused\n'

cat >"$fixtures/modern-dialect" <<'EOF_MODERN'
#!/usr/bin/env bash
declare -A counts=()
counts[one]=1
EOF_MODERN
! classify_command "$fixtures/modern-dialect" >/dev/null 2>&1 ||
  { printf 'A library-free command using Bash 4 syntax was accepted\n' >&2; exit 1; }
printf 'PASS: a library-free command using Bash 4 syntax is refused\n'

# --- The interesting case, run for real where a real Apple Bash exists --------

# /bin/bash is Apple's 3.2 on a macOS runner and a modern Bash elsewhere, so the
# distinction is made by asking it rather than by asking uname.
system_bash="/bin/bash"
system_bash_is_old="false"
if [[ -x "$system_bash" ]] &&
  ! "$system_bash" -c \
    '((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4)))' \
    >/dev/null 2>&1; then
  system_bash_is_old="true"
fi

theme_command="$repo_root/bin/.local/bin/theme"
stowed_bin="$root/stowed/.local/bin"
mkdir -p "$stowed_bin" "$root/home" "$root/xdg" "$root/state"
# Invoked through the symlink Stow creates, as a user invokes it, rather than as
# an argument to the test runner's own Bash.
ln -s "$theme_command" "$stowed_bin/theme"

if [[ "$system_bash_is_old" == true ]]; then
  # A PATH where the system directory precedes Homebrew, which is what a login
  # shell, a launcher or an automation environment can easily have. `env bash`
  # then resolves to Apple's, and the command must still work.
  output="$(
    env PATH="/bin:/usr/bin:/opt/homebrew/bin" \
      HOME="$root/home" XDG_CONFIG_HOME="$root/xdg" \
      XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/home/.local/share" \
      DOTFILES_BOOTSTRAP_TRACE=true \
      "$stowed_bin/theme" --help 2>&1
  )"
  grep -Fq 'Usage: theme' <<<"$output" || {
    printf 'theme did not run under a system-Bash-first PATH:\n%s\n' "$output" >&2
    exit 1
  }
  ! grep -Fq 'declare' <<<"$output" || {
    printf 'theme reached a modern-Bash library under Apple Bash:\n%s\n' "$output" >&2
    exit 1
  }
  grep -Fq 're-executing with' <<<"$output" || {
    printf 'theme did not re-exec although the system Bash is 3.2:\n%s\n' "$output" >&2
    exit 1
  }
  printf 'PASS: theme runs under a real Apple Bash on a system-Bash-first PATH\n'

  # Argument preservation across the re-exec, checked through the same path a
  # user takes. An invalid flavour is used so nothing is applied.
  output="$(
    env PATH="/bin:/usr/bin:/opt/homebrew/bin" \
      HOME="$root/home" XDG_CONFIG_HOME="$root/xdg" \
      XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/home/.local/share" \
      "$stowed_bin/theme" not-a-flavour --preserve-wallpaper 2>&1 || true
  )"
  grep -Fq 'Invalid Catppuccin flavour: not-a-flavour' <<<"$output" || {
    printf 'Arguments did not survive the re-exec under Apple Bash:\n%s\n' "$output" >&2
    exit 1
  }
  ! grep -Fq 'Unknown option: --preserve-wallpaper' <<<"$output" || {
    printf '--preserve-wallpaper was lost or reordered:\n%s\n' "$output" >&2
    exit 1
  }
  printf 'PASS: theme mocha --preserve-wallpaper keeps its argv across the re-exec\n'

  # With no supported Bash anywhere on PATH, the user gets the cause and the
  # fix. Homebrew is dropped from PATH and the two Homebrew prefixes the library
  # probes are redirected, which is why this case needs its own PATH rather than
  # the one above.
  output="$(
    env PATH="/bin:/usr/bin" \
      HOME="$root/home" XDG_CONFIG_HOME="$root/xdg" \
      XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/home/.local/share" \
      DOTFILES_MODERN_BASH="$system_bash" \
      "$stowed_bin/theme" mocha 2>&1 || true
  )"
  if ! grep -Fq 'requires Bash 4.4 or newer' <<<"$output" &&
    ! grep -Fq 'Usage: theme' <<<"$output"; then
    printf 'Removing Homebrew from PATH produced neither a run nor a diagnostic:\n%s\n' \
      "$output" >&2
    exit 1
  fi
  ! grep -Fq 'declare' <<<"$output" || {
    printf 'A declare error reached the user:\n%s\n' "$output" >&2
    exit 1
  }
  printf 'PASS: no declare error reaches the user when Homebrew Bash is off PATH\n'
else
  # What this run does and does not prove: the audit above is complete and
  # exact, and tests/test-theme.sh drives the selection library itself. The
  # direct invocation under a real Apple Bash is the one thing that needs a
  # macOS runner, where the workflow's system-Bash step runs this same file
  # under /bin/bash.
  printf 'NOTE: /bin/bash here is Bash %s, not Apple 3.2, so the direct\n' \
    "$("$system_bash" -c 'printf "%s" "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
  printf '      invocation case is exercised on the macOS runner instead.\n'

  # The command must still work when invoked through its Stow symlink, which is
  # the part of the user's path that can be checked anywhere: the repository is
  # resolved through the symlink before the guard uses it.
  output="$(
    env HOME="$root/home" XDG_CONFIG_HOME="$root/xdg" \
      XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/home/.local/share" \
      "$stowed_bin/theme" --help 2>&1
  )"
  grep -Fq 'Usage: theme' <<<"$output" || {
    printf 'theme did not run through its Stow symlink:\n%s\n' "$output" >&2
    exit 1
  }
  printf 'PASS: theme runs when invoked through its Stow symlink\n'
fi

printf 'macOS command-surface runtime-boundary tests passed.\n'
