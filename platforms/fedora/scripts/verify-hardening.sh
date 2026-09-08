#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/secure-boot.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/secure-boot.sh"
# shellcheck source=../lib/hardening.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/hardening.sh"

failures=0
warnings=0

pass() {
  printf '\033[1;32m✓\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m✗\033[0m %s\n' "$*" >&2
  failures=$((failures + 1))
}

warning() {
  printf '\033[1;33m!\033[0m %s\n' "$*" >&2
  warnings=$((warnings + 1))
}

note() {
  printf '  %s\n' "$*"
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

# ---------------------------------------------------------------------------
# SELinux
# ---------------------------------------------------------------------------

section "SELinux"

case "$(selinux_mode)" in
enforcing)
  pass "SELinux is enforcing"
  ;;
permissive)
  fail "SELinux is permissive, not enforcing"
  ;;
disabled)
  fail "SELinux is disabled"
  ;;
unavailable)
  warning "SELinux is not available on this kernel (e.g. inside a container)"
  ;;
*)
  warning "Could not determine SELinux mode"
  ;;
esac

# ---------------------------------------------------------------------------
# firewalld
# ---------------------------------------------------------------------------

section "firewalld"

if systemctl is-active --quiet firewalld.service; then
  pass "firewalld is active"

  if command_exists firewall-cmd; then
    default_zone="$(firewall-cmd --get-default-zone 2>/dev/null || true)"
    if [[ -n "$default_zone" ]]; then
      note "Default zone: $default_zone"
      note "Exposed services: $(
        firewall-cmd --zone="$default_zone" --list-services 2>/dev/null
      )"
      note "Open ports: $(
        firewall-cmd --zone="$default_zone" --list-ports 2>/dev/null || printf '(none)'
      )"
    fi
  fi
else
  fail "firewalld is not active"
fi

# ---------------------------------------------------------------------------
# Secure Boot (report only; never modified)
# ---------------------------------------------------------------------------

section "Secure Boot"

case "$(secure_boot_state)" in
enabled)
  pass "Secure Boot is enabled"
  ;;
disabled)
  warning "Secure Boot is disabled (informational; not required on every machine)"
  ;;
*)
  warning "Secure Boot state could not be determined"
  ;;
esac

# ---------------------------------------------------------------------------
# pam_faillock
# ---------------------------------------------------------------------------

section "pam_faillock lockout"

if command_exists authselect && authselect current 2>/dev/null | grep -q with-faillock; then
  pass "authselect has with-faillock enabled"
else
  warning "authselect does not report with-faillock enabled"
fi

faillock_dropin="/etc/security/faillock.conf.d/90-dotfiles-hardening.conf"
if sudo test -f "$faillock_dropin" 2>/dev/null; then
  pass "faillock policy drop-in present: $faillock_dropin"
else
  warning "faillock policy drop-in missing: $faillock_dropin"
fi

# ---------------------------------------------------------------------------
# sudo audit logging
# ---------------------------------------------------------------------------

section "sudo audit logging"

if sudo test -f /etc/sudoers.d/90-dotfiles-hardening 2>/dev/null; then
  pass "sudo logfile drop-in present: /etc/sudoers.d/90-dotfiles-hardening"
else
  warning "sudo logfile drop-in missing: /etc/sudoers.d/90-dotfiles-hardening"
fi

# ---------------------------------------------------------------------------
# auditd
# ---------------------------------------------------------------------------

section "auditd"

if systemctl is-active --quiet auditd.service; then
  pass "auditd is active"

  if sudo auditctl -l 2>/dev/null | grep -q dotfiles-identity; then
    pass "dotfiles watch rules are loaded"
  else
    warning "Could not confirm dotfiles audit watch rules are loaded"
  fi
else
  warning "auditd is not active"
fi

# ---------------------------------------------------------------------------
# sysctl hardening
# ---------------------------------------------------------------------------

section "sysctl hardening"

check_sysctl() {
  local key="$1"
  local expected="$2"
  local actual

  actual="$(sysctl -n "$key" 2>/dev/null || true)"

  if [[ "$actual" == "$expected" ]]; then
    pass "$key = $actual"
  else
    fail "$key expected $expected, got ${actual:-unreadable}"
  fi
}

