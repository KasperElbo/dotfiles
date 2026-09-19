#!/usr/bin/env bash
# The commands macOS runs, and the Bash they may assume (#256, #313).
#
# The installer establishes the modern-Bash boundary for itself: the
# compatibility entry point runs under Apple's Bash 3.2 and reaches Homebrew
# Bash before scripts/install-main.sh. A stowed command is a separate execution
# surface. It is launched from a login shell, a key binding or automation, with
# whatever PATH that environment has, and nothing had established a boundary for
# it -- which is how `theme` came to enter install-selection.sh under Bash 3.2
# and fail on `declare -A` before running any of its own code.
#
# The portable entry points are a third surface, and the same thing had happened
# to them: `./doctor` is `#!/usr/bin/env bash`, which on macOS resolves to
# Apple's 3.2 whenever Homebrew is not ahead of /bin on PATH -- precisely the
# broken PATH docs/troubleshooting.md sends the user to `./doctor` to diagnose.
# So this file audits two input sets, both derived rather than listed: the
# commands macOS puts on a user's PATH, and the entry points the repository
# documents as portable.
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

# --- The first input set: the commands macOS puts on a user's PATH ------------

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

# Each command is one of three things, and the classification is enforced rather
# than recorded: either it never loads a modern-Bash library and is safe under
# Apple's Bash as it stands, or it selects a supported Bash before the first
# such load, or it refuses under an old one before that load and names the way
# forward. Making every shared script 3.2-compatible is explicitly not the goal;
# the baseline stays where it is.
#
# classify_command <path>: prints the category, or explains the violation and
# returns 1. Taking a path rather than reading the tree directly is what lets
# the fixtures below prove it can actually refuse.
classify_command() {
  local command_path="$1"
  local name first_library guard refusal construct
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
  if [[ -n "$guard" ]] && ((guard < first_library)); then
    printf 'selects a supported Bash before loading any shared library\n'
    return 0
  fi

  # Category 3: the boundary declared rather than crossed. scripts/install-main.sh
  # is deliberately not re-executed -- installing an interpreter is the macOS
  # compatibility bootstrap's job, with the user's consent -- so it checks
  # BASH_VERSINFO itself and exits, naming the bootstrap. That is a complete
  # answer as long as it happens before the first library load, because the
  # user then reads a sentence instead of `declare: -A: invalid option`.
  # Comments are blanked first, so a file that merely mentions the variable in
  # prose does not count as having checked it; sed keeps the line numbering.
  refusal="$(
    sed -e 's/^[[:space:]]*#.*$//' "$command_path" |
      grep -n 'BASH_VERSINFO' | head -n 1 | cut -d: -f1 || true
  )"
  if [[ -n "$refusal" ]] && ((refusal < first_library)); then
    printf 'refuses under an unsupported Bash before loading any shared library\n'
    return 0
  fi

  if [[ -n "$guard" ]]; then
    printf '%s selects its Bash at line %s, after loading a library at line %s\n' \
      "$name" "$guard" "$first_library" >&2
    return 1
  fi
  if [[ -n "$refusal" ]]; then
    printf '%s checks its Bash version at line %s, after loading a library at line %s\n' \
      "$name" "$refusal" "$first_library" >&2
    return 1
  fi
  printf '%s loads a shared library at line %s without selecting a supported Bash;\n' \
    "$name" "$first_library" >&2
  printf 'source common/lib/modern-bash.sh and call modern_bash_reexec first.\n' >&2
  return 1
}

audited=0
while IFS= read -r command_path; do
  [[ -n "$command_path" ]] || continue
  category="$(classify_command "$command_path")" || exit 1
  printf 'PASS: %s %s\n' "$(basename "$command_path")" "$category"
  audited=$((audited + 1))
done <<<"$commands"
printf 'PASS: every macOS command on the stowed PATH is audited (%d)\n' "$audited"

# --- The second input set: the portable entry points --------------------------
#
# The documented way in is a surface too, and a user reaches it with whatever
# PATH they have. The set is read rather than listed, from two sources that each
# close a hole the other leaves:
#
#   - the "Portable entry point" row of
#     docs/architecture/repository-conventions.md, which is what the
#     documentation promises works on every supported platform;
#   - every root-level public-entrypoint row of config/shell-file-roles.tsv,
#     which is the authoritative role inventory that document points at. A new
#     `./something` at the repository root therefore joins this audit when it is
#     given its role, not when someone remembers this file.
#
# The documented names are then required to carry that role, so the reading aid
# cannot quietly name something the inventory no longer calls an entry point.
#
# Where that line falls is deliberate. The role is also held by developer tools
# that live deeper in the tree (scripts/benchmark-shell-startup.sh,
# docs/cheatsheets/verify.sh), which are not what a macOS user is sent to when
# their PATH is wrong and which would need their own change; this audit covers
# the documented way in. Adding one of them to the "Portable entry point" row,
# or adding any new entry point at the repository root, brings it in here.
conventions="$repo_root/docs/architecture/repository-conventions.md"
roles="$repo_root/config/shell-file-roles.tsv"

