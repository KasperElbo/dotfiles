#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap

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
  printf 'firewalld.service\n' >>"$active_units"
  printf 'firewalld.service\n' >>"$enabled_units"

  if [[ "$seed_sshd" == "true" ]]; then
    printf 'sshd.service\n' >>"$active_units"
    printf 'sshd.service\n' >>"$enabled_units"
  fi

  # Package-manager calls use the shared exact-argv stub. The scenario keeps
  # stateful security/service commands local because they model Fedora state.
  test_stub_init "$test_root"
  test_stub_install "$test_root" dnf
  test_stub_install "$test_root" sudo
  test_stub_install "$test_root" systemctl
  test_stub_allow "$test_root" dnf install -y dnf5-plugin-automatic
  test_stub_allow "$test_root" sudo setenforce 1
  test_stub_allow "$test_root" sudo test -f /etc/selinux/config
  test_stub_allow "$test_root" sudo grep -q '^SELINUX=' /etc/selinux/config
  test_stub_allow "$test_root" sudo sed -i \
    's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
  test_stub_allow "$test_root" sudo authselect enable-feature with-faillock
  test_stub_allow "$test_root" sudo dnf install -y dnf5-plugin-automatic
  test_stub_allow "$test_root" sudo test -f \
    /etc/security/faillock.conf.d/90-dotfiles-hardening.conf
  test_stub_allow "$test_root" sudo test -f \
    /etc/sudoers.d/90-dotfiles-hardening
  test_stub_allow "$test_root" sudo test -f \
    /etc/audit/rules.d/90-dotfiles-hardening.rules
  test_stub_allow "$test_root" sudo test -f \
    /etc/sysctl.d/90-dotfiles-hardening.conf
  test_stub_allow "$test_root" sudo cat \
    /etc/audit/rules.d/90-dotfiles-hardening.rules
  test_stub_allow "$test_root" sudo sysctl -p \
    /etc/sysctl.d/90-dotfiles-hardening.conf
  test_stub_allow "$test_root" sudo auditctl -l
  test_stub_allow "$test_root" sudo systemctl enable --now auditd.service
  test_stub_allow "$test_root" sudo systemctl enable --now dnf5-automatic.timer

  test_stub_allow "$test_root" sudo install -D -m 0644 -o root -g root \
    "$test_root/state/tmp-1" \
    /etc/security/faillock.conf.d/90-dotfiles-hardening.conf
  test_stub_allow "$test_root" sudo install -D -m 0440 -o root -g root \
    "$test_root/state/tmp-3" /etc/sudoers.d/90-dotfiles-hardening
  test_stub_allow "$test_root" sudo install -D -m 0640 -o root -g root \
    "$test_root/state/tmp-4" /etc/audit/rules.d/90-dotfiles-hardening.rules
  test_stub_allow "$test_root" sudo install -D -m 0644 -o root -g root \
    "$test_root/state/tmp-5" /etc/sysctl.d/90-dotfiles-hardening.conf

  if [[ "$seed_sshd" == "true" ]]; then
    test_stub_allow "$test_root" sudo test -f \
      /etc/ssh/sshd_config.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo install -D -m 0644 -o root -g root \
      "$test_root/state/tmp-6" \
      /etc/ssh/sshd_config.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-9" \
      /etc/security/faillock.conf.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-11" \
      /etc/sudoers.d/90-dotfiles-hardening
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-12" \
      /etc/audit/rules.d/90-dotfiles-hardening.rules
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-13" \
      /etc/sysctl.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-14" \
      /etc/ssh/sshd_config.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo sshd -t
    test_stub_allow "$test_root" sudo systemctl reload sshd.service
    test_stub_allow "$test_root" sudo grep -Fqx 'PermitRootLogin no' \
      /etc/ssh/sshd_config.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo grep -Fqx 'MaxAuthTries 3' \
      /etc/ssh/sshd_config.d/90-dotfiles-hardening.conf
  else
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-8" \
      /etc/security/faillock.conf.d/90-dotfiles-hardening.conf
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-10" \
      /etc/sudoers.d/90-dotfiles-hardening
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-11" \
      /etc/audit/rules.d/90-dotfiles-hardening.rules
    test_stub_allow "$test_root" sudo cmp -s "$test_root/state/tmp-12" \
      /etc/sysctl.d/90-dotfiles-hardening.conf
  fi

  systemctl_contracts=(
    'is-enabled --quiet auditd.service'
    'enable --now auditd.service'
    'is-active --quiet sshd.service'
    'is-enabled --quiet sshd.service'
    'reload sshd.service'
    'is-enabled --quiet dnf5-automatic.timer'
    'enable --now dnf5-automatic.timer'
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

  cat >"$mock_bin/mktemp" <<'EOF'
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
printf 'SecureBoot enabled\n'
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
test | cmp | rm | grep | sed | cat)
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
    "SELINUX_FS_ROOT=$selinux_fs_root"
    "SELINUX_STATE=$selinux_state"
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
  assert_contains "$verify_output" 'firewalld is active'
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

  printf 'PASS: %s\n' "$scenario_name"
}

run_scenario "hardening install/verify with sshd absent (default Fedora Workstation)" false
run_scenario "hardening install/verify with sshd active" true

printf '\nFedora hardening install/verify and idempotency tests passed.\n'
