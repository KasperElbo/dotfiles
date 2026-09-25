#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_isolate_path sha256sum timeout

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
  local ssh_path=/etc/ssh/sshd_config.d/00-dotfiles-hardening.conf
  local legacy_ssh_path=/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf

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
    "-n true"
    "-n test -f $root$contract_path"
    "-n cat -- $root$contract_path"
    "-n stat -c %a $root$contract_path"
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
    "test -f $root$legacy_ssh_path"
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
# Verification asks sudo whether it can answer at all before it reads
# anything, and every read it then makes carries -n.
if [[ "$1" == -n ]]; then
  shift
  [[ "$1" != true ]] || exit 0
fi
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

# assert_non_interactive_sudo <command-log> <first-line>: fails unless every
# sudo call the log records from <first-line> on carries -n.
#
# Verification is documented as read-only and is run from scripts, timers and
# sessions with no terminal to answer on, so a password prompt there is a hang,
# not a question. The installer's own calls come earlier in the same log and
# may legitimately ask, which is why this reads a slice rather than the file.
assert_non_interactive_sudo() {
  local command_log="$1"
  local first_line="$2"
  local interactive

  interactive="$(
    sed -n "$((first_line + 1)),\$p" "$command_log" |
      grep '^sudo ' | grep -v '^sudo -n ' || true
  )"
  [[ -z "$interactive" ]] ||
    _test_die "verification ran sudo without -n, so it can stop on a password prompt:\n$interactive"
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

# run_faillock_config_contract: the lockout policy goes into the one file
# pam_faillock reads, /etc/security/faillock.conf, without costing an
# administrator a line of it, converges on reruns, and is refused rather than
# rewritten when the file is not in a shape it can safely edit. Until #535 it
# went to a faillock.conf.d drop-in, which pam_faillock does not read at all.
run_faillock_config_contract() {
  test_new_root
  local test_root="$TEST_ROOT"
  local fake_root="$test_root/fake-root"
  local config="$fake_root/etc/security/faillock.conf"
  local legacy="$fake_root/etc/security/faillock.conf.d/90-dotfiles-hardening.conf"
  local block=$'# BEGIN dotfiles Fedora hardening profile. Delete through END to undo.\ndeny = 5\nunlock_time = 900\n# END dotfiles Fedora hardening profile'
  local before

  mkdir -p "${legacy%/*}"
  printf '# deny = 3\ndir = /var/lib/faillock\n' >"$config"
  chmod 0644 "$config"
  printf 'deny = 5\n' >"$legacy"

  install_mktemp_mock "$test_root/bin"
  install_date_and_restorecon_mocks "$test_root/bin"
  # Every privileged call is carried out as asked, on the fixture's paths:
  # this contract is about what the file ends up holding, which the exact-argv
  # lists of the SELinux and scenario contracts do not show.
  cat >"$test_root/bin/sudo" <<'SUDO_EOF'
#!/usr/bin/env bash
case "$1" in
restorecon) exit 0 ;;
cmp) [[ -f "$3" && -f "$4" && "$(cat -- "$3")" == "$(cat -- "$4")" ]] ;;
install) install -m "$3" "$8" "$9" ;;
mv)
  "$@" || exit
  [[ "${SABOTAGE_FAILLOCK_WRITE:-false}" != true ]] || printf 'deny = 50\n' >>"$5"
  ;;
test | cat | cp | stat | rm) "$@" ;;
*)
  printf 'faillock contract sudo rejected: %s\n' "$*" >&2
  exit 96
  ;;
esac
SUDO_EOF
  chmod +x "$test_root/bin/sudo"

  run_apply() {
    run_capture env PATH="$test_root/bin:$PATH" HARDENING_ROOT="$fake_root" \
      MOCK_EPOCH="$1" SABOTAGE_FAILLOCK_WRITE="${2:-false}" \
      DOTFILES_ROOT_DIR="$repo_root" \
      bash -c '
        set -euo pipefail
        source "$DOTFILES_ROOT_DIR/common/lib/common.sh"
        source "$DOTFILES_ROOT_DIR/platforms/fedora/lib/hardening.sh"
        apply_faillock_policy
      '
  }

  # 1. First run: the administrator's lines kept, the block last, a backup of
  #    what was there, and the drop-in pam_faillock never read removed.
  run_apply 1700000000
  assert_success
  assert_eq $'# deny = 3\ndir = /var/lib/faillock\n'"$block" "$(cat "$config")" \
    '[faillock config] first write'
  assert_eq $'# deny = 3\ndir = /var/lib/faillock' \
    "$(cat "$config.dotfiles-1700000000.bak")" '[faillock config] backup'
  assert_eq 644 "$(stat -c '%a' "$config")" '[faillock config] preserved mode'
  assert_path_missing "$legacy"

  # 2. An unchanged rerun changes nothing and makes no second backup.
  run_apply 1700000100
  assert_success
  assert_contains "$TEST_OUTPUT" 'pam_faillock lockout policy already applied'
  assert_path_missing "$config.dotfiles-1700000100.bak"

  # 3. A line added after the block wins over it in pam_faillock. A rerun
  #    keeps that line and moves the block back below it, where it wins.
  printf 'deny = 50\n' >>"$config"
  run_apply 1700000200
  assert_success
  assert_eq $'# deny = 3\ndir = /var/lib/faillock\ndeny = 50\n'"$block" \
    "$(cat "$config")" '[faillock config] block moved last'

  # 4. No file at all, so pam_faillock would run on its defaults: it is
  #    created with the table's mode, and there is nothing to back up.
  rm -f -- "$config" "$config".dotfiles-*.bak
  run_apply 1700000300
  assert_success
  assert_eq "$block" "$(cat "$config")" '[faillock config] created'
  assert_eq 644 "$(stat -c '%a' "$config")" '[faillock config] created mode'
  assert_path_missing "$config.dotfiles-1700000300.bak"

  # 5. A write that did not produce the staged content is caught by the
  #    read-back, which names the backup to restore.
  printf 'dir = /var/lib/faillock\n' >"$config"
  run_apply 1700000400 true
  assert_failure
  assert_contains "$TEST_OUTPUT" \
    "$config does not carry the lockout policy after the rewrite"
  assert_contains "$TEST_OUTPUT" \
    "sudo cp -a $config.dotfiles-1700000400.bak $config"

  # 6. A block with no END line is refused before any backup or write:
  #    taking it out would take every line after it too.
  printf '%s\ndeny = 5\ndir = /var/lib/faillock\n' \
    '# BEGIN dotfiles Fedora hardening profile. Delete through END to undo.' \
    >"$config"
  before="$(cat "$config")"
  run_apply 1700000500
  assert_failure
  assert_contains "$TEST_OUTPUT" "Refusing to rewrite $config"
  assert_eq "$before" "$(cat "$config")" \
    '[faillock config] refused file is unchanged'
  assert_path_missing "$config.dotfiles-1700000500.bak"

  printf 'PASS: the faillock policy is written into faillock.conf, keeping its other lines\n'
}