documented_entrypoints="$(
  grep '^| \*\*Portable entry point\*\*' "$conventions" |
    grep -o '`\./[^`]*`' | tr -d '`' | sed 's|^\./||' | sort -u
)"
[[ -n "$documented_entrypoints" ]] ||
  { printf 'No portable entry points found in %s; the audit proves nothing\n' "$conventions" >&2; exit 1; }

public_entrypoints="$(
  awk -F'\t' 'NR > 1 && $1 == "public-entrypoint" { print $3 }' "$roles" | sort -u
)"
while IFS= read -r documented; do
  [[ -n "$documented" ]] || continue
  printf '%s\n' "$public_entrypoints" | grep -Fqx -- "$documented" || {
    printf 'repository-conventions.md calls %s a portable entry point, but\n' "$documented" >&2
    printf 'config/shell-file-roles.tsv does not give it the public-entrypoint role\n' >&2
    exit 1
  }
done <<<"$documented_entrypoints"

root_entrypoints="$(
  awk -F'\t' 'NR > 1 && $1 == "public-entrypoint" && $3 !~ "/" { print $3 }' "$roles" | sort -u
)"

# A Bash program is what this audit is about; the Python and PowerShell entry
# points carry the same role and answer to their own runtimes. The shebang
# decides, so nothing here depends on a file extension `doctor` does not have.
entrypoints=""
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] || continue
  [[ -f "$repo_root/$candidate" ]] || {
    printf '%s is listed as a portable entry point but does not exist\n' "$candidate" >&2
    exit 1
  }
  head -n 1 "$repo_root/$candidate" | grep -q 'bash' || continue
  entrypoints="$entrypoints$candidate"$'\n'
done <<<"$(printf '%s\n%s\n' "$documented_entrypoints" "$root_entrypoints" | sed '/^$/d' | sort -u)"
[[ -n "$entrypoints" ]] ||
  { printf 'No portable Bash entry points found; the audit proves nothing\n' >&2; exit 1; }

# An entry point that is a thin wrapper moves the problem one process along
# rather than answering it: `./doctor` is four lines whose last is an exec of
# scripts/doctor.sh, and it was scripts/doctor.sh that died on `declare -A`. So
# the chain of repository scripts each entry point can exec is audited with it.
# Only a literal "$repo_root/..." target is followed; a path built from a
# variable (platforms/$platform/install.sh) names a platform entry point, which
# is a different surface with its own platform bootstrap.
exec_targets() {
  grep '^[[:space:]]*exec ' "$repo_root/$1" |
    grep -o '\$repo_root/[A-Za-z0-9_./-]*' | sed 's|^\$repo_root/||' | sort -u
}

# A worklist rather than a recursion, and a plain newline-separated string
# rather than an array, because this file stays in the 3.2 dialect. Command
# substitution strips the trailing newline, so every rewrite of the list puts
# one back and drops the blank line an empty list would otherwise contribute.
pending="$(printf '%s' "$entrypoints" | sed '/^$/d')"
chain=""
while [[ -n "$pending" ]]; do
  current="$(printf '%s\n' "$pending" | head -n 1)"
  pending="$(printf '%s\n' "$pending" | sed '1d')"
  if printf '%s\n' "$chain" | grep -Fqx -- "$current"; then
    continue
  fi
  chain="$chain$current"$'\n'
  while IFS= read -r target; do
    [[ -n "$target" && -f "$repo_root/$target" ]] || continue
    pending="$(printf '%s\n%s\n' "$pending" "$target" | sed '/^$/d')"
  done <<<"$(exec_targets "$current")"
done

audited=0
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  category="$(classify_command "$repo_root/$entry")" || exit 1
  printf 'PASS: %s %s\n' "$entry" "$category"
  audited=$((audited + 1))
done <<<"$chain"
printf 'PASS: every portable entry point, and what it execs, is audited (%d)\n' "$audited"

# The set must actually contain the entry points the defect was found in, or a
# derivation that quietly produced nothing would look like a clean audit.
for required in doctor scripts/doctor.sh scripts/lint.sh scripts/test.sh install.sh; do
  printf '%s' "$chain" | grep -Fqx -- "$required" || {
    printf 'The derived entry-point set does not contain %s\n' "$required" >&2
    printf 'audited:\n%s\n' "$chain" >&2
    exit 1
  }
