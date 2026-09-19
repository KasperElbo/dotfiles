#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_isolate_path sha256sum

# install_mktemp_mock <bin>: numbered, predictable temp files under the stub
# root, so exact sudo argv contracts can name them.
install_mktemp_mock() {
  cat >"$1/mktemp" <<'EOF'
#!/usr/bin/env bash
counter_file="$TEST_STUB_ROOT/state/mktemp-counter"
counter="$(cat "$counter_file" 2>/dev/null || printf '0')"
counter=$((counter + 1))
printf '%s\n' "$counter" >"$counter_file"
if (($# == 0)); then
  path="$TEST_STUB_ROOT/state/tmp-$counter"
else
  path="${1/XXXXXX/$(printf '%06d' "$counter")}"
fi
mkdir -p "$(dirname "$path")"
: >"$path"
printf '%s\n' "$path"
EOF
  chmod +x "$1/mktemp"
}

# HARDENING_ROOT exists so a fixture, not the machine running the tests, owns
# the hardening drop-ins. Unset or empty it must leave every privileged command
# byte-for-byte what it was before the override existed. Set, every access to
# an owned drop-in (write, read, stat, remove, reload) must land under that one
# prefix, including the unprivileged reads that used to see the host's /etc.
#
# Each mode calls every owned-drop-in helper and writer once, against a sudo
# stub whose allow-list is the expected call sequence in order, then requires
# the recorded sudo log to equal that allow-list exactly.
run_root_prefix_contract() {
  local mode="$1"
  # Absent on any host, so the unprivileged branches always fall through to
  # sudo and the expected log does not depend on the machine.
  local contract_path=/etc/dotfiles-hardening-root-contract/owned.conf
  local sysctl_path=/etc/sysctl.d/90-dotfiles-hardening.conf
  local rules_path=/etc/audit/rules.d/90-dotfiles-hardening.rules
  local ssh_path=/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf

  test_new_root
  local test_root="$TEST_ROOT"
  local tmp="$test_root/state/tmp"
  local root=""
  [[ "$mode" != prefix ]] || root="$test_root/fake-root"

  test_stub_init "$test_root"
  test_stub_install "$test_root" sudo
  test_stub_install "$test_root" systemctl
  test_stub_install "$test_root" auditctl
  test_stub_allow "$test_root" systemctl is-active --quiet sshd.service
  test_stub_allow "$test_root" systemctl is-enabled --quiet auditd.service
  install_mktemp_mock "$test_root/bin"

  # The expected sequence, in call order; with root="" these are the exact
  # commands the helpers ran before HARDENING_ROOT existed.
  local expected=(
    "test -f $root$contract_path"
    "cat -- $root$contract_path"
    "stat -c %a $root$contract_path"
    "test -f $root$contract_path"
    "install -D -m 0644 -o root -g root $tmp-1 $root$contract_path"
    "test -f $root$contract_path"
    "cmp -s $tmp-2 $root$contract_path"
    "test -f $root$contract_path"
    "rm -f -- $root$contract_path"
    "test -f $root$sysctl_path"
    "install -D -m 0644 -o root -g root $tmp-3 $root$sysctl_path"
    "sysctl -p $root$sysctl_path"
    "test -f $root$rules_path"
    "test -f $root$rules_path"
    "install -D -m 0640 -o root -g root $tmp-4 $root$rules_path"
    "cat $root$rules_path"
    "augenrules --load"
    "test -f $root$ssh_path"
    "install -D -m 0644 -o root -g root $tmp-5 $root$ssh_path"
    "sshd -t"
    "systemctl reload sshd.service"
  )
  local call
  local -a call_argv
  for call in "${expected[@]}"; do
    read -r -a call_argv <<<"$call"
    test_stub_allow "$test_root" sudo "${call_argv[@]}"
  done

  # Models only file presence, so writes, cmp and removals are observable.
  cat >"$test_root/handlers/sudo" <<'EOF'
#!/usr/bin/env bash
installed="$TEST_STUB_ROOT/state/installed"
touch "$installed"
target="${*: -1}"
case "$1" in
test | stat) grep -Fxq -- "$target" "$installed" ;;
cat) grep -Fxq -- "$target" "$installed" && printf 'managed\n' ;;
install) printf '%s\n' "$target" >>"$installed" ;;
rm)
  grep -Fxv -- "$target" "$installed" >"$installed.next" || true
  mv -- "$installed.next" "$installed"
  ;;
