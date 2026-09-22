#!/usr/bin/env bash

# Fedora security-hardening helpers. Source common/lib/common.sh before this
# file. Every writer here is idempotent (safe to rerun) and only ever touches
# a single dotfiles-owned drop-in file per subsystem, so unrelated user
# configuration is never overwritten. The one exception is the SELINUX= line
# of the vendor file /etc/selinux/config, because SELinux has no drop-in
# mechanism; persist_selinux_enforcing edits it with a backup.
#
# HARDENING_ROOT is prefixed to every path of those owned drop-ins and to
# /etc/selinux/config, for the writes, reads, stats, removals, and reloads
# below alike, so they can never target different roots. Empty (the default)
# means the real root and leaves every command unchanged. Tests point it at a
# fake root so a machine with the profile installed cannot answer checks that
# belong to the fixture. Always pass the real /etc path; each function applies
# the prefix itself, once.

# write_managed_root_file <path> <mode> <description>
# Reads new file content from stdin, then installs it at <path> with <mode>
# via sudo. Skips the write (and reports so) when the file already has the
# same content. Always root:root, matching sudoers.d/sysctl.d/etc. norms.
write_managed_root_file() {
  local path="${HARDENING_ROOT:-}$1"
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

# Read-only counterparts of write_managed_root_file, used by verification.
# The drop-ins this profile owns are root:root and some are mode 0440/0640, so
# an unprivileged read cannot see them at all. sudo is used here only to read
# and stat; nothing below writes, reloads, or enables anything.
managed_root_file_exists() {
  local path="${HARDENING_ROOT:-}$1"
  [[ -f "$path" ]] || sudo test -f "$path" 2>/dev/null
}

managed_root_file_read() {
  local path="${HARDENING_ROOT:-}$1"
  if [[ -r "$path" ]]; then
    cat -- "$path" 2>/dev/null
  else
    sudo cat -- "$path" 2>/dev/null
  fi
}

managed_root_file_mode() {
  local path="${HARDENING_ROOT:-}$1"
  local mode

  mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
  [[ -n "$mode" ]] || mode="$(sudo stat -c '%a' "$path" 2>/dev/null || true)"
  [[ -n "$mode" ]] || return 1
  printf '%s\n' "$mode"
}

# remove_managed_root_file <path> <description>
remove_managed_root_file() {
  local path="${HARDENING_ROOT:-}$1"
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

# selinux_config_single_enforcing: reads an SELinux config on stdin and
# succeeds only when it has exactly one SELINUX= line, SELINUX=enforcing.
selinux_config_single_enforcing() {
  awk '
    /^SELINUX=/ { total++; if ($0 == "SELINUX=enforcing") enforcing++ }
    END { exit !(total == 1 && enforcing == 1) }
  '
}

# persist_selinux_enforcing: makes SELINUX=enforcing survive a reboot. This is
# the one vendor file the profile edits in place, and it is boot-relevant, so
# it is not edited with sed -i. The new content is staged and validated first;
# the current file is kept as a timestamped backup beside it (reusing an
# identical backup, so reruns do not accumulate copies); the staged file is
# installed next to the original with its mode and renamed over it in one
# step, relabelled, and read back while the backup is still adjacent.
persist_selinux_enforcing() {
  local config="${HARDENING_ROOT:-}/etc/selinux/config"
  local staged backup="" candidate mode

  if ! sudo test -f "$config" || ! sudo grep -q '^SELINUX=' "$config"; then
    warn "$config has no SELINUX= line; persisted only for this boot"
    return 0
  fi

  staged="$(mktemp)"
  sudo cat -- "$config" | sed 's/^SELINUX=.*/SELINUX=enforcing/' >"$staged"

  if sudo cmp -s "$staged" "$config"; then
    info "SELINUX=enforcing is already persisted: $config"
    rm -f -- "$staged"
    return 0
  fi

  if ! selinux_config_single_enforcing <"$staged"; then
    rm -f -- "$staged"
    die "Refusing to rewrite $config: it has more than one SELINUX= line." \
      "Leave exactly one, then rerun the hardening profile."
  fi

  for candidate in "$config".dotfiles-*.bak; do
    [[ -f "$candidate" ]] || continue
    if sudo cmp -s "$candidate" "$config"; then
      backup="$candidate"
      break
    fi
  done
  if [[ -n "$backup" ]]; then
    info "Reusing the identical backup of $config: $backup"
  else
    backup="$config.dotfiles-$(date +%s).bak"
    [[ ! -e "$backup" ]] || die "Refusing to overwrite an existing backup: $backup"
    info "Backing up $config to $backup"
    sudo cp -a -- "$config" "$backup"
  fi

  mode="$(sudo stat -c '%a' "$config")"
  sudo install -m "$mode" -o root -g root "$staged" "$config.dotfiles-new"
  rm -f -- "$staged"
  sudo mv -f -- "$config.dotfiles-new" "$config"
  if command_exists restorecon; then
    sudo restorecon "$config"
  fi

  sudo cat -- "$config" | selinux_config_single_enforcing ||
    die "$config does not contain exactly one SELINUX=enforcing line after" \
      "the rewrite. Restore it with: sudo cp -a $backup $config"

  info "Persisted SELINUX=enforcing in $config (backup: $backup)"
}

# harden_selinux_mode: verifies SELinux is enforcing. When it is merely
# Permissive, switches it to Enforcing immediately (setenforce 1, which never
# requires a reboot or relabel) and persists the change in
# /etc/selinux/config through persist_selinux_enforcing. When it is Disabled,
# a reboot and filesystem relabel are required, which this installer will not
# do unattended; it warns with manual instructions instead of silently
# continuing.
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
    persist_selinux_enforcing
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

# hardening_dropin_content <name>: the exact body of one owned drop-in, on
# stdout. Every writer below pipes this, and verify-hardening.sh compares the
# file on disk against it, so "what the installer wrote" and "what the verifier
# accepts as unmodified" are the same bytes from one place. They used not to
# be: the verifier carried its own hand-listed copy of a few policy lines per
# subsystem and searched for each as a substring of the whole file, which let a
# drop-in with every directive commented out, and one with deny = 50 where
# deny = 5 was expected, both report as unmodified -- and left two of the five
# audit watch rules written here asserted nowhere at all, because the call site
# only listed three. Adding or changing a directive is now one edit that the
# writer and the verifier both follow.
#
# The names are subsystems, not paths: the path belongs to the writer (which
# prefixes HARDENING_ROOT) and to the verifier's call site.
hardening_dropin_content() {
  case "$1" in
  faillock)
    printf '%s\n' \
      '# Managed by dotfiles Fedora hardening profile. Safe to delete.' \
      'deny = 5' \
      'unlock_time = 900'
    ;;
  sudo-logfile)
    # No comment header: this one is parsed by sudoers(5) and checked with
    # visudo -cf before it is installed, so it stays minimal.
    printf '%s\n' \
      'Defaults logfile="/var/log/sudo.log"'
    ;;
  auditd-rules)
    # No comment header either: augenrules concatenates this file into the
    # ruleset it loads. auditctl -l prints a loaded watch back in exactly this
    # `-w <path> -p <perms> -k <key>` form, which is what lets the verifier
    # require these lines whole in the running kernel's ruleset as well as on
    # disk.
    printf '%s\n' \
      '-w /etc/passwd -p wa -k dotfiles-identity' \
      '-w /etc/shadow -p wa -k dotfiles-identity' \
      '-w /etc/group -p wa -k dotfiles-identity' \
      '-w /etc/sudoers -p wa -k dotfiles-sudoers' \
      '-w /etc/sudoers.d/ -p wa -k dotfiles-sudoers'
    ;;
  sysctl)
    printf '%s\n' \
      '# Managed by dotfiles Fedora hardening profile. Safe to delete.' \
      'kernel.yama.ptrace_scope = 1' \
      'kernel.kptr_restrict = 2' \
      'kernel.dmesg_restrict = 1'
    ;;
  ssh)
    printf '%s\n' \
      '# Managed by dotfiles Fedora hardening profile. Safe to delete.' \
      'PermitRootLogin no' \
      'MaxAuthTries 3' \
      'LoginGraceTime 20'
    ;;
  *)
    die "hardening_dropin_content: no drop-in named '$1'"
    ;;
  esac
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

  hardening_dropin_content faillock |
    write_managed_root_file /etc/security/faillock.conf.d/90-dotfiles-hardening.conf \
      0644 "pam_faillock lockout policy"
}

