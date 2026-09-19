#!/usr/bin/env bash
set -euo pipefail

# The note --dry-run prints under a plan step is a promise about the command
# that step's apply function runs. This suite holds the Fedora-family
# installers to that promise end to end: a real apply runs in a scratch copy of
# the checkout whose step scripts only record how they were called, and every
# recorded command is compared with the note the same selection's dry-run
# printed. The same runs check that the lifecycle record, which ./doctor and
# --rerun read, names exactly the capabilities the run selected.
#
# The checkout itself is never modified, and nothing leaves the scratch root.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"

tree="$test_root/tree"
mkdir -p "$tree"
tar -C "$repo_root" --exclude=.git -cf - . | tar -xf - -C "$tree"

# Every script a Fedora-family step can run becomes a recorder. It appends the
# checkout-relative command to the plan log, where it lands after the plan's
# own "start id=<step>" line; before the lifecycle begins (preflight probes such
# as --preflight) there is no plan log and it records nothing.
recorder="$test_root/record-step-command"
cat >"$recorder" <<EOF
#!/usr/bin/env bash
[[ -n "\${DOTFILES_PLAN_LOG:-}" ]] || exit 0
printf 'command %s\n' "\${0#"$tree/"}\${*:+ \$*}" >>"\$DOTFILES_PLAN_LOG"
EOF
chmod +x "$recorder"
for script in "$tree"/platforms/fedora/scripts/*.sh "$tree"/platforms/fedora-wsl/scripts/*.sh \
  "$tree"/common/*.sh "$tree/scripts/test-dev-workflows.sh"; do
  cp "$recorder" "$script"
done

mock_bin="$test_root/mock-bin"
mkdir -p "$mock_bin"
test_stub_init "$test_root"
for command_name in dnf rpm sudo systemctl wslpath; do
  test_stub_install "$test_root" "$command_name"
done
test_stub_allow "$test_root" sudo -n -v
real_id="$(type -P id)"
cat >"$mock_bin/id" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in -u) printf '1000\n' ;; -un) printf 'tester\n' ;; *) exec "$real_id" "\$@" ;; esac
EOF
# The WSL containers profile requires systemd as PID 1.
cat >"$mock_bin/ps" <<'EOF'
#!/usr/bin/env bash
printf 'systemd\n'
EOF
# These scratch machines have neither Terra nor mise, so their preflight checks
# that the hosts it would download from answer. Stand in for a reachable
# network: no suite may depend on the machine running it having one.
cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# Same rule for the disk floor: the preflight arithmetic runs against a known
# figure, not against whatever this machine happens to have free.
test_stub_roomy_df "$mock_bin"
chmod +x "$mock_bin/id" "$mock_bin/ps" "$mock_bin/curl"
printf 'ID=fedora\n' >"$test_root/os-release"
# The WSL containers preflight probes the host's user bus, cgroup v2, and user
# namespaces; stand in for a capable host so the result never depends on them.
: >"$test_root/systemd-user-bus"
mkdir -p "$test_root/cgroup"
: >"$test_root/cgroup/cgroup.controllers"
printf '15000\n' >"$test_root/max-user-namespaces"
test_isolate_path getent git
PATH="$mock_bin:$TEST_STUB_ROOT/bin:$PATH"

# run_installer <home> <platform> <argument>...: the platform installer from the
# scratch checkout, in its own home, with no inherited plan log.
run_installer() {
  local home="$1" platform="$2"
  shift 2
  run_capture env -u DOTFILES_PLAN_LOG -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_DATA_HOME \
    HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" \
    XDG_DATA_HOME="$home/.local/share" XDG_CACHE_HOME="$home/.cache" \
    OS_RELEASE_FILE="$test_root/os-release" WSL_DISTRO_NAME=Fedora \
    SYSTEMD_USER_BUS_SOCKET="$test_root/systemd-user-bus" CGROUP_ROOT="$test_root/cgroup" \
    MAX_USER_NAMESPACES_FILE="$test_root/max-user-namespaces" \
    "$tree/platforms/$platform/install.sh" "$@"
}

# check_plan_commands <dry-run output> <plan log>: every step must run exactly
# the repository script and arguments its note names, and no step may run one
# its note does not name. --non-interactive is an invocation-only control the
# plan deliberately leaves out of notes, so a trailing one is ignored.
check_plan_commands() {
  local dry_run="$1" plan_log="$2" line id="" promised actual status=0
  local step_pattern='^ +[0-9]+\. \[([^]]+)\] ' note_pattern='^      (.*)$'
  local start_pattern=' start id=([^ ]+) ' script_pattern='((platforms|common|scripts)/[^;]*)'
  local -A notes=() ran=()

  while IFS= read -r line; do
    if [[ "$line" =~ $step_pattern ]]; then
      id="${BASH_REMATCH[1]}"
      notes["$id"]=""
    elif [[ -n "$id" && "$line" =~ $note_pattern ]]; then
      notes["$id"]="${BASH_REMATCH[1]}"
    fi
  done < <(sed -n '/^Resolved steps/,/^$/p' <<<"$dry_run")
  ((${#notes[@]} > 0)) || { printf 'The dry-run printed no plan steps.\n'; return 1; }

  id=""
  while IFS= read -r line; do
    if [[ "$line" =~ $start_pattern ]]; then
      id="${BASH_REMATCH[1]}"
    elif [[ "$line" == 'command '* ]]; then
      if [[ -n "${ran[$id]+set}" ]]; then
        printf 'Step [%s] ran more than one repository script: "%s", then "%s".\n' \
          "$id" "${ran[$id]}" "${line#command }"
        status=1
      fi
      ran["$id"]="${line#command }"
    fi
  done <"$plan_log"

  for id in "${!ran[@]}"; do
    [[ -n "${notes[$id]+set}" ]] || {
      printf 'Apply ran "%s" in step [%s], which the dry-run never planned.\n' "${ran[$id]}" "$id"
      status=1
    }
  done
  for id in "${!notes[@]}"; do
    promised=""
    [[ ! "${notes[$id]}" =~ $script_pattern ]] || promised="${BASH_REMATCH[1]}"
    actual="${ran[$id]-}"
    actual="${actual% --non-interactive}"
    [[ "$promised" == "$actual" ]] || {
      printf 'Step [%s] dry-run promised "%s" but apply ran "%s".\n' \
        "$id" "${promised:-no repository script}" "${actual:-no repository script}"
      status=1
    }
  done
  return "$status"
}

# assert_plan_keeps_promises <name> <platform> <expected capabilities> <argument>...
assert_plan_keeps_promises() {
  local name="$1" platform="$2" expected_capabilities="$3" home dry_run
  shift 3
  home="$test_root/homes/$name"
  mkdir -p "$home"

  run_installer "$home" "$platform" --dry-run "$@"
  assert_success
  dry_run="$TEST_OUTPUT"
  run_installer "$home" "$platform" --non-interactive "$@"
  assert_success

  run_capture check_plan_commands "$dry_run" "$home/.local/state/dotfiles/install.log"
  ((TEST_STATUS == 0)) || _test_die "$name: the dry-run and apply disagree:\n$TEST_OUTPUT"
  assert_file_line "$home/.local/state/dotfiles/install.conf" \
    "requested_capabilities=$expected_capabilities"
  printf 'PASS: %s\n' "$name"
}

assert_plan_keeps_promises fedora-every-option fedora \
  base,dotnet-debug,kde,latex,ocaml,sway,vm-host,hardware,hardening,desktop-tools,dictation,containers,tailscale,ai,codex,gnhf,backpass \
  --kde --latex --ocaml --sway --vm-host --hardware ga402xz --secure-boot --charge-limit 80 \
  --hardening --desktop-tools --desktop-tools-force-defaults --dictation --containers --containers-api-socket \
  --tailscale --ai --codex --no-firstmate --gnhf --backpass --dev-workflows
assert_plan_keeps_promises fedora-option-defaults fedora \
  base,dotnet-debug,vm-guest,desktop-tools,containers,ai,firstmate \
  --no-kde --no-latex --vm-guest --desktop-tools --containers --ai --no-codex --firstmate
assert_plan_keeps_promises fedora-wsl-every-option fedora-wsl \
  base,dotnet-debug,ocaml,latex,containers,ai,firstmate,backpass \
  --ocaml --latex --containers --containers-api-socket --ai --no-codex --firstmate --backpass \
  --dev-workflows
assert_plan_keeps_promises fedora-wsl-defaults fedora-wsl base,dotnet-debug

# Structurally, no Fedora-family apply or preflight function may call a
# repository script except through plan_command_run, which is what ties it to
# the note. The behavioural check above catches a divergence for the options it
# exercises; this catches a bypass for every option.
assert_no_direct_script_calls() {
  local installer status=0
  for installer in "$@"; do
    if grep -n '"\$DOTFILES_ROOT/' "$installer"; then
      printf '%s runs a repository script directly; state it in a *_command function and run it with plan_command_run.\n' \
        "${installer#"$tree/"}"
      status=1
    fi
  done
  return "$status"
}
run_capture assert_no_direct_script_calls \
  "$tree/platforms/fedora/install.sh" "$tree/platforms/fedora-wsl/install.sh"
assert_success

# Negative control: point apply_tailscale at another profile's script, as an
# edit that forgets the note would. Both checks must name the step.
sed -i 's|^apply_tailscale() { plan_command_run fedora_tailscale_command; }$|apply_tailscale() { "$DOTFILES_ROOT/platforms/fedora/scripts/install-containers.sh"; }|' \
  "$tree/platforms/fedora/install.sh"
grep -Fq 'install-containers.sh"; }' "$tree/platforms/fedora/install.sh" ||
  _test_die 'negative control could not rewrite apply_tailscale'
run_capture assert_no_direct_script_calls "$tree/platforms/fedora/install.sh"
assert_failure
assert_contains "$TEST_OUTPUT" 'apply_tailscale() { "$DOTFILES_ROOT/platforms/fedora/scripts/install-containers.sh"; }'
assert_contains "$TEST_OUTPUT" 'platforms/fedora/install.sh runs a repository script directly'

control_home="$test_root/homes/diverged-tailscale"
mkdir -p "$control_home"
run_installer "$control_home" fedora --dry-run --no-kde --no-latex --tailscale
assert_success
control_dry_run="$TEST_OUTPUT"
run_installer "$control_home" fedora --non-interactive --no-kde --no-latex --tailscale
assert_success
run_capture check_plan_commands "$control_dry_run" "$control_home/.local/state/dotfiles/install.log"
assert_failure
assert_contains "$TEST_OUTPUT" \
  'Step [tailscale] dry-run promised "platforms/fedora/scripts/install-tailscale.sh" but apply ran "platforms/fedora/scripts/install-containers.sh".'
printf 'PASS: a diverged apply_tailscale is reported against its dry-run note\n'

# The hardening profile is the one selected step that asks the user to agree to
# it, and the plan has no way to skip a step: asked from the step itself, a no
# could only fail the run after everything ahead of it had already been
# installed, leaving the machine changed and the installation unrecorded. So
# platforms/fedora/install.sh asks from its preflight, with
# install-hardening.sh --confirm, while the plan is still just a list. The real
# script goes back into the scratch tree for this: the answer has to travel
# through the option parser that has to keep understanding --confirm, not
# through a recorder that exits 0 whatever it is handed.
cp "$repo_root/platforms/fedora/scripts/install-hardening.sh" \
  "$tree/platforms/fedora/scripts/install-hardening.sh"
test_stub_allow "$test_root" sudo -v

declined_home="$test_root/homes/hardening-declined"
mkdir -p "$declined_home"
# Yes to the installer's own "Continue with installation?", then no to the
# hardening profile.
printf 'y\nn\n' >"$test_root/hardening-answers"
run_installer "$declined_home" fedora --no-kde --no-latex --hardening \
  <"$test_root/hardening-answers"
assert_failure
assert_contains "$TEST_OUTPUT" 'Hardening installation declined'
# install_lifecycle_begin writes install.conf and names install.log, and it
# runs only after preflight has returned. Neither exists, so the run stopped
# while nothing had been installed and nothing had been recorded.
[[ ! -e "$declined_home/.local/state/dotfiles/install.conf" ]] ||
  _test_die 'a declined hardening profile recorded an installation'
[[ ! -e "$declined_home/.local/state/dotfiles/install.log" ]] ||
  _test_die 'a declined hardening profile stopped the run only after steps had begun running'
printf 'PASS: declining the hardening profile stops the run before any step has run\n'

printf 'Installer plan-command tests passed.\n'
