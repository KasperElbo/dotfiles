#!/usr/bin/env bash
set -euo pipefail

# The Fedora installers on a minimal image (common/lib/base-bootstrap.sh).
#
# A fresh Fedora WSL distro has no awk, and ./install.sh died reading its own
# package list with "awk: command not found" before it could install gawk.
# This drives the real entry points on a machine that has the bootstrap
# prerequisites of config/command-providers.tsv and nothing else the installer
# could install, and requires each to reach its base package transaction.
#
# The machine is exact, not merely small. Its PATH holds:
#   - bash, and stubs for the other bootstrap prerequisites (sudo, dnf, rpm,
#     curl) that log every call and refuse any they do not expect, plus the
#     real git, which the lifecycle record reads;
#   - the commands a Fedora system has without this installer's help and that
#     no installer step provides (getent, and wslpath or systemctl), as
#     tripwires: present, so preflight finds them, and failing the case if
#     anything runs one before the base package step.
# `sudo dnf install -y` of packages the image lacks "installs" them: each
# bootstrap-package command of that provider becomes the host's real command,
# and each other command it provides becomes a tripwire. So the case fails if
# the installer runs, before its base package step, any command that is not a
# bootstrap prerequisite or a bootstrap package -- a supported-base command, or
# one config/command-providers.tsv does not list at all.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"
manifest="$repo_root/config/command-providers.tsv"

# Host tools the fixture itself uses, resolved before any PATH is narrowed.
host_ln="$(type -P ln)"
host_git="$(type -P git)"

# The image's own commands besides the prerequisites, by platform.
image_commands() {
  case "$1" in
  fedora) printf '%s\n' getent systemctl ;;
  fedora-wsl) printf '%s\n' getent wslpath ;;
  esac
}

# registry_rows <platform>: command<TAB>provider<TAB>classification.
registry_rows() {
  awk -F '\t' -v p="$1" 'NR > 1 && $1 == p { print $2 "\t" $3 "\t" $6 }' "$manifest"
}

write_tripwire() {
  printf '#!%s\nprintf "TRIPWIRE %%s %%s\\n" %q "$*" >>%q\nexit 95\n' \
    "$BASH" "$1" "$fixture/calls.log" >"$2"
  chmod +x "$2"
}

# The host command a bootstrap package provides, with the two that would
# answer about the machine running the tests replaced: id, because the suite
# may run as root and the installer refuses root, and df, whose free space
# belongs to the host.
write_installed() {
  local command="$1" target="$2"
  case "$command" in
  id)
    printf '#!%s\ncase "${1:-}" in -u) printf "1000\\n" ;; -un) printf "tester\\n" ;; *) exit 95 ;; esac\n' \
      "$BASH" >"$target"
    chmod +x "$target"
    ;;
  df) test_stub_roomy_df "${target%/*}" ;;
  *) "$host_ln" -s "$(type -P "$command")" "$target" ;;
  esac
}

# minimal_image <platform> <name>: a fresh fixture in $fixture, its PATH
# directory in $fixture/bin and each installable package's commands staged
# under $fixture/repo/<provider>/.
minimal_image() {
  local platform="$1" command provider classification image
  fixture="$test_root/$2"
  mkdir -p "$fixture/bin" "$fixture/repo" "$fixture/home" "$fixture/state"
  : >"$fixture/calls.log"
  image=" $(image_commands "$platform" | tr '\n' ' ') "
  "$host_ln" -s "$BASH" "$fixture/bin/bash"
  "$host_ln" -s "$host_git" "$fixture/bin/git"
  printf 'ID=fedora\n' >"$fixture/os-release"

  while IFS=$'\t' read -r command provider classification; do
    if [[ "$classification" == bootstrap-prerequisite ]]; then
      continue
    elif [[ "$image" == *" $command "* ]]; then
      write_tripwire "$command" "$fixture/bin/$command"
    elif [[ "$classification" == bootstrap-package ]]; then
      mkdir -p "$fixture/repo/$provider"
      write_installed "$command" "$fixture/repo/$provider/$command"
    elif [[ "$classification" == supported-base ]]; then
      mkdir -p "$fixture/repo/$provider"
      write_tripwire "$command" "$fixture/repo/$provider/$command"
    fi
  done < <(registry_rows "$platform")

  # sudo is the one way anything is installed. The bootstrap's transaction
  # names only packages staged above; any other dnf install is the base package
  # step, where the case ends with a status nothing else produces.
  cat >"$fixture/bin/sudo" <<EOF
#!$BASH
printf 'sudo %s\n' "\$*" >>'$fixture/calls.log'
case "\$*" in
'-v') exit 0 ;;
'-n -v') [[ "\${SUDO_NOAUTH:-}" != true ]]; exit ;;
esac
[[ "\$1 \$2 \$3" == 'dnf install -y' ]] || { printf 'unexpected sudo call\n' >&2; exit 96; }
shift 3
for package in "\$@"; do
  [[ -d '$fixture/repo/'"\$package" ]] || { printf 'BASE INSTALL REACHED\n' >>'$fixture/calls.log'; exit 97; }