esac
EOF
  chmod +x "$test_root/handlers/sudo"

  run_capture env PATH="$test_root/bin:$PATH" TEST_STUB_ROOT="$test_root" \
    HARDENING_ROOT="$root" CONTRACT_MODE="$mode" \
    CONTRACT_PATH="$contract_path" DOTFILES_ROOT_DIR="$repo_root" \
    bash -c '
      set -euo pipefail
      [[ "$CONTRACT_MODE" != unset ]] || unset HARDENING_ROOT
      source "$DOTFILES_ROOT_DIR/common/lib/common.sh"
      source "$DOTFILES_ROOT_DIR/platforms/fedora/lib/hardening.sh"
      managed_root_file_exists "$CONTRACT_PATH" && exit 90
      managed_root_file_read "$CONTRACT_PATH" && exit 91
      managed_root_file_mode "$CONTRACT_PATH" && exit 92
      printf "owned\n" | write_managed_root_file "$CONTRACT_PATH" 0644 contract
      printf "owned\n" | write_managed_root_file "$CONTRACT_PATH" 0644 contract
      remove_managed_root_file "$CONTRACT_PATH" contract
      apply_hardening_sysctl
      apply_auditd_rules
      apply_ssh_hardening
    '
  assert_success
  assert_files_identical "$test_root/contracts/sudo.allow" \
    "$test_root/logs/sudo.log"

  if [[ "$mode" == prefix ]]; then
    # The unprivileged branches read the prefixed file, never the host's.
    mkdir -p "$root${contract_path%/*}"
    printf 'owned\n' >"$root$contract_path"
    chmod 0640 "$root$contract_path"
    run_capture env PATH="$test_root/bin:$PATH" TEST_STUB_ROOT="$test_root" \
      HARDENING_ROOT="$root" CONTRACT_PATH="$contract_path" \
      DOTFILES_ROOT_DIR="$repo_root" \
      bash -c '
        set -euo pipefail
        source "$DOTFILES_ROOT_DIR/common/lib/common.sh"
        source "$DOTFILES_ROOT_DIR/platforms/fedora/lib/hardening.sh"
        managed_root_file_exists "$CONTRACT_PATH"
        managed_root_file_mode "$CONTRACT_PATH"
        managed_root_file_read "$CONTRACT_PATH"
      '
    assert_success
    assert_eq $'640\nowned' "$TEST_OUTPUT" \
      "[root prefix] unprivileged helper output"
    assert_files_identical "$test_root/contracts/sudo.allow" \
      "$test_root/logs/sudo.log"
  fi

  printf 'PASS: owned drop-in commands with HARDENING_ROOT %s\n' "$mode"
}

# install_date_and_restorecon_mocks <bin>: `date +%s` answers MOCK_EPOCH so the
# SELinux config backup has a predictable name; every other date call is real.
# restorecon exists so the relabel step is always taken.
install_date_and_restorecon_mocks() {
  local real_date
  real_date="$(command -v date)"
  cat >"$1/date" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == +%s ]]; then
  printf '%s\\n' "\$MOCK_EPOCH"
else
  exec $real_date "\$@"
fi
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' >"$1/restorecon"
  chmod +x "$1/date" "$1/restorecon"
}

# /etc/selinux/config is the one vendor file the profile edits in place, so
# the edit is held to more than the drop-ins: the new content is validated
# before anything changes, the previous file is kept as a timestamped backup
# (an identical one is reused, so reruns do not accumulate copies), the write
# goes through a staged sibling renamed over the original with its mode, and
# the result is read back.
run_selinux_config_contract() {
  test_new_root
  local test_root="$TEST_ROOT"
  local fake_root="$test_root/fake-root"
  local config="$fake_root/etc/selinux/config"
  local tmp="$test_root/state/tmp"
  local backup="$config.dotfiles-1700000000.bak"
  local original=$'SELINUX=permissive\nSELINUXTYPE=targeted'

  mkdir -p "${config%/*}"
  printf '%s\n' "$original" >"$config"
  chmod 0644 "$config"

  test_stub_init "$test_root"
  test_stub_install "$test_root" sudo
  install_mktemp_mock "$test_root/bin"
  install_date_and_restorecon_mocks "$test_root/bin"

  # SABOTAGE_SELINUX_WRITE models a write that did not produce the staged
  # content, which only the read-back can catch.
  cat >"$test_root/handlers/sudo" <<'EOF'
#!/usr/bin/env bash
# Called, not exec'd: `test` is a shell builtin, and the suite's isolated PATH
# has no cmp, so both are answered in Bash.
case "$1" in
restorecon) exit 0 ;;
cmp) [[ -f "$3" && -f "$4" && "$(cat -- "$3")" == "$(cat -- "$4")" ]] ;;
install) install -m "$3" "$8" "$9" ;;
mv)
  if [[ "${SABOTAGE_SELINUX_WRITE:-false}" == true ]]; then
    printf 'SELINUX=enforcing\nSELINUX=permissive\n' >"$4"
  fi
  "$@"
  ;;