check_sysctl kernel.yama.ptrace_scope 1
check_sysctl kernel.kptr_restrict 2
check_sysctl kernel.dmesg_restrict 1

# ---------------------------------------------------------------------------
# SSH posture (only if sshd is present)
# ---------------------------------------------------------------------------

section "SSH posture"

if sshd_present; then
  ssh_dropin="/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf"
  if sudo test -f "$ssh_dropin" 2>/dev/null &&
    sudo grep -Fqx 'PermitRootLogin no' "$ssh_dropin" 2>/dev/null &&
    sudo grep -Fqx 'MaxAuthTries 3' "$ssh_dropin" 2>/dev/null; then
    pass "sshd hardening drop-in applied: $ssh_dropin"
  else
    fail "sshd is present but the hardening drop-in is missing or incomplete"
  fi
else
  pass "sshd is not active/enabled; SSH posture is not applicable"
fi

# ---------------------------------------------------------------------------
# Automatic update notifications
# ---------------------------------------------------------------------------

section "Update notifications"

if systemctl is-enabled --quiet dnf-automatic-notifyonly.timer 2>/dev/null; then
  pass "dnf-automatic-notifyonly.timer is enabled (reports only, installs nothing)"
elif systemctl is-active --quiet dnf-automatic-install.timer 2>/dev/null; then
  note "dnf-automatic-install.timer is active (a different, user-chosen policy)"
else
  warning "No dnf-automatic timer is enabled"
fi

# ---------------------------------------------------------------------------
# Mount options (report only)
# ---------------------------------------------------------------------------

section "Mount options (report only)"

for mount_point in /tmp /dev/shm /boot /home; do
  if command_exists findmnt && findmnt -no OPTIONS "$mount_point" >/dev/null 2>&1; then
    note "$mount_point: $(findmnt -no OPTIONS "$mount_point")"
  fi
done

# ---------------------------------------------------------------------------
# Service watch-list (report only; never auto-disabled)
# ---------------------------------------------------------------------------

section "Service watch-list (report only)"

note "Services with no clear single-user dev-laptop use case, if enabled:"

for service in avahi-daemon.service cups-browsed.service rpcbind.service \
  nfs-server.service smb.service vsftpd.service telnet.socket; do
  if systemctl is-enabled --quiet "$service" 2>/dev/null; then
    note "  enabled: $service (review whether you use it; not disabled automatically)"
  fi
done

if command_exists ss; then
  note "Listening sockets (ss -tuln):"
  while IFS= read -r line; do
    note "  $line"
  done < <(ss -tuln 2>/dev/null | tail -n +2)
fi

# ---------------------------------------------------------------------------
# Credential/secrets permission audit (report only; never modifies files)
# ---------------------------------------------------------------------------

section "Credential permissions"

check_private_key_mode() {
  local path="$1"
  local mode

  [[ -f "$path" ]] || return 0

  mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
  [[ -n "$mode" ]] || return 0

  if ((8#$mode & 8#077)); then
    fail "$path is readable by group/other (mode $mode)"
  else
    pass "$path permissions are private (mode $mode)"
  fi
}

if [[ -d "$HOME/.ssh" ]]; then
  for key in "$HOME"/.ssh/id_* "$HOME"/.ssh/*.pem; do
    [[ -f "$key" && "$key" != *.pub ]] || continue
    check_private_key_mode "$key"
  done
fi

check_private_key_mode "$HOME/.aws/credentials"
check_private_key_mode "$HOME/.config/gh/hosts.yml"

if [[ -d "$HOME/.gnupg/private-keys-v1.d" ]]; then
  for key in "$HOME"/.gnupg/private-keys-v1.d/*.key; do
    [[ -f "$key" ]] || continue
    check_private_key_mode "$key"
  done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n'

if ((failures > 0)); then
  printf '\033[1;31mHardening verification failed:\033[0m %d failure(s), %d warning(s)\n' \
    "$failures" "$warnings"
  exit 1
fi

if ((warnings > 0)); then
  printf '\033[1;33mHardening verification passed with warnings:\033[0m %d warning(s)\n' \
    "$warnings"
else
  printf '\033[1;32mHardening verification passed.\033[0m\n'
fi
