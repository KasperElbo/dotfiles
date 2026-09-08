#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

run_scenario() {
  local scenario_name="$1"
  local seed_sshd="$2"

  local test_root
  test_root="$(mktemp -d)"

  local mock_bin="$test_root/bin"
  local command_log="$test_root/commands.log"
  local fake_root="$test_root/fake-root"
  local selinux_state="$test_root/state/selinux"
  local active_units="$test_root/state/active-units"
  local enabled_units="$test_root/state/enabled-units"
  local sysctl_kv="$test_root/state/sysctl.kv"

  mkdir -p "$mock_bin" "$test_root/home" "$test_root/xdg" \
    "$fake_root/etc/selinux" "$(dirname "$selinux_state")"
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

  cat >"$mock_bin/dnf" <<'EOF'
#!/usr/bin/env bash
printf 'dnf %s\n' "$*" >>"$COMMAND_LOG"
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

  cat >"$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$COMMAND_LOG"
cmd="$1"
shift || true
case "$cmd" in
is-active)
  args=("$@")
  grep -qx "${args[-1]}" "$ACTIVE_UNITS" 2>/dev/null
  exit $?
  ;;
is-enabled)
  args=("$@")
  grep -qx "${args[-1]}" "$ENABLED_UNITS" 2>/dev/null
  exit $?
  ;;
enable)
  for a in "$@"; do
    case "$a" in --*) continue ;; esac
    grep -qx "$a" "$ENABLED_UNITS" 2>/dev/null || printf '%s\n' "$a" >>"$ENABLED_UNITS"
    grep -qx "$a" "$ACTIVE_UNITS" 2>/dev/null || printf '%s\n' "$a" >>"$ACTIVE_UNITS"
  done
  ;;
esac
exit 0
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

  cat >"$mock_bin/sudo" <<'SUDO_EOF'
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
  "$cmd" "$@"
  ;;
esac
SUDO_EOF

  chmod +x "$mock_bin"/*
  printf 'ID=fedora\n' >"$test_root/os-release"

  local test_environment=(
    env
    "HOME=$test_root/home"
    "XDG_CONFIG_HOME=$test_root/xdg"
    "XDG_DATA_HOME=$test_root/home/.local/share"
    "PATH=$mock_bin:$PATH"
    "COMMAND_LOG=$command_log"
    "OS_RELEASE_FILE=$test_root/os-release"
    "FAKE_ROOT=$fake_root"
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
    printf '[%s] install-hardening.sh failed\n' "$scenario_name" >&2
    exit 1
  fi

  state_file="$test_root/xdg/dotfiles/hardening.conf"
  [[ -f "$state_file" ]] ||
    {
      printf '[%s] state file missing: %s\n' "$scenario_name" "$state_file" >&2
      exit 1
    }
  first_state="$(sha256sum "$state_file")"

  if ! run_install; then
    cat "$test_root/install-output.log" >&2
    printf '[%s] rerun of install-hardening.sh failed\n' "$scenario_name" >&2
    exit 1
  fi
  second_state="$(sha256sum "$state_file")"

  [[ "$first_state" == "$second_state" ]] || {
    printf '[%s] hardening.conf changed on rerun\n' "$scenario_name" >&2
    exit 1
  }

  grep -Fqx 'profile=hardening' "$state_file"
  grep -Fqx 'selinux_mode=enforcing' "$state_file"
  grep -Fqx 'faillock=true' "$state_file"
  grep -Fqx 'sysctl_ptrace_scope=1' "$state_file"
  grep -Fqx 'sysctl_kptr_restrict=2' "$state_file"
  grep -Fqx 'sysctl_dmesg_restrict=1' "$state_file"
  grep -Fqx 'dnf_automatic=notifyonly' "$state_file"

  grep -Fq 'sudo setenforce 1' "$command_log"
  grep -Fq 'sudo authselect enable-feature with-faillock' "$command_log"
  grep -Fq 'sudo dnf install -y dnf-automatic' "$command_log"
  grep -Fq 'systemctl enable --now dnf-automatic-notifyonly.timer' "$command_log"

  grep -Fqx 'kernel.yama.ptrace_scope = 1' \
    "$fake_root/etc/sysctl.d/90-dotfiles-hardening.conf"
  grep -Fqx 'kernel.kptr_restrict = 2' \
    "$fake_root/etc/sysctl.d/90-dotfiles-hardening.conf"
  grep -Fqx 'kernel.dmesg_restrict = 1' \
    "$fake_root/etc/sysctl.d/90-dotfiles-hardening.conf"
  grep -Fqx 'deny = 5' \
    "$fake_root/etc/security/faillock.conf.d/90-dotfiles-hardening.conf"
  grep -Fq 'Defaults logfile="/var/log/sudo.log"' \
    "$fake_root/etc/sudoers.d/90-dotfiles-hardening"
  grep -Fq 'dotfiles-identity' \
    "$fake_root/etc/audit/rules.d/90-dotfiles-hardening.rules"
  grep -Fqx 'SELINUX=enforcing' "$fake_root/etc/selinux/config"

  if [[ "$seed_sshd" == "true" ]]; then
    grep -Fqx 'PermitRootLogin no' \
      "$fake_root/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf"
    grep -Fqx 'MaxAuthTries 3' \
      "$fake_root/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf"
    grep -Fq 'sudo systemctl reload sshd.service' "$command_log"
    grep -Fqx 'ssh=hardened' "$state_file"
  else
    [[ -f "$fake_root/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf" ]] && {
      printf '[%s] sshd drop-in written although sshd was never present\n' \
        "$scenario_name" >&2
      exit 1
    }
    grep -Fqx 'ssh=not-present' "$state_file"
  fi

  verify_output="$("${test_environment[@]}" \
    "$repo_root/platforms/fedora/scripts/verify-hardening.sh" 2>&1)" ||
    {
      printf '[%s] verify-hardening.sh reported failures:\n%s\n' \
        "$scenario_name" "$verify_output" >&2
      exit 1
    }

  grep -Fq 'SELinux is enforcing' <<<"$verify_output"
  grep -Fq 'firewalld is active' <<<"$verify_output"
  grep -Fq 'kernel.yama.ptrace_scope = 1' <<<"$verify_output"
  grep -Fq 'kernel.kptr_restrict = 2' <<<"$verify_output"
  grep -Fq 'kernel.dmesg_restrict = 1' <<<"$verify_output"

  if [[ "$seed_sshd" == "true" ]]; then
    grep -Fq 'sshd hardening drop-in applied' <<<"$verify_output"
  else
    grep -Fq 'SSH posture is not applicable' <<<"$verify_output"
  fi

  rm -rf -- "$test_root"
  printf 'PASS: %s\n' "$scenario_name"
}

run_scenario "hardening install/verify with sshd absent (default Fedora Workstation)" false
run_scenario "hardening install/verify with sshd active" true

printf '\nFedora hardening install/verify and idempotency tests passed.\n'