*) "$@" ;;
esac
EOF
  chmod +x "$test_root/handlers/sudo"

  run_persist() {
    run_capture env PATH="$test_root/bin:$PATH" TEST_STUB_ROOT="$test_root" \
      HARDENING_ROOT="$fake_root" MOCK_EPOCH="$1" \
      SABOTAGE_SELINUX_WRITE="${2:-false}" DOTFILES_ROOT_DIR="$repo_root" \
      bash -c '
        set -euo pipefail
        source "$DOTFILES_ROOT_DIR/common/lib/common.sh"
        source "$DOTFILES_ROOT_DIR/platforms/fedora/lib/hardening.sh"
        persist_selinux_enforcing
      '
  }

  backup_count() {
    local backups=("$config".dotfiles-*.bak)
    [[ -e "${backups[0]}" ]] || backups=()
    printf '%s\n' "${#backups[@]}"
  }

  # 1. First run: the exact privileged sequence, in order.
  local expected=(
    "test -f /etc/selinux/config"
    "grep -q ^SELINUX= /etc/selinux/config"
    "cat -- /etc/selinux/config"
    "cmp -s $tmp-1 /etc/selinux/config"
    "cp -a -- /etc/selinux/config /etc/selinux/config.dotfiles-1700000000.bak"
    "stat -c %a /etc/selinux/config"
    "install -m 644 -o root -g root $tmp-1 /etc/selinux/config.dotfiles-new"
    "mv -f -- /etc/selinux/config.dotfiles-new /etc/selinux/config"
    "restorecon /etc/selinux/config"
    "cat -- /etc/selinux/config"
  )
  local call
  local -a call_argv
  for call in "${expected[@]}"; do
    read -r -a call_argv <<<"${call//\/etc\/selinux/$fake_root/etc/selinux}"
    test_stub_allow "$test_root" sudo "${call_argv[@]}"
  done

  run_persist 1700000000
  assert_success
  assert_files_identical "$test_root/contracts/sudo.allow" \
    "$test_root/logs/sudo.log"
  assert_eq $'SELINUX=enforcing\nSELINUXTYPE=targeted' "$(cat "$config")" \
    '[selinux config] rewritten content'
  assert_eq "$original" "$(cat "$backup")" '[selinux config] backup content'
  assert_eq 644 "$(stat -c '%a' "$config")" '[selinux config] preserved mode'
  assert_contains "$TEST_OUTPUT" "Persisted SELINUX=enforcing in $config (backup: $backup)"

  # Later runs may also compare against the backup and stage further temp
  # files, but never create a second backup: no other cp is allowed.
  local n
  test_stub_allow "$test_root" sudo cmp -s "$backup" "$config"
  for n in 2 3 4 5; do
    test_stub_allow "$test_root" sudo cmp -s "$tmp-$n" "$config"
    test_stub_allow "$test_root" sudo install -m 644 -o root -g root \
      "$tmp-$n" "$config.dotfiles-new"
  done

  # 2. An unchanged rerun changes nothing.
  run_persist 1700000100
  assert_success
  assert_contains "$TEST_OUTPUT" 'SELINUX=enforcing is already persisted'
  assert_eq 1 "$(backup_count)" '[selinux config] backups after a rerun'

  # 3. Reverted to the backed-up content: rewritten, identical backup reused.
  printf '%s\n' "$original" >"$config"
  run_persist 1700000100
  assert_success
  assert_contains "$TEST_OUTPUT" "Reusing the identical backup of $config: $backup"
  assert_file_line "$config" 'SELINUX=enforcing'
  assert_eq 1 "$(backup_count)" '[selinux config] backups after a reused backup'

  # 4. Sabotage: a write that leaves two SELINUX= lines fails the read-back
  #    and names the adjacent backup to restore.
  printf '%s\n' "$original" >"$config"
  run_persist 1700000100 true
  assert_failure
  assert_contains "$TEST_OUTPUT" \
    "$config does not contain exactly one SELINUX=enforcing line after the rewrite"
  assert_contains "$TEST_OUTPUT" "sudo cp -a $backup $config"
  assert_eq "$original" "$(cat "$backup")" '[selinux config] backup after sabotage'

  # 5. A file with more than one SELINUX= line is refused before any backup
  #    or write.
  printf 'SELINUX=permissive\nSELINUX=disabled\n' >"$config"
  run_persist 1700000100
  assert_failure
  assert_contains "$TEST_OUTPUT" "Refusing to rewrite $config: it has more than one SELINUX= line"
  assert_eq $'SELINUX=permissive\nSELINUX=disabled' "$(cat "$config")" \
    '[selinux config] refused file is unchanged'
  assert_eq 1 "$(backup_count)" '[selinux config] backups after a refusal'

  # With HARDENING_ROOT unset the path is the real /etc/selinux/config. The
  # stub reports it absent, so the host file is never read.
  test_new_root
  test_root="$TEST_ROOT"
  test_stub_init "$test_root"
  test_stub_install "$test_root" sudo
  test_stub_allow "$test_root" sudo test -f /etc/selinux/config
  printf '#!/usr/bin/env bash\nexit 1\n' >"$test_root/handlers/sudo"
  chmod +x "$test_root/handlers/sudo"
  run_capture env PATH="$test_root/bin:$PATH" TEST_STUB_ROOT="$test_root" \
    DOTFILES_ROOT_DIR="$repo_root" \
    bash -c '
      set -euo pipefail
      unset HARDENING_ROOT
      source "$DOTFILES_ROOT_DIR/common/lib/common.sh"
      source "$DOTFILES_ROOT_DIR/platforms/fedora/lib/hardening.sh"
      persist_selinux_enforcing
    '
  assert_success
  assert_contains "$TEST_OUTPUT" '/etc/selinux/config has no SELINUX= line'
  assert_files_identical "$test_root/contracts/sudo.allow" \
    "$test_root/logs/sudo.log"

  printf 'PASS: the SELinux config edit is backed up, idempotent, and read back\n'
}