done
printf 'PASS: the derived set contains the documented entry points and their implementations\n'

# The classification must be able to refuse, or the audits above say nothing.
# One fixture per way a command can be wrong, and one for the category the
# installer relies on, so "refuses before the library load" cannot decay into
# "mentions BASH_VERSINFO somewhere".
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

cat >"$fixtures/late-refusal" <<'EOF_LATE_REFUSAL'
#!/usr/bin/env bash
source "$repo_root/common/lib/install-lifecycle.sh"
if ((BASH_VERSINFO[0] < 4)); then
  exit 2
fi
EOF_LATE_REFUSAL
! classify_command "$fixtures/late-refusal" >/dev/null 2>&1 ||
  { printf 'A command checking its Bash version after the library load was accepted\n' >&2; exit 1; }
printf 'PASS: a command that checks its Bash version too late is refused\n'

cat >"$fixtures/mentions-versinfo" <<'EOF_MENTIONS'
#!/usr/bin/env bash
# This one only talks about BASH_VERSINFO; it never looks at it.
source "$repo_root/common/lib/install-lifecycle.sh"
EOF_MENTIONS
! classify_command "$fixtures/mentions-versinfo" >/dev/null 2>&1 ||
  { printf 'A command merely mentioning BASH_VERSINFO in a comment was accepted\n' >&2; exit 1; }
printf 'PASS: a comment mentioning BASH_VERSINFO does not count as a check\n'

cat >"$fixtures/early-refusal" <<'EOF_EARLY_REFUSAL'
#!/usr/bin/env bash
if ((BASH_VERSINFO[0] < 4)); then
  printf 'ERROR: this needs Bash 4.4 or newer; start through ./install.sh --platform macos\n' >&2
  exit 2
fi
source "$repo_root/common/lib/install-lifecycle.sh"
EOF_EARLY_REFUSAL
classify_command "$fixtures/early-refusal" >/dev/null 2>&1 ||
  { printf 'A command refusing before its library load was rejected\n' >&2; exit 1; }
printf 'PASS: a command that refuses before loading a library is accepted\n'

# --- `./install.sh doctor`, however the platform is spelled -------------------
#
# `doctor` is a subcommand, and it used to be reachable only as the first
# argument of scripts/install-main.sh. On macOS that made it unreachable twice
# over: `./install.sh doctor` names no platform, so it went to install-main.sh
# under Apple's Bash and hit that file's refusal, and the form the refusal
# recommends -- `./install.sh --platform macos doctor` -- was parsed as a
# platform option and answered `Unknown option for macos: doctor`. Every
# implemented platform is asserted, so fedora and parrot-ctf cannot drift apart
# from macos. The report is read-only, and HOME is a test root, so no platform
# selector here can install anything.
doctor_home="$root/doctor-home"
mkdir -p "$doctor_home"

assert_reaches_doctor() {
  local description="$1"
  shift
  local output
  output="$(
    env HOME="$doctor_home" XDG_CONFIG_HOME="$doctor_home/config" \
      XDG_STATE_HOME="$doctor_home/state" XDG_DATA_HOME="$doctor_home/data" \
      "$repo_root/install.sh" "$@" 2>&1
  )" || {
    printf '%s did not succeed:\n%s\n' "$description" "$output" >&2
    exit 1
  }
  grep -Fq 'Dotfiles doctor (read-only)' <<<"$output" || {
    printf '%s did not reach the doctor:\n%s\n' "$description" "$output" >&2
    exit 1
  }
  grep -Fq 'No changes made.' <<<"$output" || {
    printf '%s did not finish the report:\n%s\n' "$description" "$output" >&2
    exit 1
  }
  printf 'PASS: %s reaches the doctor\n' "$description"
}

assert_reaches_doctor './install.sh doctor' doctor

platform_names="$(
  awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) column[$i] = i; next }
   $column["capability"] == "base" && $column["status"] == "implemented" { print $column["platform"] }' \
    "$repo_root/config/capabilities.tsv" | sort -u
)"
[[ -n "$platform_names" ]] ||
  { printf 'No implemented platforms found; the subcommand cases prove nothing\n' >&2; exit 1; }
while IFS= read -r platform_name; do
  [[ -n "$platform_name" ]] || continue
  assert_reaches_doctor \
    "./install.sh --platform $platform_name doctor" --platform "$platform_name" doctor
  assert_reaches_doctor \
    "./install.sh --platform=$platform_name doctor" "--platform=$platform_name" doctor
done <<<"$platform_names"