done
[[ "\${DNF_INSTALLS_NOTHING:-}" == true ]] && exit 0
for package in "\$@"; do
  for installed in '$fixture/repo/'"\$package"/*; do
    '$host_ln' -s "\$installed" '$fixture/bin/'"\${installed##*/}"
  done
done
EOF
  local stub
  for stub in dnf rpm; do
    printf '#!%s\nprintf "%s %%s\\n" "$*" >>%q\nexit 96\n' \
      "$BASH" "$stub" "$fixture/calls.log" >"$fixture/bin/$stub"
  done
  # The network preflight probes with curl --head; nothing else may fetch.
  printf '#!%s\nprintf "curl %%s\\n" "$*" >>%q\n[[ " $* " == *" --head "* ]] || exit 96\n' \
    "$BASH" "$fixture/calls.log" >"$fixture/bin/curl"
  chmod +x "$fixture/bin"/*
}

# run_minimal <entry> [argument]...: the entry point on the fixture's PATH
# alone, with an environment as bare as a first login's. Standard input is the
# caller's, so an interactive case can answer the prompts.
run_minimal() {
  local entry="$1"
  shift
  run_capture env -i HOME="$fixture/home" PATH="$fixture/bin" TERM=dumb LANG=C \
    USER=tester LOGNAME=tester XDG_STATE_HOME="$fixture/state" \
    OS_RELEASE_FILE="$fixture/os-release" WSL_DISTRO_NAME=FedoraLinux \
    SUDO_NOAUTH="${SUDO_NOAUTH:-}" DNF_INSTALLS_NOTHING="${DNF_INSTALLS_NOTHING:-}" \
    "$BASH" "$repo_root/$entry" "$@"
}

calls() { cat "$fixture/calls.log"; }

# assert_reached_base <bootstrap packages>: the bootstrap installed exactly
# those packages, with nothing before it but sudo's own check, and the run then
# went on to the base package step without running anything it has no row for.
assert_reached_base() {
  local expected="sudo dnf install -y $1" log line
  log="$(calls)"
  # First, so a failure names the command rather than only a status.
  [[ "$log" != *TRIPWIRE* ]] ||
    _test_die "a command with no bootstrap row ran before the base package step; classify it bootstrap-package in config/command-providers.tsv or stop using it there:\n$log"
  assert_not_contains "$TEST_OUTPUT" 'command not found'
  assert_status 97
  assert_contains "$log" 'BASE INSTALL REACHED'
  while IFS= read -r line; do
    [[ "$line" != "$expected" ]] || return 0
    [[ "$line" == 'sudo -n -v' ]] ||
      _test_die "'$line' ran before the bootstrap transaction:\n$log"
  done <<<"$log"
  _test_die "the bootstrap never ran '$expected':\n$log"
}

# preinstall <platform> <provider>: the image already has that package, so
# every command of it is the real one, whatever its class.
preinstall() {
  local command provider classification
  while IFS=$'\t' read -r command provider classification; do
    [[ "$provider" != "$2" ]] || write_installed "$command" "$fixture/bin/$command"
  done < <(registry_rows "$1")
}

bootstrap_packages='gawk coreutils findutils grep sed'

# The owner's report, exactly: ./install.sh --platform fedora-wsl on a clean
# Fedora WSL distro, which has coreutils, findutils, grep and sed but no gawk.
minimal_image fedora-wsl gawk-only
for provider in coreutils findutils grep sed; do preinstall fedora-wsl "$provider"; done
run_minimal install.sh --platform fedora-wsl --non-interactive
assert_reached_base gawk

# Nothing may be assumed of the image beyond the bootstrap prerequisites: with
# none of the bootstrap packages, both Fedora installers still get there.
for platform in fedora-wsl fedora; do
  minimal_image "$platform" "$platform-non-interactive"
  run_minimal install.sh --platform "$platform" --non-interactive
  assert_reached_base "$bootstrap_packages"
  printf 'PASS: %s reaches its base package step from a minimal image\n' "$platform"
done

# The platform installers are documented entry points of their own.
minimal_image fedora-wsl direct
run_minimal platforms/fedora-wsl/install.sh --non-interactive
assert_reached_base "$bootstrap_packages"

# Interactive: the bootstrap asks, then the installer asks its own question.
minimal_image fedora-wsl interactive
run_minimal install.sh --platform fedora-wsl <<<$'y\ny'
assert_reached_base "$bootstrap_packages"
assert_contains "$TEST_OUTPUT" 'Install them now? [Y/n]'
assert_contains "$TEST_OUTPUT" 'Continue with installation?'
# Asked, so sudo is not required to be cached: the transaction comes first.
assert_eq "sudo dnf install -y $bootstrap_packages" "$(head -n 1 "$fixture/calls.log")"

# --dry-run changes nothing: it shows the bootstrap's plan and stops there.
minimal_image fedora-wsl dry-run
run_minimal install.sh --platform fedora-wsl --dry-run
assert_success
assert_contains "$TEST_OUTPUT" 'Fedora base bootstrap plan'
assert_contains "$TEST_OUTPUT" "sudo dnf install -y $bootstrap_packages"
assert_contains "$TEST_OUTPUT" 'No changes were made.'
assert_file_empty "$fixture/calls.log"
[[ ! -e "$fixture/bin/awk" ]] || _test_die '--dry-run installed awk'

# A declined prompt, and a closed standard input, install nothing.
minimal_image fedora-wsl declined
run_minimal install.sh --platform fedora-wsl <<<n
assert_success
assert_contains "$TEST_OUTPUT" 'Cancelled; no changes made.'
assert_file_empty "$fixture/calls.log"
run_minimal install.sh --platform fedora-wsl </dev/null
assert_success
assert_contains "$TEST_OUTPUT" 'treating the prompt as declined'
assert_file_empty "$fixture/calls.log"

# --non-interactive never prompts, so it needs sudo already cached.
minimal_image fedora-wsl no-sudo
SUDO_NOAUTH=true run_minimal install.sh --platform fedora-wsl --non-interactive
assert_status 1
assert_contains "$TEST_OUTPUT" "requires cached sudo authorization; run 'sudo -v' first"
assert_not_contains "$(calls)" 'dnf install'

# --help changes nothing either, and says why it cannot show the help yet.
minimal_image fedora-wsl help
run_minimal install.sh --platform fedora-wsl --help
assert_status 1
assert_contains "$TEST_OUTPUT" 'Run it with --dry-run to see what the bootstrap would install'
assert_file_empty "$fixture/calls.log"

# Only on Fedora: the providers are Fedora package names.
minimal_image fedora-wsl not-fedora
printf 'ID=ubuntu\n' >"$fixture/os-release"
run_minimal install.sh --platform fedora-wsl --non-interactive
assert_status 1
assert_contains "$TEST_OUTPUT" 'This installer supports Fedora only; nothing has been installed.'
assert_not_contains "$(calls)" 'dnf install'

# A transaction that reports success without providing the commands is a
# failure, not a run that dies on the first of them further on.
minimal_image fedora-wsl installs-nothing
DNF_INSTALLS_NOTHING=true run_minimal install.sh --platform fedora-wsl --non-interactive
assert_status 1
assert_contains "$TEST_OUTPUT" 'still cannot be found on PATH'
assert_not_contains "$(calls)" 'BASE INSTALL REACHED'

# A missing prerequisite is named before anything is installed.
minimal_image fedora-wsl no-git
rm "$fixture/bin/git"
run_minimal install.sh --platform fedora-wsl --non-interactive
assert_status 1
assert_contains "$TEST_OUTPUT" 'Missing bootstrap-prerequisite command: git (provider: git)'
assert_file_empty "$fixture/calls.log"
printf 'PASS: the bootstrap honours --dry-run, --help, the prompt and sudo\n'

# On a machine that has every package the bootstrap is silent and changes
# nothing, so a full machine installs exactly as it did before it existed.
# shellcheck source=../common/lib/base-bootstrap.sh
source "$repo_root/common/lib/base-bootstrap.sh"
for platform in fedora fedora-wsl macos parrot-ctf windows; do
  run_capture base_bootstrap "$platform" --non-interactive
  assert_success
  assert_eq '' "$TEST_OUTPUT" "base_bootstrap $platform on a full machine"
done
# The manifest is read by column name, as common/lib/manifest.sh reads it.
awk -F '\t' 'BEGIN { OFS = "\t" } { t = $2; $2 = $6; $6 = t; print }' "$manifest" >"$test_root/reordered.tsv"
# On an empty PATH, too: the reader is Bash alone.
(
  PATH="$test_root/empty-path" _base_bootstrap_read "$test_root/reordered.tsv" fedora-wsl
  printf '%s\n' "${_BASE_BOOTSTRAP_PROVIDERS[*]}" "${_BASE_BOOTSTRAP_COMMANDS[gawk]}"
) >"$test_root/reordered.out"
assert_eq "$bootstrap_packages"$'\n''awk' "$(cat "$test_root/reordered.out")"
sed '1s/\tclassification$/\tclass/' "$manifest" >"$test_root/renamed.tsv"
run_capture env COMMAND_PROVIDER_MANIFEST="$test_root/renamed.tsv" \
  "$BASH" -c 'source "$1"; base_bootstrap fedora' bootstrap "$repo_root/common/lib/base-bootstrap.sh"
assert_status 1
assert_contains "$TEST_OUTPUT" 'has no column: classification'
printf 'unterminated\n' >>"$test_root/reordered.tsv"
run_capture env COMMAND_PROVIDER_MANIFEST="$test_root/reordered.tsv" \
  "$BASH" -c 'source "$1"; base_bootstrap fedora' bootstrap "$repo_root/common/lib/base-bootstrap.sh"
assert_status 1
assert_contains "$TEST_OUTPUT" '1 columns, expected 6'

# The class belongs to the dnf bootstrap: another platform may not claim it.
for platform in macos parrot-ctf; do
  cp "$manifest" "$test_root/$platform-bootstrap.tsv"
  printf '%s\tdotfiles-bootstrap-command\tsome-package\tbase\tbase\tbootstrap-package\n' \
    "$platform" >>"$test_root/$platform-bootstrap.tsv"
  run_capture env COMMAND_PROVIDER_MANIFEST="$test_root/$platform-bootstrap.tsv" \
    python3 "$repo_root/scripts/validate-command-provider-closure.py"
  assert_failure
  assert_contains "$TEST_OUTPUT" "$platform command 'dotfiles-bootstrap-command' is a bootstrap-package"
done
cp "$manifest" "$test_root/path-provider.tsv"
printf 'fedora\tdotfiles-bootstrap-command\tbin/.local/bin/theme\tbase\tbase\tbootstrap-package\n' \
  >>"$test_root/path-provider.tsv"
run_capture env COMMAND_PROVIDER_MANIFEST="$test_root/path-provider.tsv" \
  python3 "$repo_root/scripts/validate-command-provider-closure.py"
assert_failure
assert_contains "$TEST_OUTPUT" 'must be a package name the bootstrap can install'

printf 'Base bootstrap tests passed.\n'