run_scenario() {
  local scenario_name="$1"
  local seed_sshd="$2"

  test_new_root
  local test_root="$TEST_ROOT"
  local mock_bin="$test_root/bin"
  local command_log="$test_root/commands.log"
  local fake_root="$test_root/fake-root"
  local selinux_state="$test_root/state/selinux"
  local active_units="$test_root/state/active-units"
  local enabled_units="$test_root/state/enabled-units"
  local sysctl_kv="$test_root/state/sysctl.kv"
  local selinux_fs_root="$test_root/selinux-fs"

  mkdir -p "$fake_root/etc/selinux" "$selinux_fs_root"
  : >"$command_log"
  : >"$active_units"
  : >"$enabled_units"
  : >"$sysctl_kv"
  printf 'Permissive\n' >"$selinux_state"
  printf 'SELINUX=permissive\nSELINUXTYPE=targeted\n' >"$fake_root/etc/selinux/config"
  chmod 0644 "$fake_root/etc/selinux/config"
  printf 'firewalld.service\n' >>"$active_units"
  printf 'firewalld.service\n' >>"$enabled_units"

  if [[ "$seed_sshd" == "true" ]]; then
    printf 'sshd.service\n' >>"$active_units"
    printf 'sshd.service\n' >>"$enabled_units"
  fi

  # Package-manager calls use the shared exact-argv stub. The scenario keeps
  # stateful security/service commands local because they model Fedora state.
  # HARDENING_ROOT puts every owned drop-in under the fake root, so those
  # allow-list entries name fake-root paths; any access that skipped the
  # prefix would hit the real /etc and be rejected here.
  test_stub_init "$test_root"
  test_stub_install "$test_root" dnf
  test_stub_install "$test_root" sudo
  test_stub_install "$test_root" systemctl
  test_stub_allow "$test_root" dnf install -y dnf5-plugin-automatic
  test_stub_allow "$test_root" sudo setenforce 1
  local selinux_config="$fake_root/etc/selinux/config"
  test_stub_allow "$test_root" sudo test -f "$selinux_config"
  test_stub_allow "$test_root" sudo grep -q '^SELINUX=' "$selinux_config"
  test_stub_allow "$test_root" sudo cat -- "$selinux_config"
  test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-1" "$selinux_config"
  test_stub_allow "$test_root" sudo cp -a -- "$selinux_config" \
    "$selinux_config.dotfiles-1700000000.bak"
  test_stub_allow "$test_root" sudo stat -c '%a' "$selinux_config"
  test_stub_allow "$test_root" sudo install -m 644 -o root -g root \
    "$test_root/state/tmp-1" "$selinux_config.dotfiles-new"
  test_stub_allow "$test_root" sudo mv -f -- "$selinux_config.dotfiles-new" \
    "$selinux_config"
  test_stub_allow "$test_root" sudo restorecon "$selinux_config"
  test_stub_allow "$test_root" sudo authselect enable-feature with-faillock
  test_stub_allow "$test_root" sudo dnf install -y dnf5-plugin-automatic
  test_stub_allow "$test_root" sudo test -f \
    "$fake_root"/etc/security/faillock.conf.d/90-dotfiles-hardening.conf
  test_stub_allow "$test_root" sudo test -f \
    "$fake_root"/etc/sudoers.d/90-dotfiles-hardening
  test_stub_allow "$test_root" sudo test -f \
    "$fake_root"/etc/audit/rules.d/90-dotfiles-hardening.rules
  test_stub_allow "$test_root" sudo test -f \
    "$fake_root"/etc/sysctl.d/90-dotfiles-hardening.conf
  test_stub_allow "$test_root" sudo cat \
    "$fake_root"/etc/audit/rules.d/90-dotfiles-hardening.rules
  test_stub_allow "$test_root" sudo sysctl -p \
    "$fake_root"/etc/sysctl.d/90-dotfiles-hardening.conf
  test_stub_allow "$test_root" sudo auditctl -l
  # Verification reads owned drop-ins it cannot see unprivileged. These are
  # reads and stats only; no write form of sudo is ever allowed here.
  for owned_path in \
    /etc/security/faillock.conf.d/90-dotfiles-hardening.conf \
    /etc/sudoers.d/90-dotfiles-hardening \
    /etc/audit/rules.d/90-dotfiles-hardening.rules \
    /etc/sysctl.d/90-dotfiles-hardening.conf \
    /etc/ssh/sshd_config.d/90-dotfiles-hardening.conf; do
    test_stub_allow "$test_root" sudo stat -c '%a' "$fake_root$owned_path"
    test_stub_allow "$test_root" sudo cat -- "$fake_root$owned_path"
    test_stub_allow "$test_root" sudo test -f "$fake_root$owned_path"
  done
  test_stub_allow "$test_root" sudo systemctl enable --now auditd.service
  test_stub_allow "$test_root" sudo systemctl enable --now dnf5-automatic.timer

  test_stub_allow "$test_root" sudo install -D -m 0644 -o root -g root \
    "$test_root/state/tmp-2" \
    "$fake_root"/etc/security/faillock.conf.d/90-dotfiles-hardening.conf
  test_stub_allow "$test_root" sudo install -D -m 0440 -o root -g root \
    "$test_root/state/tmp-4" "$fake_root"/etc/sudoers.d/90-dotfiles-hardening
  test_stub_allow "$test_root" sudo install -D -m 0640 -o root -g root \
    "$test_root/state/tmp-5" "$fake_root"/etc/audit/rules.d/90-dotfiles-hardening.rules
  test_stub_allow "$test_root" sudo install -D -m 0644 -o root -g root \
    "$test_root/state/tmp-6" "$fake_root"/etc/sysctl.d/90-dotfiles-hardening.conf

  if [[ "$seed_sshd" == "true" ]]; then
    test_stub_allow "$test_root" sudo test -f \
      "$fake_root"/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo install -D -m 0644 -o root -g root \
      "$test_root/state/tmp-7" \
      "$fake_root"/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-10" \
      "$fake_root"/etc/security/faillock.conf.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-12" \
      "$fake_root"/etc/sudoers.d/90-dotfiles-hardening
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-13" \
      "$fake_root"/etc/audit/rules.d/90-dotfiles-hardening.rules
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-14" \
      "$fake_root"/etc/sysctl.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-15" \
      "$fake_root"/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo sshd -t
    test_stub_allow "$test_root" sudo systemctl reload sshd.service
    test_stub_allow "$test_root" sudo grep -Fqx 'PermitRootLogin no' \
      "$fake_root"/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo grep -Fqx 'MaxAuthTries 3' \
      "$fake_root"/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf
  else
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-9" \
      "$fake_root"/etc/security/faillock.conf.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-11" \
      "$fake_root"/etc/sudoers.d/90-dotfiles-hardening
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-12" \
      "$fake_root"/etc/audit/rules.d/90-dotfiles-hardening.rules
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-13" \
      "$fake_root"/etc/sysctl.d/90-dotfiles-hardening.conf
  fi

  systemctl_contracts=(
    'is-enabled --quiet auditd.service'
    'enable --now auditd.service'
    'is-active --quiet sshd.service'
    'is-enabled --quiet sshd.service'
    'reload sshd.service'
    'is-enabled --quiet dnf5-automatic.timer'
    'enable --now dnf5-automatic.timer'
    'is-enabled --quiet firewalld.service'
    'is-active --quiet firewalld.service'
    'is-active --quiet auditd.service'
    'is-enabled --quiet avahi-daemon.service'
    'is-enabled --quiet cups-browsed.service'
    'is-enabled --quiet rpcbind.service'
    'is-enabled --quiet nfs-server.service'
    'is-enabled --quiet smb.service'
    'is-enabled --quiet vsftpd.service'
    'is-enabled --quiet telnet.socket'
  )
  for systemctl_contract in "${systemctl_contracts[@]}"; do
    read -r -a systemctl_argv <<<"$systemctl_contract"
    test_stub_allow "$test_root" systemctl "${systemctl_argv[@]}"
  done

  install_mktemp_mock "$mock_bin"
  install_date_and_restorecon_mocks "$mock_bin"

  cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$mock_bin/getenforce" <<'EOF'
#!/usr/bin/env bash
cat "$SELINUX_STATE" 2>/dev/null || printf 'Permissive\n'
EOF

  cat >"$mock_bin/visudo" <<'EOF'
#!/usr/bin/env bash
printf 'visudo %s\n' "$*" >>"$COMMAND_LOG"
exit 0
EOF

  cat >"$mock_bin/authselect" <<'EOF'
#!/usr/bin/env bash
printf 'authselect %s\n' "$*" >>"$COMMAND_LOG"
case "$1" in
current)
  printf 'Profile ID: sssd\n'
  printf 'Enabled features:\n'
  [[ -f "$AUTHSELECT_FEATURES" ]] && sed 's/^/- /' "$AUTHSELECT_FEATURES"
  exit 0
  ;;