# The selector still names a platform when it is followed by one, so a platform
# called `doctor` is reported as unsupported rather than silently running the
# report.
output="$(
  env HOME="$doctor_home" XDG_CONFIG_HOME="$doctor_home/config" \
    XDG_STATE_HOME="$doctor_home/state" XDG_DATA_HOME="$doctor_home/data" \
    "$repo_root/install.sh" --platform doctor 2>&1 || true
)"
grep -Fq 'Unsupported platform: doctor' <<<"$output" || {
  printf '--platform doctor was not treated as a platform name:\n%s\n' "$output" >&2
  exit 1
}
printf 'PASS: --platform doctor still names a platform\n'

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

  # PATH is not the only way to a supported Bash, and it must not be: a
  # launcher, a cron entry or an automation environment can hand the command a
  # PATH with no Homebrew on it at all. The absolute prefixes the library probes
  # are what make that case work, so this drops Homebrew from PATH entirely and
  # asserts the command still runs. DOTFILES_MODERN_BASH is deliberately pointed
  # at Apple's 3.2 as well, so nothing but those prefixes can supply the answer.
  #
  # The refusal when no supported Bash exists anywhere cannot be staged here,
  # because /opt/homebrew/bin/bash is a real file on this machine and the probe
  # is an absolute path; tests/test-theme.sh drives the library directly with
  # the prefixes pointed at a 3.2 tree and covers it there.
  output="$(
    env PATH="/bin:/usr/bin" \
      HOME="$root/home" XDG_CONFIG_HOME="$root/xdg" \
      XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/home/.local/share" \
      DOTFILES_MODERN_BASH="$system_bash" \
      "$stowed_bin/theme" --help 2>&1 || true
  )"
  grep -Fq 'Usage: theme' <<<"$output" || {
    printf 'theme did not run with Homebrew off PATH:\n%s\n' "$output" >&2
    exit 1
  }
  ! grep -Fq 'declare' <<<"$output" || {
    printf 'A declare error reached the user:\n%s\n' "$output" >&2
    exit 1
  }
  printf 'PASS: theme reaches a supported Bash with Homebrew off PATH\n'

  # The entry points, on the same system-Bash-first PATH. This is the situation
  # docs/troubleshooting.md describes and then answers with `./doctor`, so it is
  # run here for real rather than modelled: `./doctor` used to die on
  # `declare: -A: invalid option` before printing anything, and `./install.sh
  # doctor` never reached the report at all.
  entrypoint_under_apple_bash() {
    local description="$1"
    local expected="$2"
    shift 2
    local output
    output="$(
      env PATH="/bin:/usr/bin:/opt/homebrew/bin" \
        HOME="$doctor_home" XDG_CONFIG_HOME="$doctor_home/config" \
        XDG_STATE_HOME="$doctor_home/state" XDG_DATA_HOME="$doctor_home/data" \
        DOTFILES_BOOTSTRAP_TRACE=true "$@" 2>&1
    )" || {
      printf '%s failed under a system-Bash-first PATH:\n%s\n' "$description" "$output" >&2
      exit 1
    }
    grep -Fq "$expected" <<<"$output" || {
      printf '%s did not run under a system-Bash-first PATH:\n%s\n' "$description" "$output" >&2
      exit 1
    }
    ! grep -Fq 'declare' <<<"$output" || {
      printf '%s reached a modern-Bash library under Apple Bash:\n%s\n' "$description" "$output" >&2
      exit 1
    }
    grep -Fq 're-executing with' <<<"$output" || {
      printf '%s did not re-exec although the system Bash is 3.2:\n%s\n' "$description" "$output" >&2
      exit 1
    }
    printf 'PASS: %s runs under a real Apple Bash on a system-Bash-first PATH\n' "$description"
  }

  entrypoint_under_apple_bash './doctor' 'Dotfiles doctor (read-only)' \
    "$repo_root/doctor"
  entrypoint_under_apple_bash './install.sh doctor' 'Dotfiles doctor (read-only)' \
    "$repo_root/install.sh" doctor
  entrypoint_under_apple_bash './install.sh --platform macos doctor' \
    'Dotfiles doctor (read-only)' "$repo_root/install.sh" --platform macos doctor
  entrypoint_under_apple_bash './scripts/test.sh --help' 'Usage: ./scripts/test.sh' \
    "$repo_root/scripts/test.sh" --help
else
  # What this run does and does not prove: the audit above is complete and
  # exact, and tests/test-theme.sh drives the selection library itself. The
  # direct invocation under a real Apple Bash is the one thing that needs a
  # macOS runner, where the workflow's system-Bash step runs this same file
  # under /bin/bash.
  printf 'NOTE: /bin/bash here is Bash %s, not Apple 3.2, so the direct\n' \
    "$("$system_bash" -c 'printf "%s" "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
  printf '      invocation cases are exercised on the macOS runner instead.\n'

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
