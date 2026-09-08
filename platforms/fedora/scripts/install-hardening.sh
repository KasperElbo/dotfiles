#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/fedora.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/fedora.sh"
# shellcheck source=../lib/hardening.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/hardening.sh"

dry_run="false"
validate_only="false"
interactive="true"

usage() {
  cat <<'EOF'
Usage: ./platforms/fedora/scripts/install-hardening.sh [options]

Install the optional, conservative Fedora security-hardening profile.

Options:
  --dry-run          Show the hardening plan without changing anything
  --validate         Validate an existing hardening installation only
  --non-interactive  Do not prompt before applying changes
  -h, --help         Show this help

Every change is a small, named, dotfiles-owned drop-in file (sysctl.d,
sudoers.d, sshd_config.d, faillock.conf.d, audit/rules.d). Nothing is
mixed into a vendor config file, so it is always safe to delete a
drop-in to roll a single change back. Does not disable SELinux or
firewalld, does not install/enable sshd, and does not reboot.

See README.md's "Fedora security hardening" section for the full
rationale, verification command, and rollback instructions for each
change.
EOF
}

while (($#)); do
  case "$1" in
  --dry-run)
    dry_run="true"
    interactive="false"
    shift
    ;;
  --validate)
    validate_only="true"
    shift
    ;;
  --non-interactive)
    interactive="false"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    die "Unknown option: $1"
    ;;
  esac
done

if [[ "$dry_run" == "true" && "$validate_only" == "true" ]]; then
  die "--dry-run and --validate cannot be combined"
fi

if [[ "$validate_only" == "true" ]]; then
  exec "$DOTFILES_ROOT/platforms/fedora/scripts/verify-hardening.sh"
fi

if [[ "$dry_run" == "true" ]]; then
  cat <<'EOF'

Fedora hardening installation plan
-----------------------------------

Verify only, never change:
  - SELinux mode (fixes permissive -> enforcing only; warns on disabled)
  - firewalld active state and exposed zone services
  - Secure Boot state
  - /tmp, /dev/shm, /boot, /home mount options
  - enabled systemd services and listening sockets, against an allow-list
  - permissions on ~/.ssh, ~/.aws, ~/.config/gh, ~/.gnupg

Apply (each as its own removable drop-in file):
  1. SELinux: setenforce 1 if currently Permissive
     /etc/selinux/config (SELINUX= line only)

  2. pam_faillock: lock an account after 5 failed attempts for 15 minutes
     authselect enable-feature with-faillock
     /etc/security/faillock.conf.d/90-dotfiles-hardening.conf

  3. sudo audit logfile
     /etc/sudoers.d/90-dotfiles-hardening

  4. auditd: watch /etc/passwd, /etc/shadow, /etc/group, sudoers for changes
     /etc/audit/rules.d/90-dotfiles-hardening.rules

  5. sysctl: kernel.yama.ptrace_scope=1, kernel.kptr_restrict=2,
     kernel.dmesg_restrict=1
     /etc/sysctl.d/90-dotfiles-hardening.conf

  6. sshd posture, only if sshd is already active or enabled:
     PermitRootLogin no, MaxAuthTries 3, LoginGraceTime 20
     /etc/ssh/sshd_config.d/90-dotfiles-hardening.conf

  7. dnf-automatic-notifyonly.timer: reports available updates daily,
     installs nothing automatically

Never done by this profile: disabling SELinux or firewalld, changing
firewalld zone services, noexec on /tmp, USBGuard, Wi-Fi MAC
randomization, unprivileged_bpf_disabled, or rp_filter changes (kept
compatible with split-tunnel VPNs such as Tailscale). See README.md for
the full rationale and rejected-ideas list.

No changes were made.

EOF
  exit 0
fi

require_fedora

if [[ "$interactive" == "true" ]]; then
  printf '\n'
  printf 'This installs the optional Fedora hardening profile described above.\n'
  printf 'Run with --dry-run first to see the full plan.\n'
  confirm "Continue with hardening installation?" "y" || exit 0
fi

state_selinux="$(selinux_mode)"
state_faillock="false"
state_sudo_logfile="true"
state_auditd="true"
state_ssh="not-present"
state_dnf_automatic="skipped"

info "Verifying SELinux mode"
harden_selinux_mode
state_selinux="$(selinux_mode)"

info "Configuring pam_faillock lockout policy"
if apply_pam_faillock; then
  state_faillock="true"
fi

info "Configuring sudo audit logfile"
apply_sudo_audit_log

info "Configuring auditd watch rules"
apply_auditd_rules

info "Applying hardening sysctl settings"
apply_hardening_sysctl

info "Checking SSH server posture"
if apply_ssh_hardening; then
  state_ssh="hardened"
elif sshd_present; then
  state_ssh="present-not-hardened"
fi

info "Configuring update-notification policy"
if apply_dnf_automatic_notify; then
  state_dnf_automatic="notifyonly"
fi

state_file="$XDG_CONFIG_HOME/dotfiles/hardening.conf"
ensure_dir "$(dirname "$state_file")"
{
  printf 'profile=hardening\n'
  printf 'selinux_mode=%s\n' "$state_selinux"
  printf 'faillock=%s\n' "$state_faillock"
  printf 'sudo_logfile=%s\n' "$state_sudo_logfile"
  printf 'auditd=%s\n' "$state_auditd"
  printf 'sysctl_ptrace_scope=1\n'
  printf 'sysctl_kptr_restrict=2\n'
  printf 'sysctl_dmesg_restrict=1\n'
  printf 'ssh=%s\n' "$state_ssh"
  printf 'dnf_automatic=%s\n' "$state_dnf_automatic"
} | atomic_write_file "$state_file"

info "Validating the Fedora hardening profile"
if "$DOTFILES_ROOT/platforms/fedora/scripts/verify-hardening.sh"; then
  success "Fedora hardening profile installed"
else
  warn "Hardening changes were applied, but validation reported problems"
  exit 1
fi