apply_sudo_audit_log() {
  local tmp

  tmp="$(mktemp)"
  hardening_dropin_content sudo-logfile >"$tmp"

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
  local rooted_rules_path="${HARDENING_ROOT:-}$rules_path"
  local before after

  before=""
  sudo test -f "$rooted_rules_path" && before="$(sudo cat "$rooted_rules_path")"

  hardening_dropin_content auditd-rules |
    write_managed_root_file "$rules_path" 0640 "auditd watch rules"

  after="$(sudo cat "$rooted_rules_path")"

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

  hardening_dropin_content sysctl |
    write_managed_root_file "$path" 0644 "hardening sysctl settings"

  info "Applying sysctl settings"
  sudo sysctl -p "${HARDENING_ROOT:-}$path" >/dev/null
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

  local path="${HARDENING_ROOT:-}/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf"
  local tmp

  tmp="$(mktemp)"
  hardening_dropin_content ssh >"$tmp"

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

# apply_dnf_automatic_notify: enables dnf5's single automatic-update timer.
# Unlike dnf4's dnf-automatic package (separate -notifyonly/-download/-install
# timer units), dnf5-plugin-automatic ships one timer, dnf5-automatic.timer,
# whose behavior is controlled by /etc/dnf/automatic.conf. Its packaged
# default (apply_updates = no, download_updates = yes) already matches the
# "report and download, never auto-install" policy this profile wants, so no
# config override is written here; only the timer is enabled.
apply_dnf_automatic_notify() {
  command_exists dnf-automatic || {
    info "Installing dnf5-plugin-automatic"
    sudo dnf install -y dnf5-plugin-automatic
  }

  if systemctl is-enabled --quiet dnf5-automatic.timer 2>/dev/null; then
    info "dnf5-automatic.timer already enabled"
  else
    info "Enabling dnf5-automatic.timer (downloads and reports updates;" \
      "apply_updates=no by default installs nothing automatically)"
    sudo systemctl enable --now dnf5-automatic.timer
  fi
}
