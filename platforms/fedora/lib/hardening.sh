#!/usr/bin/env bash

# Fedora security-hardening helpers. Source common/lib/common.sh before this
# file. Every writer here is idempotent (safe to rerun) and only ever touches
# a single dotfiles-owned drop-in file per subsystem, never a vendor config
# file, so unrelated user configuration is never overwritten.

# write_managed_root_file <path> <mode> <description>
# Reads new file content from stdin, then installs it at <path> with <mode>
# via sudo. Skips the write (and reports so) when the file already has the
# same content. Always root:root, matching sudoers.d/sysctl.d/etc. norms.
write_managed_root_file() {
  local path="$1"
  local mode="$2"
  local description="$3"
  local tmp

  tmp="$(mktemp)"
  cat >"$tmp"

  if sudo test -f "$path" && sudo cmp -s "$tmp" "$path"; then
    info "$description already applied: $path"
    rm -f "$tmp"
    return 0
  fi

  info "Writing $description: $path"
  sudo install -D -m "$mode" -o root -g root "$tmp" "$path"
  rm -f "$tmp"
}

# remove_managed_root_file <path> <description>
remove_managed_root_file() {
  local path="$1"
  local description="$2"

  if sudo test -f "$path"; then
    info "Removing $description: $path"
    sudo rm -f -- "$path"
  else
    info "$description already absent: $path"
  fi
}

selinux_mode() {
  # SELinux is a host-kernel feature: it is not namespaced, so most
  # containers (including the Fedora container CI runs in) have no
  # /sys/fs/selinux and often no getenforce at all. Report that distinctly
  # from a real Fedora install where SELinux support is missing/misconfigured.
  [[ -d "${SELINUX_FS_ROOT:-/sys/fs/selinux}" ]] || {
    printf 'unavailable\n'
    return
  }

  command_exists getenforce || {
    printf 'unknown\n'
    return
  }
  LC_ALL=C getenforce 2>/dev/null | tr '[:upper:]' '[:lower:]' || printf 'unknown\n'
}

# harden_selinux_mode: verifies SELinux is enforcing. When it is merely
# Permissive, switches it to Enforcing immediately (setenforce 1, which never
# requires a reboot or relabel) and persists the change in
# /etc/selinux/config. When it is Disabled, a reboot and filesystem relabel
# are required, which this installer will not do unattended; it warns with
# manual instructions instead of silently continuing.
harden_selinux_mode() {
  local mode
  mode="$(selinux_mode)"

  case "$mode" in
  enforcing)
    info "SELinux is already enforcing"
    ;;
  permissive)
    info "Switching SELinux from permissive to enforcing"
    sudo setenforce 1
    if sudo test -f /etc/selinux/config &&
      sudo grep -q '^SELINUX=' /etc/selinux/config; then
      sudo sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
    else
      warn "/etc/selinux/config has no SELINUX= line; persisted only for this boot"
    fi
    ;;
  disabled)
    warn "SELinux is Disabled; this requires editing /etc/selinux/config," \
      "a filesystem relabel (touch /.autorelabel), and a reboot." \
      "Run these manually, then rerun the hardening profile."
    ;;
  unavailable)
    warn "SELinux is not available on this kernel (e.g. inside a container);" \
      "skipping SELinux enforcement"
    ;;
  *)
    warn "Could not determine SELinux mode (getenforce reported: $mode)"
    ;;
  esac
}

firewalld_active() {
  systemctl is-active --quiet firewalld.service
}

apply_pam_faillock() {
  command_exists authselect || {
    warn "authselect not found; skipping pam_faillock lockout"
    return 1
  }

  if ! authselect current >/dev/null 2>&1; then
    warn "authselect has no active profile; skipping pam_faillock lockout"
    return 1
  fi

  if authselect current 2>/dev/null | grep -q 'with-faillock'; then
    info "pam_faillock already enabled via authselect"
  elif sudo authselect enable-feature with-faillock; then
    success "Enabled pam_faillock via authselect"
  else
    warn "authselect could not enable with-faillock (local modifications?);" \
      "run 'authselect current' and enable it manually if desired"
    return 1
  fi

  write_managed_root_file /etc/security/faillock.conf.d/90-dotfiles-hardening.conf \
    0644 "pam_faillock lockout policy" <<'EOF'
# Managed by dotfiles Fedora hardening profile. Safe to delete.
deny = 5
unlock_time = 900
EOF
}