run_scenario() {
  local scenario_name="$1"
  local seed_sshd="$2"

  test_new_root
  local test_root="$TEST_ROOT"
  local mock_bin="$test_root/bin"
  local command_log="$test_root/commands.log"
  local fake_root="$test_root/fake-root"
  # A root that holds none of the drop-ins, for the case where the unprivileged
  # read cannot see them and sudo will not answer without a password.
  local unreadable_root="$test_root/unreadable-root"
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
  # Fedora's /etc/security/faillock.conf is every option commented out; this
  # one also carries a line an administrator added, which has to survive, and
  # the drop-in an earlier install of this profile wrote where pam_faillock
  # never looked, which has to go.
  mkdir -p "$fake_root/etc/security/faillock.conf.d" "$fake_root/etc/pam.d"
  printf '%s\n' \
    '# Configuration for locking the user after multiple failed' \
    '# authentication attempts.' \
    '#' \
    '# The default is 3.' \
    '# deny = 3' \
    '#' \
    '# The default is 600 (10 minutes).' \
    '# unlock_time = 600' \
    'audit' \
    >"$fake_root/etc/security/faillock.conf"
  chmod 0644 "$fake_root/etc/security/faillock.conf"
  printf '%s\n' '# Managed by dotfiles Fedora hardening profile. Safe to delete.' \
    'deny = 5' 'unlock_time = 900' \
    >"$fake_root/etc/security/faillock.conf.d/90-dotfiles-hardening.conf"
  # The pam_faillock lines authselect's with-faillock feature writes: no
  # argument that would override the file.
  printf '%s\n' \
    'auth        required      pam_faillock.so preauth silent' \
    'auth        required      pam_faillock.so authfail' \
    'account     required      pam_faillock.so' \
    | tee "$fake_root/etc/pam.d/system-auth" \
    >"$fake_root/etc/pam.d/password-auth"
  printf 'firewalld.service\n' >>"$active_units"
  printf 'firewalld.service\n' >>"$enabled_units"
  # Fedora's own /etc/sudoers, cut down to what sudo -l has to report: a
  # quoted value with spaces, a value sudo prints with its colons escaped, and
  # the includedir line last, so the drop-ins' Defaults are read after these
  # and anything added below that line is read after the drop-ins.
  printf '%s\n' \
    'Defaults   !visiblepw' \
    'Defaults    always_set_home' \
    'Defaults    env_reset' \
    'Defaults    env_keep =  "COLORS DISPLAY HOSTNAME HISTSIZE KDEDIR LS_COLORS"' \
    'Defaults    secure_path = /sbin:/bin:/usr/sbin:/usr/bin' \
    'root	ALL=(ALL) 	ALL' \
    '%wheel	ALL=(ALL)	ALL' \
    '#includedir /etc/sudoers.d' \
    >"$fake_root/etc/sudoers"

  if [[ "$seed_sshd" == "true" ]]; then
    printf 'sshd.service\n' >>"$active_units"
    printf 'sshd.service\n' >>"$enabled_units"
    # Fedora's own sshd_config puts the Include first, so every drop-in is
    # read before anything else in this file can set a keyword.
    mkdir -p "$fake_root/etc/ssh"
    printf '%s\n' \
      'Include /etc/ssh/sshd_config.d/*.conf' \
      'AuthorizedKeysFile .ssh/authorized_keys' \
      'Subsystem sftp /usr/libexec/openssh/sftp-server' \
      >"$fake_root/etc/ssh/sshd_config"
    # What Anaconda writes when root SSH login with a password is allowed at
    # installation, which is how a Fedora machine comes to run sshd at all.
    # sshd keeps the first value it reads, and this file sorts before a 90-
    # drop-in, so a profile drop-in sorting after it never takes effect.
    mkdir -p "$fake_root/etc/ssh/sshd_config.d"
    printf 'PermitRootLogin yes\n' \
      >"$fake_root/etc/ssh/sshd_config.d/01-permitrootlogin.conf"
    # A machine hardened before the drop-in was renamed to sort first still
    # holds the 90- copy, which the installer supersedes and removes.
    printf 'PermitRootLogin no\n' \
      >"$fake_root/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf"
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
  local faillock_conf="$fake_root/etc/security/faillock.conf"
  test_stub_allow "$test_root" sudo test -f "$faillock_conf"
  test_stub_allow "$test_root" sudo cat -- "$faillock_conf"
  test_stub_allow "$test_root" sudo cp -a -- "$faillock_conf" \
    "$faillock_conf.dotfiles-1700000000.bak"
  test_stub_allow "$test_root" sudo stat -c '%a' "$faillock_conf"
  test_stub_allow "$test_root" sudo install -m 644 -o root -g root \
    "$test_root/state/tmp-2" "$faillock_conf.dotfiles-new"
  test_stub_allow "$test_root" sudo mv -f -- "$faillock_conf.dotfiles-new" \
    "$faillock_conf"
  test_stub_allow "$test_root" sudo restorecon "$faillock_conf"
  test_stub_allow "$test_root" sudo test -f \
    "$fake_root"/etc/security/faillock.conf.d/90-dotfiles-hardening.conf
  test_stub_allow "$test_root" sudo rm -f -- \
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
  test_stub_allow "$test_root" sudo -n auditctl -l
  # Verification reads owned drop-ins it cannot see unprivileged. These are
  # reads and stats only; no write form of sudo is ever allowed here, and each
  # one is -n, because verification must never stop on a password prompt.
  test_stub_allow "$test_root" sudo -n true
  test_stub_allow "$test_root" sudo -n -l
  for owned_path in \
    /etc/security/faillock.conf \
    /etc/sudoers.d/90-dotfiles-hardening \
    /etc/audit/rules.d/90-dotfiles-hardening.rules \
    /etc/sysctl.d/90-dotfiles-hardening.conf \
    /etc/ssh/sshd_config.d/00-dotfiles-hardening.conf; do
    test_stub_allow "$test_root" sudo -n stat -c '%a' "$fake_root$owned_path"
    test_stub_allow "$test_root" sudo -n cat -- "$fake_root$owned_path"
    test_stub_allow "$test_root" sudo -n test -f "$fake_root$owned_path"
    test_stub_allow "$test_root" sudo -n test -f "$unreadable_root$owned_path"
  done
  test_stub_allow "$test_root" sudo systemctl enable --now auditd.service
  test_stub_allow "$test_root" sudo systemctl enable --now dnf5-automatic.timer

  test_stub_allow "$test_root" sudo install -D -m 0440 -o root -g root \
    "$test_root/state/tmp-4" "$fake_root"/etc/sudoers.d/90-dotfiles-hardening
  test_stub_allow "$test_root" sudo install -D -m 0640 -o root -g root \
    "$test_root/state/tmp-5" "$fake_root"/etc/audit/rules.d/90-dotfiles-hardening.rules
  test_stub_allow "$test_root" sudo install -D -m 0644 -o root -g root \
    "$test_root/state/tmp-6" "$fake_root"/etc/sysctl.d/90-dotfiles-hardening.conf

  if [[ "$seed_sshd" == "true" ]]; then
    test_stub_allow "$test_root" sudo test -f \
      "$fake_root"/etc/ssh/sshd_config.d/00-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo install -D -m 0644 -o root -g root \
      "$test_root/state/tmp-7" \
      "$fake_root"/etc/ssh/sshd_config.d/00-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-10" \
      "$faillock_conf"
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-12" \
      "$fake_root"/etc/sudoers.d/90-dotfiles-hardening
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-13" \
      "$fake_root"/etc/audit/rules.d/90-dotfiles-hardening.rules
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-14" \
      "$fake_root"/etc/sysctl.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-15" \
      "$fake_root"/etc/ssh/sshd_config.d/00-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo sshd -t
    test_stub_allow "$test_root" sudo -n sshd -T
    test_stub_allow "$test_root" sudo test -f \
      "$fake_root"/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo rm -f -- \
      "$fake_root"/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo systemctl reload sshd.service
    test_stub_allow "$test_root" sudo grep -Fqx 'PermitRootLogin no' \
      "$fake_root"/etc/ssh/sshd_config.d/00-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo grep -Fqx 'MaxAuthTries 3' \
      "$fake_root"/etc/ssh/sshd_config.d/00-dotfiles-hardening.conf
  else
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-9" \
      "$faillock_conf"
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

  # A model of sshd, not a stub that agrees with everything. -t answers the
  # installer's syntax check. -T resolves the configuration the way
  # sshd_config(5) describes it -- the first value read for a keyword wins,
  # Include expands in place in lexical order and is followed across files,
  # and global settings stop at the first Match -- then prints it as sshd -T
  # does: one lower-case `keyword value` per line, defaults included. With no
  # /etc/ssh/sshd_config it fails as sshd does. Any other argv is refused, so
  # a new sshd call has to be modelled before it can pass. MOCK_SSHD_T
  # replaces -T's answer with one of the ways it can fail to arrive: hang (no
  # answer at all) or stall (the whole answer printed, and then no exit).
  cat >"$mock_bin/sshd" <<'EOF'
#!/usr/bin/env bash
printf 'sshd %s\n' "$*" >>"$COMMAND_LOG"
case "$*" in
-t) exit 0 ;;
-T)
  case "${MOCK_SSHD_T:-model}" in
  model | stall) ;;
  hang)
    # Detached from the output, so a probe that is killed on time is not
    # then held open by a sleeping child.
    sleep 10 </dev/null >/dev/null 2>&1
    exit 0
    ;;
  *) exit 96 ;;
  esac
  ;;
