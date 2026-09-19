#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/profile-state.sh"
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

The rule is that every change is a small, named, dotfiles-owned drop-in
file (sysctl.d, sudoers.d, sshd_config.d, faillock.conf.d, audit/rules.d),
so deleting a drop-in rolls that single change back. Three changes are not
drop-in files:

  - the SELINUX= line of /etc/selinux/config, edited in place only when
    SELinux is permissive, because SELinux has no drop-in mechanism. The
    previous file is kept beside it as
    /etc/selinux/config.dotfiles-<epoch>.bak; roll back with
    'sudo setenforce 0' and copy that backup over /etc/selinux/config.
  - the authselect 'with-faillock' feature, which regenerates /etc/pam.d;
    deleting the faillock drop-in does not undo it. Roll back with
    'sudo authselect disable-feature with-faillock'.
  - dnf5-automatic.timer, enabled after installing dnf5-plugin-automatic
    when it is missing. Roll back with
    'sudo systemctl disable --now dnf5-automatic.timer', and
    'sudo dnf remove dnf5-plugin-automatic' if you want the package gone.

Does not disable SELinux or firewalld, does not install/enable sshd, and
does not reboot.

See docs/profiles/hardening.md for the full rationale, verification
command, and the per-change rollback table.
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

Apply (a removable drop-in file per change, except where noted; see the
per-change rollback table in docs/profiles/hardening.md):
  1. SELinux: setenforce 1 if currently Permissive
     /etc/selinux/config (SELINUX= line only, edited in place, no drop-in;
     the previous file is kept as /etc/selinux/config.dotfiles-<epoch>.bak)

  2. pam_faillock: lock an account after 5 failed attempts for 15 minutes
     authselect enable-feature with-faillock (regenerates /etc/pam.d,
     not a drop-in; undone with 'authselect disable-feature with-faillock')
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

  7. dnf5-automatic.timer: downloads and reports available updates daily
     (apply_updates=no by default), installs nothing automatically
     installs dnf5-plugin-automatic when missing; no drop-in, undone with
     'systemctl disable --now dnf5-automatic.timer'

Never done by this profile: disabling SELinux or firewalld, changing
firewalld zone services, noexec on /tmp, USBGuard, Wi-Fi MAC
randomization, unprivileged_bpf_disabled, or rp_filter changes (kept
compatible with split-tunnel VPNs such as Tailscale). See
docs/profiles/hardening.md for the full rationale and rejected-ideas list.

No changes were made.

EOF
  exit 0
fi

require_fedora

if [[ "$interactive" == "true" ]]; then
  printf '\n'
  printf 'This installs the optional Fedora hardening profile described above.\n'
  printf 'Run with --dry-run first to see the full plan.\n'
  # `confirm` is deliberately three-valued and this is a step of a larger
  # plan, not a top-level installer: exiting 0 on anything but a yes would
  # report a profile that was never installed as completed. plan_execute would
  # record `[hardening] completed`, install_lifecycle_commit would add
  # `hardening` to observed_capabilities, and the plan's verify step could not
  # catch it, because platforms/fedora/scripts/verify.sh only runs the
  # hardening verifier when the state file this run never wrote exists. Only
  # ./doctor would notice, much later. So both non-yes statuses stop the run,
  # and they are distinguished the way every other call site distinguishes
  # them: an unparseable answer is a different mistake from a declined one.
  if confirm "Continue with hardening installation?" "y"; then :; else
    result=$?
    ((result == 1)) || die 'Invalid confirmation response'
    die 'Hardening installation declined; nothing was changed.'
  fi
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
} | profile_state_write_content "$state_file" hardening applying

info "Validating the Fedora hardening profile"
if "$DOTFILES_ROOT/platforms/fedora/scripts/verify-hardening.sh"; then
  profile_state_set_status "$state_file" hardening installed
  success "Fedora hardening profile installed"
else
  profile_state_set_status "$state_file" hardening failed
  warn "Hardening changes were applied, but validation reported problems"
  exit 1
fi