enable-feature)
  printf '%s\n' "$2" >>"$AUTHSELECT_FEATURES"
  exit 0
  ;;
*)
  exit 1
  ;;
esac
EOF

  cat >"$mock_bin/sysctl" <<'EOF'
#!/usr/bin/env bash
printf 'sysctl %s\n' "$*" >>"$COMMAND_LOG"
case "$1" in
-p)
  while IFS= read -r line; do
    line="${line%%#*}"
    [[ "$line" == *=* ]] || continue
    key="$(printf '%s' "${line%%=*}" | xargs)"
    value="$(printf '%s' "${line#*=}" | xargs)"
    [[ -n "$key" ]] || continue
    grep -q "^$key=" "$SYSCTL_KV" 2>/dev/null &&
      sed -i "/^$key=/d" "$SYSCTL_KV"
    printf '%s=%s\n' "$key" "$value" >>"$SYSCTL_KV"
  done <"$2"
  ;;
-n)
  grep "^$2=" "$SYSCTL_KV" 2>/dev/null | tail -n1 | cut -d= -f2
  ;;
esac
EOF

  cat >"$test_root/handlers/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$COMMAND_LOG"
cmd="${1:-}"
shift || true
reject() {
  printf 'strict systemctl fixture rejected unsupported argv: %s' "$cmd" >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  exit 96
}
case "$cmd" in
is-active)
  [[ $# -eq 2 && "$1" == --quiet ]] || reject "$@"
  grep -qx "$2" "$ACTIVE_UNITS" 2>/dev/null
  exit $?
  ;;
is-enabled)
  [[ $# -eq 2 && "$1" == --quiet ]] || reject "$@"
  grep -qx "$2" "$ENABLED_UNITS" 2>/dev/null
  exit $?
  ;;
enable)
  [[ $# -eq 2 && "$1" == --now ]] || reject "$@"
  unit="$2"
  grep -qx "$unit" "$ENABLED_UNITS" 2>/dev/null || printf '%s\n' "$unit" >>"$ENABLED_UNITS"
  grep -qx "$unit" "$ACTIVE_UNITS" 2>/dev/null || printf '%s\n' "$unit" >>"$ACTIVE_UNITS"
  exit 0
  ;;
reload)
  [[ $# -eq 1 && "$1" == sshd.service ]] || reject "$@"
  exit 0
  ;;
restart)
  [[ $# -eq 1 && "$1" == auditd.service ]] || reject "$@"
  exit 0
  ;;
*)
  reject "$@"
  ;;
esac
EOF

  cat >"$mock_bin/sshd" <<'EOF'
#!/usr/bin/env bash
printf 'sshd %s\n' "$*" >>"$COMMAND_LOG"
exit 0
EOF

  cat >"$mock_bin/auditctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -l ]]; then
  # MOCK_AUDITCTL_EMPTY models the real failure mode this check exists for:
  # the rules file on disk is intact, but augenrules never loaded it, so the
  # running kernel is watching nothing.
  [[ "${MOCK_AUDITCTL_EMPTY:-false}" == true ]] ||
    cat "$FAKE_ROOT/etc/audit/rules.d/90-dotfiles-hardening.rules" 2>/dev/null
fi
exit 0
EOF

  cat >"$mock_bin/augenrules" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$mock_bin/firewall-cmd" <<'EOF'
#!/usr/bin/env bash
case "$1" in
--get-default-zone) printf 'FedoraWorkstation\n' ;;
*--list-services*) printf 'dhcpv6-client mdns samba-client\n' ;;
*--list-ports*) printf '\n' ;;
esac
exit 0
EOF

  cat >"$mock_bin/mokutil" <<'EOF'
#!/usr/bin/env bash
printf 'SecureBoot %s\n' "${MOCK_SECURE_BOOT:-enabled}"
exit 0
EOF

  cat >"$mock_bin/findmnt" <<'EOF'
#!/usr/bin/env bash
printf 'rw,nosuid,nodev\n'
exit 0
EOF

  cat >"$mock_bin/ss" <<'EOF'
#!/usr/bin/env bash
printf 'Netid State Recv-Q Send-Q Local-Address:Port Peer-Address:Port\n'
printf 'tcp LISTEN 0 128 127.0.0.1:631 0.0.0.0:*\n'
exit 0
EOF

  cat >"$test_root/handlers/sudo" <<'SUDO_EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"

rewrite() {
  case "$1" in
  /etc/* | /var/*) printf '%s' "$FAKE_ROOT$1" ;;
  *) printf '%s' "$1" ;;
  esac
}

cmd="$1"
shift || true

case "$cmd" in
cmp)
  [[ "${1:-}" == -s && $# -eq 3 ]] || exit 96
  left="$(rewrite "$2")"
  right="$(rewrite "$3")"
  [[ -f "$left" && -f "$right" && "$(cat -- "$left")" == "$(cat -- "$right")" ]]
  ;;
test | rm | grep | sed | cat | stat | cp | mv)
  args=()
  for a in "$@"; do args+=("$(rewrite "$a")"); done
  "$cmd" "${args[@]}"
  ;;
install)
  mode=""
  positional=()
  while (($#)); do
    case "$1" in
    -D) shift ;;
    -m)
      mode="$2"
      shift 2
      ;;
    -o | -g) shift 2 ;;
    *)
      positional+=("$1")
      shift
      ;;
    esac
  done
  install -D -m "$mode" "${positional[0]}" "$(rewrite "${positional[1]}")"
  ;;
restorecon) ;;
setenforce)
  if [[ "$1" == 1 ]]; then
    printf 'Enforcing\n' >"$SELINUX_STATE"
  else
    printf 'Permissive\n' >"$SELINUX_STATE"
  fi
  ;;
dnf | systemctl | authselect | sshd | augenrules | auditctl | sysctl)
  args=()
  for a in "$@"; do args+=("$(rewrite "$a")"); done
  "$cmd" "${args[@]}"
  ;;
*)
  printf 'strict sudo fixture rejected unsupported command: %s' "$cmd" >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  exit 96
  ;;
esac
SUDO_EOF

  chmod +x "$mock_bin"/* "$test_root/handlers"/*
  printf 'ID=fedora\n' >"$test_root/os-release"

  mapfile -t base_environment < <(test_env_args "$test_root")
  local test_environment=(
    env
    "${base_environment[@]}"
    "PATH=$mock_bin:$PATH"
    "COMMAND_LOG=$command_log"
    "OS_RELEASE_FILE=$test_root/os-release"
    "FAKE_ROOT=$fake_root"
    "HARDENING_ROOT=$fake_root"
    "SELINUX_FS_ROOT=$selinux_fs_root"
    "SELINUX_STATE=$selinux_state"
    "MOCK_EPOCH=1700000000"
    "ACTIVE_UNITS=$active_units"
    "ENABLED_UNITS=$enabled_units"
    "SYSCTL_KV=$sysctl_kv"
    "AUTHSELECT_FEATURES=$test_root/state/authselect-features"
  )

  run_install() {
    "${test_environment[@]}" \
      "$repo_root/platforms/fedora/scripts/install-hardening.sh" \
      --non-interactive >"$test_root/install-output.log" 2>&1
  }

  if ! run_install; then
    cat "$test_root/install-output.log" >&2
    _test_die "[$scenario_name] install-hardening.sh failed"
    return 1
  fi

  local state_file="$test_root/config/dotfiles/hardening.conf"
  assert_path_exists "$state_file"
  local first_state
  first_state="$(sha256sum "$state_file")"

  if ! run_install; then
    cat "$test_root/install-output.log" >&2
    _test_die "[$scenario_name] rerun of install-hardening.sh failed"
    return 1
  fi
  local second_state
  second_state="$(sha256sum "$state_file")"
  assert_eq "$first_state" "$second_state" "[$scenario_name] hardening.conf changed on rerun"

  assert_file_line "$state_file" 'profile=hardening'
  assert_file_line "$state_file" 'selinux_mode=enforcing'
  assert_file_line "$state_file" 'faillock=true'
  assert_file_line "$state_file" 'sysctl_ptrace_scope=1'
  assert_file_line "$state_file" 'sysctl_kptr_restrict=2'
  assert_file_line "$state_file" 'sysctl_dmesg_restrict=1'
  assert_file_line "$state_file" 'dnf_automatic=notifyonly'

  assert_file_contains "$command_log" 'sudo setenforce 1'
  assert_file_contains "$command_log" 'sudo authselect enable-feature with-faillock'
  assert_file_contains "$command_log" 'sudo dnf install -y dnf5-plugin-automatic'
  assert_file_contains "$command_log" 'systemctl enable --now dnf5-automatic.timer'
  test_stub_assert_called "$test_root" dnf install -y dnf5-plugin-automatic

  assert_file_line "$fake_root/etc/sysctl.d/90-dotfiles-hardening.conf" \
    'kernel.yama.ptrace_scope = 1'
  assert_file_line "$fake_root/etc/sysctl.d/90-dotfiles-hardening.conf" \
    'kernel.kptr_restrict = 2'
  assert_file_line "$fake_root/etc/sysctl.d/90-dotfiles-hardening.conf" \
    'kernel.dmesg_restrict = 1'
  assert_file_line "$fake_root/etc/security/faillock.conf.d/90-dotfiles-hardening.conf" \
    'deny = 5'
  assert_file_contains "$fake_root/etc/sudoers.d/90-dotfiles-hardening" \
    'Defaults logfile="/var/log/sudo.log"'
  assert_file_contains "$fake_root/etc/audit/rules.d/90-dotfiles-hardening.rules" \
    'dotfiles-identity'
  assert_file_line "$fake_root/etc/selinux/config" 'SELINUX=enforcing'
  assert_file_line "$fake_root/etc/selinux/config.dotfiles-1700000000.bak" \
    'SELINUX=permissive'

  if [[ "$seed_sshd" == "true" ]]; then
    assert_file_line "$fake_root/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf" \
      'PermitRootLogin no'
    assert_file_line "$fake_root/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf" \
      'MaxAuthTries 3'
    assert_file_contains "$command_log" 'sudo systemctl reload sshd.service'
    assert_file_line "$state_file" 'ssh=hardened'
  else
    assert_path_missing "$fake_root/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf"
    assert_file_line "$state_file" 'ssh=not-present'
  fi

  local verify_output
  if ! verify_output="$("${test_environment[@]}" \
    "$repo_root/platforms/fedora/scripts/verify-hardening.sh" 2>&1)"; then
    _test_die "[$scenario_name] verify-hardening.sh reported failures:\n$verify_output"
    return 1
  fi

  assert_contains "$verify_output" 'SELinux is enforcing'
  assert_contains "$verify_output" 'firewalld.service is enabled and active'
  # Every repository-owned control is actually inspected on the happy path,
  # not skipped: mode and content are asserted, not just existence.
  assert_contains "$verify_output" \
    'faillock policy drop-in is present, mode 644, and unmodified'
  assert_contains "$verify_output" \
    'sudo logfile drop-in is present, mode 440, and unmodified'
  assert_contains "$verify_output" \
    'auditd watch rules is present, mode 640, and unmodified'
  assert_contains "$verify_output" \
    'hardening sysctl drop-in is present, mode 644, and unmodified'
  assert_contains "$verify_output" 'dotfiles watch rules are loaded'
  # Manual-assurance areas are labelled as such instead of counted as proof.
  assert_contains "$verify_output" 'manual assurance:'
  assert_contains "$verify_output" 'Mount options (manual assurance, not verified)'
  assert_contains "$verify_output" 'kernel.yama.ptrace_scope = 1'
  assert_contains "$verify_output" 'kernel.kptr_restrict = 2'
  assert_contains "$verify_output" 'kernel.dmesg_restrict = 1'

  if [[ "$seed_sshd" == "true" ]]; then
    assert_contains "$verify_output" 'sshd hardening drop-in applied'
  else
    assert_contains "$verify_output" 'SSH posture is not applicable'
  fi

  run_capture env COMMAND_LOG="$command_log" ACTIVE_UNITS="$active_units" \
    ENABLED_UNITS="$enabled_units" PATH="$mock_bin:$PATH" \
    systemctl daemon-reload
  assert_status 96

  # -------------------------------------------------------------------------
  # Negative mutations
  #
  # A machine that selected the hardening profile and later lost a control
  # used to keep verifying clean, because missing owned artifacts were only
  # warnings. Each mutation below reverts exactly one repository-owned control
  # on an otherwise-passing machine and must make verification exit non-zero.
  # Mutations run on the richer sshd-active fixture and are reverted
  # afterwards so the cases stay independent.
  # -------------------------------------------------------------------------

  if [[ "$seed_sshd" == "true" ]]; then
    local faillock_dropin="$fake_root/etc/security/faillock.conf.d/90-dotfiles-hardening.conf"
    local sudoers_dropin="$fake_root/etc/sudoers.d/90-dotfiles-hardening"
    local sysctl_dropin="$fake_root/etc/sysctl.d/90-dotfiles-hardening.conf"
    local ssh_dropin="$fake_root/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf"
    local backup="$test_root/state/mutation-backup"

    run_verify() {
      run_capture "${test_environment[@]}" "$@" \
        "$repo_root/platforms/fedora/scripts/verify-hardening.sh"
    }

    # 1. A deleted owned artifact.
    cp -p "$sysctl_dropin" "$backup"
    rm -f -- "$sysctl_dropin"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" 'hardening sysctl drop-in is missing'
    assert_contains "$TEST_OUTPUT" 'install-hardening.sh'
    cp -p "$backup" "$sysctl_dropin"

    # 2. Altered content: the file is still there, the policy is not.
    cp -p "$faillock_dropin" "$backup"
    sed -i 's/^unlock_time = 900$/unlock_time = 5/' "$faillock_dropin"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      "faillock policy drop-in no longer contains 'unlock_time = 900'"
    cp -p "$backup" "$faillock_dropin"

    # 3. Wrong file mode: a group/other-readable sudoers drop-in.
    local original_mode
    original_mode="$(stat -c '%a' "$sudoers_dropin")"
    chmod 0644 "$sudoers_dropin"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      'sudo logfile drop-in has mode 644, expected 440'
    chmod "0$original_mode" "$sudoers_dropin"

    # 4. An owned service that was switched off after installation.
    sed -i '/^auditd.service$/d' "$active_units"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" 'auditd.service is enabled but not active'
    assert_contains "$TEST_OUTPUT" 'recorded'
    printf 'auditd.service\n' >>"$active_units"

    # 4b. A security service running now that will not come back after a
    #     reboot: firewalld started by hand but no longer enabled. An
    #     is-active check alone reported this as a pass.
    sed -i '/^firewalld.service$/d' "$enabled_units"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      'firewalld.service is active but not enabled; it will not start after a reboot'
    assert_not_contains "$TEST_OUTPUT" 'firewalld.service is enabled and active'
    [[ "$(sed $'s/\033\\[[0-9;]*m//g' <<<"$TEST_OUTPUT")" =~ failed:\ ([0-9]+)\ failure ]] &&
      ((BASH_REMATCH[1] > 0)) ||
      _test_die "active-but-disabled firewalld must be counted as a verifier failure"
    printf 'firewalld.service\n' >>"$enabled_units"

    # 5. An owned control that is present on disk but ineffective: the rules
    #    file is intact, yet the running kernel has no dotfiles watches.
    run_verify MOCK_AUDITCTL_EMPTY=true
    assert_failure
    assert_contains "$TEST_OUTPUT" 'not loaded in the running kernel'
    assert_contains "$TEST_OUTPUT" 'present but ineffective'

    # 6. An owned drop-in whose policy line was reverted.
    cp -p "$ssh_dropin" "$backup"
    sed -i 's/^PermitRootLogin no$/PermitRootLogin yes/' "$ssh_dropin"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" "no longer contains 'PermitRootLogin no'"
    cp -p "$backup" "$ssh_dropin"

    # 7. An owned timer that was disabled after installation.
    sed -i '/^dnf5-automatic.timer$/d' "$enabled_units"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" 'dnf5-automatic.timer is not enabled'
    assert_contains "$TEST_OUTPUT" 'dnf_automatic=notifyonly'
    printf 'dnf5-automatic.timer\n' >>"$enabled_units"

    # 8. Corrupt recorded state is not something to verify around.
    cp -p "$state_file" "$backup"
    printf 'profile=hardening\nselinux_mode=enforcing\n' >"$state_file"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" 'recorded state is'
    cp -p "$backup" "$state_file"

    # 9. An unmet *recommendation* stays a warning: disabled Secure Boot is
    #    firmware state this profile never touches.
    run_verify MOCK_SECURE_BOOT=disabled
    assert_success
    assert_contains "$TEST_OUTPUT" 'Secure Boot is disabled'
    assert_contains "$TEST_OUTPUT" 'never changes'

    # 10. An unselected profile must not fail merely because the optional
    #     artifacts it never installed are absent.
    rm -f -- "$state_file" "$faillock_dropin" "$sudoers_dropin" \
      "$sysctl_dropin" "$ssh_dropin" \
      "$fake_root/etc/audit/rules.d/90-dotfiles-hardening.rules"
    run_verify
    assert_success
    assert_contains "$TEST_OUTPUT" 'no hardening profile selection is recorded'
    assert_not_contains "$TEST_OUTPUT" 'is missing:'

    printf 'PASS: broken repository-owned hardening controls fail verification\n'
  fi

  printf 'PASS: %s\n' "$scenario_name"
}

# The interactive confirmation is the last point before this profile mutates
# anything, and it is a step of platforms/fedora/install.sh's plan rather than
# a top-level installer. Collapsing `confirm`'s three-valued result with
# `|| exit 0` therefore reported a profile nobody agreed to install as
# installed: plan_execute recorded `[hardening] completed` and
# install_lifecycle_commit put `hardening` in observed_capabilities, while no
# hardening.conf existed for the verifier to check.
run_confirmation_contract() {
  test_new_root
  local test_root="$TEST_ROOT"
  local mock_bin="$test_root/bin"

  mkdir -p "$mock_bin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$mock_bin/dnf"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$mock_bin/rpm"
  chmod +x "$mock_bin"/*
  printf 'ID=fedora\n' >"$test_root/os-release"

  local base_environment
  mapfile -t base_environment < <(test_env_args "$test_root")
  local test_environment=(
    env
    "${base_environment[@]}"
    "PATH=$mock_bin:$PATH"
    "OS_RELEASE_FILE=$test_root/os-release"
  )
  local state_file="$test_root/config/dotfiles/hardening.conf"

  # run_answer <label> <expected-message> [answer]
  #
  # The answer is fed to the prompt; omitting it means a closed standard
  # input, which `confirm` documents as declined rather than as a silently
  # inherited yes.
  run_answer() {
    local label="$1" expected_message="$2"
    shift 2
    local status=0 output
    local answer_file="$test_root/state/answer"

    rm -f -- "$state_file"
    # An empty answer file is an immediate EOF, which is what `read` sees on a
    # closed standard input; an unattended run must not inherit a yes there.
    if (($#)); then printf '%s\n' "$1" >"$answer_file"; else : >"$answer_file"; fi

    output="$("${test_environment[@]}" \
      "$repo_root/platforms/fedora/scripts/install-hardening.sh" \
      <"$answer_file" 2>&1)" || status=$?

    ((status != 0)) ||
      _test_die "[$label] a hardening profile that was not agreed to exited 0, so the plan records it as installed; output: $output"
    assert_contains "$output" "$expected_message"
    [[ ! -e "$state_file" ]] ||
      _test_die "[$label] a hardening profile that was not agreed to wrote $state_file"
  }

  run_answer 'declined' 'Hardening installation declined' n
  run_answer 'unparseable answer' 'Invalid confirmation response' maybe
  run_answer 'no answer on standard input' 'Hardening installation declined'

  printf 'PASS: a hardening confirmation that is not a yes stops the run instead of completing it\n'
}

run_confirmation_contract
run_root_prefix_contract unset
run_root_prefix_contract empty
run_root_prefix_contract prefix
run_selinux_config_contract
run_scenario "hardening install/verify with sshd absent (default Fedora Workstation)" false
run_scenario "hardening install/verify with sshd active" true

printf '\nFedora hardening install/verify and idempotency tests passed.\n'