*)
  printf 'strict sshd fixture rejected unsupported argv: %s\n' "$*" >&2
  exit 96
  ;;
esac

export LC_ALL=C
shopt -s nullglob
declare -A effective=(
  [permitrootlogin]=prohibit-password
  [maxauthtries]=6
  [logingracetime]=120
)
declare -A seen=()
in_match=false

read_config() {
  local file="$1" line keyword value pattern included patterns
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    read -r keyword value <<<"$line"
    [[ -n "$keyword" ]] || continue
    keyword="${keyword,,}"
    [[ "$keyword" != match ]] || in_match=true
    ! "$in_match" || continue
    if [[ "$keyword" == include ]]; then
      # Split without globbing: the patterns name the fixture's /etc, and
      # expanding them against the host's would be a different answer.
      read -r -a patterns <<<"$value"
      for pattern in "${patterns[@]}"; do
        [[ "$pattern" == /* ]] || pattern="/etc/ssh/$pattern"
        for included in "$FAKE_ROOT"$pattern; do
          read_config "$included"
        done
      done
      continue
    fi
    [[ -z "${seen[$keyword]:-}" ]] || continue
    seen[$keyword]=1
    effective[$keyword]="${value,,}"
  done <"$file"
}

if [[ ! -f "$FAKE_ROOT/etc/ssh/sshd_config" ]]; then
  printf '/etc/ssh/sshd_config: No such file or directory\n' >&2
  exit 255
fi
read_config "$FAKE_ROOT/etc/ssh/sshd_config"
for keyword in "${!effective[@]}"; do
  printf '%s %s\n' "$keyword" "${effective[$keyword]}"
done | sort
if [[ "${MOCK_SSHD_T:-model}" == stall ]]; then
  sleep 10 </dev/null >/dev/null 2>&1
fi
EOF

  cat >"$mock_bin/auditctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -l ]]; then
  # MOCK_AUDITCTL_EMPTY models the real failure mode this check exists for:
  # the rules file on disk is intact, but augenrules never loaded it, so the
  # running kernel is watching nothing. MOCK_AUDITCTL_RULES models the other
  # one: a kernel that answers, but with a ruleset that is not the one the
  # installer wrote.
  if [[ "${MOCK_AUDITCTL_EMPTY:-false}" == true ]]; then
    :
  elif [[ -n "${MOCK_AUDITCTL_RULES:-}" ]]; then
    printf '%s\n' "$MOCK_AUDITCTL_RULES"
  else
    # Real auditctl trims a directory watch's trailing slash before the rule
    # reaches the kernel, so '-w /etc/sudoers.d/' is listed without it.
    sed -E 's#^(-w [^ ]*[^/ ])/+( |$)#\1\2#' \
      "$FAKE_ROOT/etc/audit/rules.d/90-dotfiles-hardening.rules" 2>/dev/null
  fi
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

# Verification asks whether sudo can answer without a password before it reads
# anything, and carries -n on every read afterwards. MOCK_SUDO_UNAUTHORIZED
# models an expired sudo timestamp: -n is refused the way sudo refuses it, and
# a bare sudo (the installer's, which may legitimately ask) is untouched.
if [[ "${1:-}" == -n ]]; then
  if [[ "${MOCK_SUDO_UNAUTHORIZED:-false}" == true ]]; then
    printf 'sudo: a password is required\n' >&2
    exit 1
  fi
  shift
  [[ "${1:-}" != true ]] || exit 0
fi

# A model of `sudo -l`, not a stub that agrees with everything. It reads the
# fixture's /etc/sudoers the way sudoers(5) describes it -- #includedir and
# @includedir expand in place, in lexical order, skipping names that contain a
# dot or end in ~ -- keeps every Defaults entry that applies to the invoking
# user (global ones and Defaults:<user>), and prints them in the order read,
# as sudo does, under its "Matching Defaults entries" header: value quoted
# only when it holds whitespace, otherwise with sudo's special characters
# backslash-escaped, the list wrapped with an indent. It never resolves the
# list itself, so whatever reads it has to apply "the last one wins".
# MOCK_SUDO_LIST replaces the answer with one of the ways sudo can fail to
# give it: refused (a non-zero exit), unrecognized (no Defaults section), or
# hang (no answer at all).
list_sudo_policy() {
  local user entries=() line entry out="" width=4

  case "${MOCK_SUDO_LIST:-model}" in
  model) ;;
  refused)
    printf 'Sorry, user %s may not run sudo on fixture.\n' "$(id -un)" >&2
    exit 1
    ;;
  unrecognized)
    printf 'User %s may run the following commands on fixture:\n' "$(id -un)"
    printf '    (ALL) ALL\n'
    exit 0
    ;;
  hang)
    # Detached from the output, so a probe that is killed on time is not
    # then held open by a sleeping child.
    sleep 10 </dev/null >/dev/null 2>&1
    exit 0
    ;;
  *) exit 96 ;;
  esac

  export LC_ALL=C
  shopt -s nullglob
  user="$(id -un)"

  split_entries() {
    local text="$1" char quoted=false current="" i
    for ((i = 0; i < ${#text}; i++)); do
      char="${text:i:1}"
      if [[ "$char" == '"' ]]; then
        quoted=$([[ "$quoted" == true ]] && echo false || echo true)
      elif [[ "$char" == , && "$quoted" == false ]]; then
        entries+=("$current")
        current=""
        continue
      fi
      current+="$char"
    done
    entries+=("$current")
  }

  read_sudoers() {
    local file="$1" line scope included name
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^[#@]includedir[[:space:]]+([^[:space:]]+) ]]; then
        for included in "$FAKE_ROOT${BASH_REMATCH[1]}"/*; do
          name="${included##*/}"
          [[ "$name" != *~ && "$name" != *.* ]] || continue
          read_sudoers "$included"
        done
        continue
      fi
      [[ "$line" =~ ^Defaults(:([^[:space:]]+))?[[:space:]]+(.*)$ ]] || continue
      scope="${BASH_REMATCH[2]}"
      [[ -z "$scope" || "$scope" == "$user" ]] || continue
      split_entries "${BASH_REMATCH[3]}"
    done <"$file"
  }

  [[ -f "$FAKE_ROOT/etc/sudoers" ]] || {
    printf 'sudo: unable to open /etc/sudoers: No such file or directory\n' >&2
    exit 1
  }
  read_sudoers "$FAKE_ROOT/etc/sudoers"

  printf 'Matching Defaults entries for %s on fixture:\n' "$user"
  for entry in "${entries[@]}"; do
    entry="$(sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//' <<<"$entry")"
    if [[ "$entry" =~ ^([A-Za-z_]+)[[:space:]]*([+-]?=)[[:space:]]*(.*)$ ]]; then
      local setting="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
      local value="${BASH_REMATCH[3]}"
      value="${value#\"}"
      value="${value%\"}"
      if [[ "$value" =~ [[:space:]] ]]; then
        entry="$setting\"$value\""
      else
        entry="$setting$(sed 's/[\\,:=#"]/\\&/g' <<<"$value")"
      fi
    fi
    if ((width + ${#entry} + 2 > 80)); then
      out+=$',\n    '
      width=4
    elif [[ -n "$out" ]]; then
      out+=', '
    fi
    [[ -n "$out" ]] || out='    '
    out+="$entry"
    width=$((width + ${#entry} + 2))
  done
  printf '%s\n\n' "$out"
  printf 'User %s may run the following commands on fixture:\n' "$user"
  printf '    (ALL) ALL\n'
}

rewrite() {
  case "$1" in
  /etc/* | /var/*) printf '%s' "$FAKE_ROOT$1" ;;
  *) printf '%s' "$1" ;;
  esac
}

cmd="$1"
shift || true

case "$cmd" in
-l)
  [[ $# -eq 0 ]] || exit 96
  list_sudo_policy
  ;;
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
  # The policy is in the one file pam_faillock reads, after every line that
  # was already there, and the drop-in it never read is gone.
  assert_eq "$(printf '%s\n' \
    '# Configuration for locking the user after multiple failed' \
    '# authentication attempts.' \
    '#' \
    '# The default is 3.' \
    '# deny = 3' \
    '#' \
    '# The default is 600 (10 minutes).' \
    '# unlock_time = 600' \
    'audit' \
    '# BEGIN dotfiles Fedora hardening profile. Delete through END to undo.' \
    'deny = 5' \
    'unlock_time = 900' \
    '# END dotfiles Fedora hardening profile')" "$(cat "$faillock_conf")" \
    "[$scenario_name] faillock.conf after install"
  assert_path_exists "$faillock_conf.dotfiles-1700000000.bak"
  assert_path_missing \
    "$fake_root/etc/security/faillock.conf.d/90-dotfiles-hardening.conf"
  assert_file_contains "$fake_root/etc/sudoers.d/90-dotfiles-hardening" \
    'Defaults logfile="/var/log/sudo.log"'
  assert_file_contains "$fake_root/etc/audit/rules.d/90-dotfiles-hardening.rules" \
    'dotfiles-identity'
  assert_file_line "$fake_root/etc/selinux/config" 'SELINUX=enforcing'
  assert_file_line "$fake_root/etc/selinux/config.dotfiles-1700000000.bak" \
    'SELINUX=permissive'

  if [[ "$seed_sshd" == "true" ]]; then
    assert_file_line "$fake_root/etc/ssh/sshd_config.d/00-dotfiles-hardening.conf" \
      'PermitRootLogin no'
    assert_file_line "$fake_root/etc/ssh/sshd_config.d/00-dotfiles-hardening.conf" \
      'MaxAuthTries 3'
    assert_file_contains "$command_log" 'sudo systemctl reload sshd.service'
    assert_file_line "$state_file" 'ssh=hardened'
    # The superseded copy is gone, and Anaconda's file, which is not this
    # profile's, is left exactly as it was.
    assert_path_missing "$fake_root/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf"
    assert_file_line "$fake_root/etc/ssh/sshd_config.d/01-permitrootlogin.conf" \
      'PermitRootLogin yes'
  else
    assert_path_missing "$fake_root/etc/ssh/sshd_config.d/00-dotfiles-hardening.conf"
    assert_file_line "$state_file" 'ssh=not-present'
  fi

  # Credentials in every place the audit looks, all private, so the happy
  # path proves each of them is read rather than skipped for being absent.
  # The public half is left world-readable, as ssh-keygen writes it, and must
  # never be reported.
  local test_home="$test_root/home"
  local credential_files=(
    "$test_home/.ssh/id_ed25519"
    "$test_home/.ssh/deploy.pem"
    "$test_home/.aws/credentials"
    "$test_home/.config/gh/hosts.yml"
    "$test_home/.gnupg/private-keys-v1.d/0123456789ABCDEF.key"
  )
  local credential_file
  for credential_file in "${credential_files[@]}"; do
    mkdir -p "$(dirname "$credential_file")"
    printf 'fixture secret\n' >"$credential_file"
    chmod 0600 "$credential_file"
  done
  printf 'ssh-ed25519 AAAA fixture\n' >"$test_home/.ssh/id_ed25519.pub"
  chmod 0644 "$test_home/.ssh/id_ed25519.pub"

  local verify_output verify_sudo_calls_before
  verify_sudo_calls_before="$(wc -l <"$command_log")"
  if ! verify_output="$("${test_environment[@]}" \
    "$repo_root/platforms/fedora/scripts/verify-hardening.sh" 2>&1)"; then
    _test_die "[$scenario_name] verify-hardening.sh reported failures:\n$verify_output"
    return 1
  fi

  assert_non_interactive_sudo "$command_log" "$verify_sudo_calls_before"
  assert_contains "$verify_output" 'SELinux is enforcing'
  assert_contains "$verify_output" 'firewalld.service is enabled and active'
  # Every repository-owned control is actually inspected on the happy path,
  # not skipped: mode and content are asserted, not just existence.
  assert_contains "$verify_output" \
    'pam_faillock reads deny = 5, unlock_time = 900 from /etc/security/faillock.conf'
  assert_contains "$verify_output" \
    'sudo logfile drop-in is present, mode 440, and unmodified'
  assert_contains "$verify_output" \
    "sudo's effective policy has logfile=/var/log/sudo.log"
  assert_contains "$verify_output" \
    'auditd watch rules is present, mode 640, and unmodified'
  assert_contains "$verify_output" \
    'hardening sysctl drop-in is present, mode 644, and unmodified'
  assert_contains "$verify_output" \
    'every dotfiles watch rule is loaded in the running kernel'
  # Manual-assurance areas are labelled as such instead of counted as proof.
  assert_contains "$verify_output" 'manual assurance:'
  assert_contains "$verify_output" 'Mount options (manual assurance, not verified)'
  assert_contains "$verify_output" 'kernel.yama.ptrace_scope = 1'
  assert_contains "$verify_output" 'kernel.kptr_restrict = 2'
  assert_contains "$verify_output" 'kernel.dmesg_restrict = 1'

  for credential_file in "${credential_files[@]}"; do
    assert_contains "$verify_output" \
      "$credential_file permissions are private (mode 600)"
  done
  assert_not_contains "$verify_output" "id_ed25519.pub"

  if [[ "$seed_sshd" == "true" ]]; then
    assert_contains "$verify_output" 'sshd hardening drop-in applied'
    assert_contains "$verify_output" \
      "sshd's effective configuration has PermitRootLogin no, MaxAuthTries 3, LoginGraceTime 20"
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
    local sudoers_dropin="$fake_root/etc/sudoers.d/90-dotfiles-hardening"
    local sysctl_dropin="$fake_root/etc/sysctl.d/90-dotfiles-hardening.conf"
    local ssh_dropin="$fake_root/etc/ssh/sshd_config.d/00-dotfiles-hardening.conf"
    local backup="$test_root/state/mutation-backup"

    run_verify() {
      local sudo_calls_before
      sudo_calls_before="$(wc -l <"$command_log")"
      run_capture "${test_environment[@]}" "$@" \
        "$repo_root/platforms/fedora/scripts/verify-hardening.sh"
      assert_non_interactive_sudo "$command_log" "$sudo_calls_before"
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
    cp -p "$faillock_conf" "$backup"
    sed -i 's/^unlock_time = 900$/unlock_time = 5/' "$faillock_conf"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      'the faillock policy in /etc/security/faillock.conf is not in effect: its dotfiles block changed'
    assert_contains "$TEST_OUTPUT" \
      "line 3 is 'unlock_time = 5', expected 'unlock_time = 900'"
    cp -p "$backup" "$faillock_conf"

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
    assert_contains "$TEST_OUTPUT" \
      "line 2 is 'PermitRootLogin yes', expected 'PermitRootLogin no'"
    cp -p "$backup" "$ssh_dropin"

    # 6b. A policy line that was not removed but overruled, by inserting the
    #     opposite directive above it. sshd_config(5) takes the first value it
    #     reads for a keyword, so root SSH login is on while every line the
    #     installer wrote is still present, in its original order. Asking
    #     whether each expected line occurs somewhere in the file cannot see
    #     this; only comparing the whole file against what was written can.
    cp -p "$ssh_dropin" "$backup"
    sed -i '0,/^PermitRootLogin no$/s//PermitRootLogin yes\nPermitRootLogin no/' \
      "$ssh_dropin"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      'sshd hardening drop-in applied no longer matches the policy'
    assert_contains "$TEST_OUTPUT" \
      "line 2 is 'PermitRootLogin yes', expected 'PermitRootLogin no'"
    cp -p "$backup" "$ssh_dropin"

    # 6f-6j. The drop-in is byte-identical and mode 644 in every case below,
    #     so each one passes check_owned_root_file; only the configuration
    #     sshd actually resolved can tell them apart. sshd_config(5) keeps the
    #     first value it reads for a keyword, and that rule runs across the
    #     Include boundary.
    local sshd_config="$fake_root/etc/ssh/sshd_config"
    local sshd_dropin_dir="$fake_root/etc/ssh/sshd_config.d"
    cp -p "$sshd_config" "$backup"

    # 6f. The obvious one: an sshd_config that never includes the drop-ins
    #     and permits root login itself.
    printf 'PermitRootLogin yes\nSubsystem sftp /usr/libexec/openssh/sftp-server\n' \
      >"$sshd_config"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      'sshd hardening drop-in applied is present, mode 644, and unmodified'
    assert_contains "$TEST_OUTPUT" \
      "sshd's effective configuration has PermitRootLogin yes, but the hardening drop-in declares PermitRootLogin no"
    # Without the Include the drop-in's other two values are not in effect
    # either, and each is named.
    assert_contains "$TEST_OUTPUT" 'has MaxAuthTries 6, but'
    assert_contains "$TEST_OUTPUT" 'has LoginGraceTime 120, but'
    cp -p "$backup" "$sshd_config"

    # 6g. The shape that passed: one line above the Include.
    sed -i '1i PermitRootLogin yes' "$sshd_config"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      "sshd's effective configuration has PermitRootLogin yes, but the hardening drop-in declares PermitRootLogin no"
    assert_not_contains "$TEST_OUTPUT" 'has MaxAuthTries'
    cp -p "$backup" "$sshd_config"

    # 6h. The same override from inside the drop-in directory: a file that
    #     still sorts before 00-dotfiles-hardening.conf, and a zero
    #     LoginGraceTime beside it. Anaconda's 01-permitrootlogin.conf, which
    #     this fixture carries throughout, no longer can; a hand-written 00-
    #     that sorts ahead of it still can, and the verifier names it.
    printf 'PermitRootLogin yes\nLoginGraceTime 0\n' \
      >"$sshd_dropin_dir/00-admin.conf"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      "sshd's effective configuration has PermitRootLogin yes, but"
    assert_contains "$TEST_OUTPUT" \
      "sshd's effective configuration has LoginGraceTime 0, but the hardening drop-in declares LoginGraceTime 20"

    # 6i. Control: the same file sorting after this profile's drop-in is
    #     overruled by it, so the policy is in effect and nothing fails. A
    #     check that merely looked for `PermitRootLogin yes` anywhere would
    #     fail here, and would already fail on Anaconda's file.
    mv -- "$sshd_dropin_dir/00-admin.conf" "$sshd_dropin_dir/99-local.conf"
    run_verify
    assert_success
    assert_contains "$TEST_OUTPUT" \
      "sshd's effective configuration has PermitRootLogin no, MaxAuthTries 3, LoginGraceTime 20"
    rm -f -- "$sshd_dropin_dir/99-local.conf"

    # 6j. sshd cannot resolve its configuration at all. That is not a pass:
    #     nothing about the policy in effect was observed, and the run says
    #     so by name.
    rm -f -- "$sshd_config"
    run_verify
    assert_success
    assert_contains "$TEST_OUTPUT" \
      "sshd -T could not report the configuration sshd would run with"
    assert_contains "$TEST_OUTPUT" 'No such file or directory'
    assert_not_contains "$TEST_OUTPUT" "sshd's effective configuration has"
    cp -p "$backup" "$sshd_config"

    # 6t. sshd -T does not answer at all. The probe is bounded the way sudo -l
    #     is, so the run finishes and says what it could not see instead of
    #     waiting on it.
    run_verify MOCK_SSHD_T=hang HARDENING_PROBE_TIMEOUT=1s
    assert_success
    assert_contains "$TEST_OUTPUT" 'sshd -T did not answer within 1s'
    assert_not_contains "$TEST_OUTPUT" "sshd's effective configuration has"

    # 6u. sshd -T prints the whole compliant configuration and then never
    #     exits. What it printed is not an answer it stood behind, so it is
    #     not a pass: an unbounded probe waits it out and then reports the
    #     policy in effect, which is exactly the verdict nobody observed.
    run_verify MOCK_SSHD_T=stall HARDENING_PROBE_TIMEOUT=1s
    assert_success
    assert_contains "$TEST_OUTPUT" 'sshd -T did not answer within 1s'
    assert_not_contains "$TEST_OUTPUT" "sshd's effective configuration has"

    # 6m-6s. The sudoers drop-in is byte-identical and mode 440 in every case
    #     below, so each one passes check_owned_root_file; only the policy
    #     sudo itself reports can tell them apart. sudoers(5) runs the other
    #     way from sshd: the last Defaults entry read for a setting wins, and
    #     #includedir reads the directory in lexical order, so anything read
    #     after 90-dotfiles-hardening overrides it.
    local sudoers="$fake_root/etc/sudoers"
    local sudoers_dir="$fake_root/etc/sudoers.d"
    local sudo_user
    sudo_user="$(id -un)"
    cp -p "$sudoers" "$backup"

    # 6m. The obvious one: a later drop-in switches command logging off.
    install -m 0440 /dev/stdin "$sudoers_dir/99-local" <<<'Defaults !logfile'
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      'sudo logfile drop-in is present, mode 440, and unmodified'
    assert_contains "$TEST_OUTPUT" \
      "sudo's effective policy has !logfile, but the hardening drop-in declares logfile=/var/log/sudo.log"

    # 6n. Control: the same file sorting before this profile's drop-in is
    #     overruled by it, so logging is on and nothing fails. A check that
    #     looked for `!logfile` anywhere in the listing would fail here.
    mv -- "$sudoers_dir/99-local" "$sudoers_dir/10-local"
    run_verify
    assert_success
    assert_contains "$TEST_OUTPUT" \
      "sudo's effective policy has logfile=/var/log/sudo.log"
    rm -f -- "$sudoers_dir/10-local"

    # 6o. The negation scoped to this user and buried after another entry on
    #     the line: not a line of its own, not global, and still the last word
    #     for every command this user runs through sudo.
    install -m 0440 /dev/stdin "$sudoers_dir/99-local" \
      <<<"Defaults:$sudo_user env_reset, !logfile"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" "sudo's effective policy has !logfile, but"
    rm -f -- "$sudoers_dir/99-local"

    # 6p. Logging left on but moved: the expected path is a prefix of the new
    #     one, so a substring match on the listing takes it for the policy.
    install -m 0440 /dev/stdin "$sudoers_dir/99-local" \
      <<<'Defaults logfile="/var/log/sudo.log.off"'
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      "sudo's effective policy has logfile=/var/log/sudo.log.off, but"
    rm -f -- "$sudoers_dir/99-local"

    # 6q. The override from /etc/sudoers itself, below its includedir line,
    #     which is read after every drop-in.
    printf 'Defaults !logfile\n' >>"$sudoers"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" "sudo's effective policy has !logfile, but"
    cp -p "$backup" "$sudoers"

    # 6r. sudo answers but not with a policy: refused outright, or a listing
    #     with no Defaults section. Neither is a pass, and neither is drift.
    run_verify MOCK_SUDO_LIST=refused
    assert_success
    assert_contains "$TEST_OUTPUT" \
      'sudo -l could not report the policy sudo applies (exit 1: Sorry, user'
    assert_not_contains "$TEST_OUTPUT" "sudo's effective policy has"
    run_verify MOCK_SUDO_LIST=unrecognized
    assert_success
    assert_contains "$TEST_OUTPUT" \
      "sudo -l answered without a 'Matching Defaults entries' section"
    assert_not_contains "$TEST_OUTPUT" "sudo's effective policy has"

    # 6s. sudo does not answer at all. The probe is bounded, so the run
    #     finishes and says what it could not see instead of waiting on it.
    run_verify MOCK_SUDO_LIST=hang HARDENING_PROBE_TIMEOUT=1s
    assert_success
    assert_contains "$TEST_OUTPUT" 'sudo -l did not answer within 1s'
    assert_not_contains "$TEST_OUTPUT" "sudo's effective policy has"

    # 6c. Every directive commented out. The file still contains the text of
    #     each policy line, and enforces none of them.
    cp -p "$faillock_conf" "$backup"
    sed -i 's/^\([^#]\)/# \1/' "$faillock_conf"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" 'its dotfiles block changed'
    assert_contains "$TEST_OUTPUT" "line 2 is '# deny = 5'"
    cp -p "$backup" "$faillock_conf"

    # 6d. Values loosened by extending them rather than shortening them:
    #     deny = 50 locks out after fifty attempts, unlock_time = 9000 is two
    #     and a half hours. Both expected lines are still substrings of the
    #     file, which is the shape mutation 2 above does not cover.
    cp -p "$faillock_conf" "$backup"
    sed -i 's/^deny = 5$/deny = 50/;s/^unlock_time = 900$/unlock_time = 9000/' \
      "$faillock_conf"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" 'its dotfiles block changed'
    assert_contains "$TEST_OUTPUT" "line 2 is 'deny = 50', expected 'deny = 5'"
    cp -p "$backup" "$faillock_conf"

    # 6d2-6d6. The block intact in every case below, so only reading the file
    #     the way pam_faillock does can tell them apart: read_config_file lets
    #     a later line for a key replace an earlier one, and pam_faillock
    #     applies its module arguments after the file.
    cp -p "$faillock_conf" "$backup"

    # 6d2. The obvious one: a line after the block.
    printf 'deny = 50\n' >>"$faillock_conf"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      'pam_faillock reads deny = 50 from it, but the dotfiles block sets deny = 5'
    cp -p "$backup" "$faillock_conf"

    # 6d3. The same override in the spelling a line-for-line match does not
    #     read: no spaces, and a trailing comment.
    printf 'unlock_time=1 # testing\n' >>"$faillock_conf"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" 'pam_faillock reads unlock_time = 1 from it'
    cp -p "$backup" "$faillock_conf"

    # 6d4. Control: the same line above the block is replaced by it, so the
    #     policy is in effect and nothing fails.
    sed -i '1i deny = 50' "$faillock_conf"
    run_verify
    assert_success
    assert_contains "$TEST_OUTPUT" 'pam_faillock reads deny = 5, unlock_time = 900'
    cp -p "$backup" "$faillock_conf"

    # 6d5. The block gone, as on a machine installed while the policy went to
    #     a faillock.conf.d drop-in pam_faillock never read.
    sed '/^# BEGIN dotfiles/,/^# END dotfiles/d' "$backup" >"$faillock_conf"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" 'it has no dotfiles block'
    cp -p "$backup" "$faillock_conf"

    # 6d6. The file untouched, and the PAM stack passing the key instead.
    local system_auth="$fake_root/etc/pam.d/system-auth"
    cp -p "$system_auth" "$test_root/state/system-auth-backup"
    sed -i 's/pam_faillock.so preauth silent/& deny=50/' "$system_auth"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      '/etc/pam.d/system-auth passes deny=50 to pam_faillock, which overrides /etc/security/faillock.conf'
    cp -p "$test_root/state/system-auth-backup" "$system_auth"

    # 6e. The two audit watches no expected-line list ever named: the
    #     installer writes five rules, and /etc/group and /etc/sudoers.d/ were
    #     asserted nowhere, so deleting them was invisible.
    local audit_rules="$fake_root/etc/audit/rules.d/90-dotfiles-hardening.rules"
    cp -p "$audit_rules" "$backup"
    sed -i '\#/etc/group#d;\#/etc/sudoers.d/#d' "$audit_rules"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" 'auditd watch rules no longer matches the policy'
    assert_contains "$TEST_OUTPUT" "expected '-w /etc/group -p wa -k dotfiles-identity'"
    cp -p "$backup" "$audit_rules"

    # 5b. A kernel that answers with a ruleset that is not this profile's. The
    #     rules file is intact and auditd is running, so only the loaded rules
    #     themselves distinguish this from a healthy machine. A decoy rule
    #     carrying the identity key as a substring used to satisfy the check.
    run_verify MOCK_AUDITCTL_RULES='-w /tmp/decoy -p r -k dotfiles-identity-DISABLED'
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      "'-w /etc/passwd -p wa -k dotfiles-identity' is not loaded"
    assert_contains "$TEST_OUTPUT" 'present but ineffective'

    # 5c. A partially loaded ruleset: the first watch is in the kernel and the
    #     rest are not, which the failure has to name.
    run_verify MOCK_AUDITCTL_RULES='-w /etc/passwd -p wa -k dotfiles-identity'
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      "'-w /etc/shadow -p wa -k dotfiles-identity' is not loaded"

    # 6k. pam_faillock switched off after installation: authselect no longer
    #     lists the feature, while the faillock policy is untouched.
    local authselect_features="$test_root/state/authselect-features"
    cp -p "$authselect_features" "$backup"
    : >"$authselect_features"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      'authselect no longer reports with-faillock enabled'
    assert_contains "$TEST_OUTPUT" 'pam_faillock reads deny = 5, unlock_time = 900'

    # 6l. Defensive, not an output seen in the wild: a feature whose name
    #     only contains with-faillock. authselect lists enabled features one
    #     per line and a custom profile may name its own, so the lockout is
    #     matched as its whole line; a substring match took this for it.
    printf 'with-faillock-reporting\n' >"$authselect_features"
    run_verify
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      'authselect no longer reports with-faillock enabled'
    cp -p "$backup" "$authselect_features"

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

    # 8b. sudo will not answer without a password, and the drop-ins are not
    #     readable unprivileged. Verification must say what it could not read
    #     and carry on, because an unreadable control is not an absent one:
    #     reporting drift here would send someone to reinstall a machine that
    #     is fine, and the run must not stop on a prompt either.
    run_verify HARDENING_ROOT="$unreadable_root" MOCK_SUDO_UNAUTHORIZED=true
    assert_success
    assert_contains "$TEST_OUTPUT" \
      'faillock policy could not be read without a sudo password'
    assert_contains "$TEST_OUTPUT" \
      'sudo logfile drop-in could not be read without a sudo password'
    assert_contains "$TEST_OUTPUT" \
      'auditd watch rules could not be read without a sudo password'
    assert_contains "$TEST_OUTPUT" \
      'hardening sysctl drop-in could not be read without a sudo password'
    assert_contains "$TEST_OUTPUT" \
      'sshd hardening drop-in applied could not be read without a sudo password'
    assert_contains "$TEST_OUTPUT" 'reading the loaded audit rules needs sudo'
    assert_contains "$TEST_OUTPUT" \
      "reading sshd's effective configuration needs sudo"
    assert_contains "$TEST_OUTPUT" \
      "reading sudo's effective policy needs sudo"
    assert_contains "$TEST_OUTPUT" "run 'sudo -v' first"
    assert_not_contains "$TEST_OUTPUT" 'is missing:'
    assert_not_contains "$TEST_OUTPUT" 'no longer matches the policy'

    # 8c. The same absent drop-ins with sudo able to answer are drift, and
    #     have to be reported as such. Without this case 8b would pass just as
    #     well on a verifier that had stopped checking these files at all.
    run_verify HARDENING_ROOT="$unreadable_root"
    assert_failure
    assert_contains "$TEST_OUTPUT" \
      '/etc/security/faillock.conf is missing, so pam_faillock runs on its built-in defaults'
    assert_contains "$TEST_OUTPUT" 'install-hardening.sh'
    assert_not_contains "$TEST_OUTPUT" 'could not be read without a sudo password'

    # 8d. SELinux gone from the kernel entirely, on a machine whose own
    #     installation record says it had SELinux. That is what booting with
    #     selinux=0 produces, and it was reported as environmental -- the
    #     wording for a container, where the profile genuinely cannot reach
    #     the host kernel.
    run_verify SELINUX_FS_ROOT="$test_root/absent-selinux-fs"
    assert_failure
    assert_contains "$TEST_OUTPUT" 'recorded selinux_mode=enforcing'
    assert_contains "$TEST_OUTPUT" '/proc/cmdline'

    # 8e. The container case the warning exists for: the record itself says
    #     SELinux was unavailable at installation, so nothing was lost.
    cp -p "$state_file" "$backup"
    sed -i 's/^selinux_mode=enforcing$/selinux_mode=unavailable/' "$state_file"
    run_verify SELINUX_FS_ROOT="$test_root/absent-selinux-fs"
    assert_success
    assert_contains "$TEST_OUTPUT" 'SELinux is not available on this kernel'
    assert_not_contains "$TEST_OUTPUT" 'no longer does'
    cp -p "$backup" "$state_file"

    # 8f. apply_updates is read with dnf's own boolean vocabulary. libdnf5
    #     lower-cases the value and accepts 1/yes/true/on and 0/no/false/off,
    #     so a machine set to `true` auto-installs updates and used to be
    #     reported as downloading and reporting only.
    local dnf_root="$test_root/dnf-root"
    mkdir -p "$dnf_root/etc/dnf"
    local automatic_conf="$dnf_root/etc/dnf/automatic.conf"

    printf '[commands]\napply_updates = true\n' >"$automatic_conf"
    run_verify DNF_AUTOMATIC_ROOT="$dnf_root"
    assert_success
    assert_contains "$TEST_OUTPUT" 'apply_updates=true'
    assert_contains "$TEST_OUTPUT" 'this system auto-installs updates'

    printf '[commands]\napply_updates = Off\n' >"$automatic_conf"
    run_verify DNF_AUTOMATIC_ROOT="$dnf_root"
    assert_success
    assert_contains "$TEST_OUTPUT" 'downloads/reports only'
    assert_not_contains "$TEST_OUTPUT" 'auto-installs updates'

    printf '[commands]\napply_updates = banana\n' >"$automatic_conf"
    run_verify DNF_AUTOMATIC_ROOT="$dnf_root"
    assert_success
    assert_contains "$TEST_OUTPUT" 'could not read apply_updates'
    assert_not_contains "$TEST_OUTPUT" 'downloads/reports only'

    printf '[commands]\ndownload_updates = yes\n' >"$automatic_conf"
    run_verify DNF_AUTOMATIC_ROOT="$dnf_root"
    assert_success
    assert_contains "$TEST_OUTPUT" 'sets no apply_updates'

    # 8g. Credentials other users can read. The profile never changes these
    #     files, but a group- or world-readable private key is a defect the
    #     audit exists to name, one by one, wherever it looked.
    for credential_file in "${credential_files[@]}"; do
      chmod 0644 "$credential_file"
    done
    run_verify
    assert_failure
    for credential_file in "${credential_files[@]}"; do
      assert_contains "$TEST_OUTPUT" \
        "$credential_file is readable by group/other (mode 644)"
    done
    assert_not_contains "$TEST_OUTPUT" "id_ed25519.pub"
    for credential_file in "${credential_files[@]}"; do
      chmod 0600 "$credential_file"
    done

    # 9. An unmet *recommendation* stays a warning: disabled Secure Boot is
    #    firmware state this profile never touches.
    run_verify MOCK_SECURE_BOOT=disabled
    assert_success
    assert_contains "$TEST_OUTPUT" 'Secure Boot is disabled'
    assert_contains "$TEST_OUTPUT" 'never changes'

    # 10. An unselected profile must not fail merely because the optional
    #     artifacts it never installed are absent.
    rm -f -- "$state_file" "$faillock_conf" "$sudoers_dropin" \
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

# tests/fixtures/hardening/ is the statement of this profile's policy that
# is not generated from platforms/fedora/lib/hardening.sh. Both halves of the
# profile read that table -- the installer to write each drop-in, the verifier
# to decide whether the one on disk is still it -- so they can never disagree,
# including when a value in the table is wrong: deleting the watch on
# /etc/sudoers.d/ and setting LoginGraceTime 0 there left every hardening suite
# green, the verifier's own "every dotfiles watch rule is loaded" among them.
# The fixture holds each drop-in's exact bytes, and dropins.tsv its path and
# mode, written out by hand. A change to the policy therefore has to be made
# twice, and the second time is the one a reviewer reads.
#
# compare_golden_dropins <hardening.sh>: prints one line per difference
# between that copy of the table and the fixture; silent when they agree.
compare_golden_dropins() {
  local library="$1"
  local golden="$repo_root/tests/fixtures/hardening"

  env DOTFILES_ROOT_DIR="$repo_root" HARDENING_LIBRARY="$library" \
    GOLDEN="$golden" bash -c '
      set -euo pipefail
      source "$DOTFILES_ROOT_DIR/common/lib/common.sh"
      source "$HARDENING_LIBRARY"

      # The names the table answers for, read from its code rather than from
      # a list here, so a drop-in added to the table without a fixture is
      # reported rather than never compared.
      declared="$(declare -f hardening_dropin_content |
        sed -n "s/^ *\([a-z][a-z-]*\))\$/\1/p" | sort)"
      pinned="$(cut -f1 "$GOLDEN/dropins.tsv" | sort)"
      [[ -n "$declared" ]] || { echo "no drop-in names read from the table"; exit 0; }
      [[ "$declared" == "$pinned" ]] ||
        echo "the table declares [$(echo $declared)] but the fixture pins [$(echo $pinned)]"

      while IFS=$'"'"'\t'"'"' read -r name path mode; do
        actual="$(hardening_dropin_path "$name")"
        [[ "$actual" == "$path" ]] ||
          echo "$name: path is $actual, the fixture says $path"
        actual="$(hardening_dropin_mode "$name")"
        [[ "$actual" == "$mode" ]] ||
          echo "$name: mode is $actual, the fixture says $mode"
        # The sentinel keeps trailing newlines, which command substitution
        # would otherwise strip from both sides alike.
        actual="$(hardening_dropin_content "$name"; printf x)"
        expected="$(cat -- "$GOLDEN/$name"; printf x)"
        [[ "$actual" == "$expected" ]] ||
          echo "$name: $(hardening_dropin_difference \
            "$(cat -- "$GOLDEN/$name")" "$(hardening_dropin_content "$name")")"
      done <"$GOLDEN/dropins.tsv"
    '
}

run_golden_dropin_contract() {
  test_new_root
  local scratch="$TEST_ROOT/hardening.sh"
  local differences

  differences="$(compare_golden_dropins \
    "$repo_root/platforms/fedora/lib/hardening.sh")"
  [[ -z "$differences" ]] ||
    _test_die "the hardening policy table no longer matches tests/fixtures/hardening/ -- change both, deliberately:\n$differences"

  # The comparison has to be able to fail, and to say which value moved. Each
  # mutation is one literal replacement in a scratch copy of the library.
  local library
  library="$(<"$repo_root/platforms/fedora/lib/hardening.sh")"
  mutate() {
    local from="$1" to="$2"
    [[ "$library" == *"$from"* ]] ||
      _test_die "golden mutation target not found in hardening.sh: $from"
    printf '%s\n' "${library/"$from"/"$to"}" >"$scratch"
  }

  # Obvious: a value changed in place.
  mutate "'LoginGraceTime 20'" "'LoginGraceTime 0'"
  differences="$(compare_golden_dropins "$scratch")"
  assert_contains "$differences" \
    "ssh: line 4 is 'LoginGraceTime 0', expected 'LoginGraceTime 20'"

  # Subtle, and the one that passed every suite: a whole rule deleted, which
  # leaves every remaining line exactly as it was.
  mutate $' \\\n      \'-w /etc/sudoers.d/ -p wa -k dotfiles-sudoers\'' ''
  differences="$(compare_golden_dropins "$scratch")"
  assert_contains "$differences" \
    "auditd-rules: line 5 is missing, expected '-w /etc/sudoers.d/ -p wa -k dotfiles-sudoers'"

  # A mode loosened.
  mutate "sudo-logfile) printf '0440\\n'" "sudo-logfile) printf '0444\\n'"
  differences="$(compare_golden_dropins "$scratch")"
  assert_contains "$differences" "sudo-logfile: mode is 0444, the fixture says 0440"

  # A drop-in the fixture has never heard of.
  mutate $'  ssh)\n    printf \'%s\\n\' \\\n      \'# Managed' \
    $'  ssh-extra) printf x ;;\n  ssh)\n    printf \'%s\\n\' \\\n      \'# Managed'
  differences="$(compare_golden_dropins "$scratch")"
  assert_contains "$differences" \
    "the table declares [auditd-rules faillock ssh ssh-extra sudo-logfile sysctl]"

  printf 'PASS: the hardening policy table matches its hand-written fixture\n'
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

  # run_answer <label> <expected-status> <expected-message> <answer-or-empty> [option...]
  #
  # The answer is fed to the prompt; an empty answer means a closed standard
  # input, which `confirm` documents as declined rather than as a silently
  # inherited yes. The state file is checked after every run: neither mode may
  # record a profile the user did not agree to.
  run_answer() {
    local label="$1" expect="$2" expected_message="$3" answer="$4"
    shift 4
    local status=0 output
    local answer_file="$test_root/state/answer"

    rm -f -- "$state_file"
    # An empty answer file is an immediate EOF, which is what `read` sees on a
    # closed standard input; an unattended run must not inherit a yes there.
    if [[ -n "$answer" ]]; then printf '%s\n' "$answer" >"$answer_file"; else : >"$answer_file"; fi

    output="$("${test_environment[@]}" \
      "$repo_root/platforms/fedora/scripts/install-hardening.sh" "$@" \
      <"$answer_file" 2>&1)" || status=$?

    case "$expect" in
    agreed)
      ((status == 0)) ||
        _test_die "[$label] a hardening confirmation that was agreed to exited $status; output: $output"
      ;;
    stopped)
      ((status != 0)) ||
        _test_die "[$label] a hardening profile that was not agreed to exited 0, so the plan records it as installed; output: $output"
      ;;
    *) _test_die "run_answer: unknown expectation: $expect" ;;
    esac
    [[ -z "$expected_message" ]] || assert_contains "$output" "$expected_message"
    [[ ! -e "$state_file" ]] ||
      _test_die "[$label] the run wrote $state_file"
  }

  run_answer 'declined' stopped 'Hardening installation declined' n
  run_answer 'unparseable answer' stopped 'Invalid confirmation response' maybe
  run_answer 'no answer on standard input' stopped 'Hardening installation declined' ''

  # --confirm is how platforms/fedora/install.sh asks during preflight, before
  # any step has run. It must report the same three answers in its exit status
  # and change nothing at all, including on a yes: the profile is installed by
  # the plan's own step, later.
  run_answer '--confirm accepted' agreed '' y --confirm
  run_answer '--confirm declined' stopped 'Hardening installation declined' n --confirm
  run_answer '--confirm unparseable' stopped 'Invalid confirmation response' maybe --confirm
  run_answer '--confirm with no answer' stopped 'Hardening installation declined' '' --confirm

  # A mode that cannot report the answer in its exit status is refused rather
  # than silently preferred over the question.
  run_answer '--confirm --non-interactive' stopped \
    '--confirm and --non-interactive cannot be combined' y --confirm --non-interactive
  run_answer '--confirm --dry-run' stopped \
    '--confirm and --dry-run cannot be combined' y --confirm --dry-run
  run_answer '--confirm --validate' stopped \
    '--confirm and --validate cannot be combined' y --confirm --validate

  printf 'PASS: a hardening confirmation that is not a yes stops the run instead of completing it\n'
}

run_confirmation_contract
run_golden_dropin_contract
run_root_prefix_contract unset
run_root_prefix_contract empty
run_root_prefix_contract prefix
run_selinux_config_contract
run_faillock_config_contract
run_scenario "hardening install/verify with sshd absent (default Fedora Workstation)" false
run_scenario "hardening install/verify with sshd active" true

printf '\nFedora hardening install/verify and idempotency tests passed.\n'