apply_sudo_audit_log() {
  local tmp

  tmp="$(mktemp)"
  printf 'Defaults logfile="/var/log/sudo.log"\n' >"$tmp"

  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    die "Generated sudoers drop-in failed visudo syntax check; not installing it"
  fi

  write_managed_root_file /etc/sudoers.d/90-dotfiles-hardening 0440 \
    "sudo audit logfile policy" <"$tmp"
  rm -f "$tmp"
}

apply_auditd_rules() {
  command_exists auditctl || {
    info "Installing auditd"
    sudo dnf install -y audit
  }

  local rules_path="/etc/audit/rules.d/90-dotfiles-hardening.rules"
  local before after

  before=""
  sudo test -f "$rules_path" && before="$(sudo cat "$rules_path")"

  printf '%s\n' \
    '-w /etc/passwd -p wa -k dotfiles-identity' \
    '-w /etc/shadow -p wa -k dotfiles-identity' \
    '-w /etc/group -p wa -k dotfiles-identity' \
    '-w /etc/sudoers -p wa -k dotfiles-sudoers' \
    '-w /etc/sudoers.d/ -p wa -k dotfiles-sudoers' |
    write_managed_root_file "$rules_path" 0640 "auditd watch rules"

  after="$(sudo cat "$rules_path")"

  if ! systemctl is-enabled --quiet auditd.service 2>/dev/null; then
    info "Enabling auditd"
    sudo systemctl enable --now auditd.service
  elif [[ "$before" != "$after" ]]; then
    info "Reloading auditd rules"
    sudo augenrules --load >/dev/null 2>&1 || sudo systemctl restart auditd.service
  else
    info "auditd rules already loaded"
  fi
}

# apply_hardening_sysctl: writes the managed sysctl.d drop-in and applies it
# immediately. Named 90- so it is read (and can be overridden) after Fedora's
# own /usr/lib/sysctl.d defaults and before an end-user /etc/sysctl.d/99-*.
apply_hardening_sysctl() {
  local path="/etc/sysctl.d/90-dotfiles-hardening.conf"

  printf '%s\n' \
    '# Managed by dotfiles Fedora hardening profile. Safe to delete.' \
    'kernel.yama.ptrace_scope = 1' \
    'kernel.kptr_restrict = 2' \
    'kernel.dmesg_restrict = 1' |
    write_managed_root_file "$path" 0644 "hardening sysctl settings"

  info "Applying sysctl settings"
  sudo sysctl -p "$path" >/dev/null
}

sshd_present() {
  systemctl is-active --quiet sshd.service ||
    systemctl is-enabled --quiet sshd.service 2>/dev/null
}

apply_ssh_hardening() {
  if ! sshd_present; then
    info "sshd is not active/enabled; skipping SSH posture (not installing it)"
    return 1
  fi

  local path="/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf"
  local tmp

  tmp="$(mktemp)"
  printf '%s\n' \
    '# Managed by dotfiles Fedora hardening profile. Safe to delete.' \
    'PermitRootLogin no' \
    'MaxAuthTries 3' \
    'LoginGraceTime 20' >"$tmp"

  if sudo test -f "$path" && sudo cmp -s "$tmp" "$path"; then
    info "SSH hardening drop-in already applied: $path"
    rm -f "$tmp"
    return 0
  fi

  sudo install -D -m 0644 -o root -g root "$tmp" "$path"
  rm -f "$tmp"

  if ! sudo sshd -t; then
    sudo rm -f -- "$path"
    die "sshd -t rejected the generated drop-in; removed it and aborted SSH hardening"
  fi

  if systemctl is-active --quiet sshd.service; then
    info "Reloading sshd"
    sudo systemctl reload sshd.service
  else
    info "sshd is enabled but not currently running; the drop-in applies on next start"
  fi
  success "Applied conservative sshd posture"
}

apply_dnf_automatic_notify() {
  command_exists dnf-automatic || {
    info "Installing dnf-automatic"
    sudo dnf install -y dnf-automatic
  }

  for competing in dnf-automatic-install.timer dnf-automatic-download.timer; do
    if systemctl is-active --quiet "$competing" 2>/dev/null; then
      warn "$competing is already active; leaving your existing dnf-automatic" \
        "policy alone instead of enabling notify-only"
      return 1
    fi
  done

  if systemctl is-enabled --quiet dnf-automatic-notifyonly.timer 2>/dev/null; then
    info "dnf-automatic-notifyonly.timer already enabled"
  else
    info "Enabling dnf-automatic-notifyonly.timer (reports updates, installs nothing)"
    sudo systemctl enable --now dnf-automatic-notifyonly.timer
  fi
}
