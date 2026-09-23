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

# The drop-ins this profile owns, as one record per subsystem: where it goes,
# the mode it carries, and the exact bytes it holds. Both halves of the
# profile read this table -- the installer to write a drop-in, the verifier to
# decide whether the one on disk is still the one that was written -- so
# "unmodified" can mean the whole file rather than a sample of a few lines
# taken from it. A verifier that samples cannot see an inserted line, and an
# inserted line is how a policy gets reversed: sshd_config(5) takes the first
# value it reads for a keyword, so `PermitRootLogin yes` written above the
# `PermitRootLogin no` this profile wrote turns root SSH login back on while
# every line the profile wrote is still present.
#
# The same rule decides the sshd drop-in's name. sshd reads the drop-ins in
# lexical order and keeps the first value, so the policy only holds if this
# file sorts before every other one: at 90- it lost to the
# 01-permitrootlogin.conf Anaconda writes when root SSH login is allowed at
# installation, and would lose to Fedora's 50-redhat.conf for any keyword
# that file sets.
# The others keep 90-: sysctl.d and the rest take the last value, and a
# deliberate local 99- override winning there is the documented intent.
#
# hardening_dropin_path <name>
hardening_dropin_path() {
  case "$1" in
  faillock) printf '/etc/security/faillock.conf.d/90-dotfiles-hardening.conf\n' ;;
  sudo-logfile) printf '/etc/sudoers.d/90-dotfiles-hardening\n' ;;
  auditd-rules) printf '/etc/audit/rules.d/90-dotfiles-hardening.rules\n' ;;
  sysctl) printf '/etc/sysctl.d/90-dotfiles-hardening.conf\n' ;;
  ssh) printf '/etc/ssh/sshd_config.d/00-dotfiles-hardening.conf\n' ;;
  *) die "Unknown hardening drop-in: $1" ;;
  esac
}

# hardening_dropin_mode <name>: the mode in the spelling install(1) is given.
# stat(1) reports it without the leading zero, so a comparison against a
# stat'd mode strips it.
hardening_dropin_mode() {
  case "$1" in
  faillock | sysctl | ssh) printf '0644\n' ;;
  sudo-logfile) printf '0440\n' ;;
  auditd-rules) printf '0640\n' ;;
  *) die "Unknown hardening drop-in: $1" ;;
  esac
}

# hardening_dropin_description <name>: what the drop-in is called in the
# installer's progress output.
hardening_dropin_description() {
  case "$1" in
  faillock) printf 'pam_faillock lockout policy\n' ;;
  sudo-logfile) printf 'sudo audit logfile policy\n' ;;
  auditd-rules) printf 'auditd watch rules\n' ;;
  sysctl) printf 'hardening sysctl settings\n' ;;
  ssh) printf 'SSH hardening drop-in\n' ;;
  *) die "Unknown hardening drop-in: $1" ;;
  esac
}

# hardening_dropin_content <name>: the file's exact content.
#
# auditd-rules carries no comment header on purpose: verification compares
# these lines against `auditctl -l`, which prints loaded rules and no
# comments, so every line here has to be a rule.
hardening_dropin_content() {
  case "$1" in
  faillock)
    printf '%s\n' \
      '# Managed by dotfiles Fedora hardening profile. Safe to delete.' \
      'deny = 5' \
      'unlock_time = 900'
    ;;
  sudo-logfile)
    printf 'Defaults logfile="/var/log/sudo.log"\n'
    ;;
  auditd-rules)
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
  *) die "Unknown hardening drop-in: $1" ;;
  esac
}

# hardening_dropin_difference <expected> <actual>: names the first line where
# two drop-in bodies part company, so a content failure says what changed
# instead of only that something did.
hardening_dropin_difference() {
  local -a expected actual
  mapfile -t expected <<<"$1"
  mapfile -t actual <<<"$2"

  local index count="${#expected[@]}"
  ((count >= ${#actual[@]})) || count="${#actual[@]}"

  for ((index = 0; index < count; index++)); do
    [[ "${expected[index]-}" != "${actual[index]-}" ]] || continue
    if ((index >= ${#actual[@]})); then
      printf "line %d is missing, expected '%s'" \
        "$((index + 1))" "${expected[index]}"
    elif ((index >= ${#expected[@]})); then
      printf "line %d was added: '%s'" "$((index + 1))" "${actual[index]}"
    else
      printf "line %d is '%s', expected '%s'" \
        "$((index + 1))" "${actual[index]}" "${expected[index]}"
    fi
    return 0
  done

  printf 'the contents are identical'
}

# write_managed_dropin <name>: writes one drop-in from the table above.
write_managed_dropin() {
  local name="$1"

  hardening_dropin_content "$name" |
    write_managed_root_file "$(hardening_dropin_path "$name")" \
      "$(hardening_dropin_mode "$name")" \
      "$(hardening_dropin_description "$name")"
}

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
#
# Every privileged read is `sudo -n`. Verification is what you run to find out
# what state a machine is in, including from a script, a timer, or a session
# with no terminal to answer on, so it must never stop on a password prompt.
# When sudo will not answer without one these helpers say they could not tell,
# with a status of their own, rather than reporting the control absent: a
# missing control and an unreadable one are different answers, and only one of
# them is drift.
#
# HARDENING_SUDO_AUTHORIZED caches the answer for the process. It is asked
# once because the answer can only go stale in the direction of a prompt,
# which is the thing being avoided.
HARDENING_SUDO_AUTHORIZED=""

# hardening_privileged_read_available: whether sudo answers without asking for
# a password.
hardening_privileged_read_available() {
  if [[ -z "$HARDENING_SUDO_AUTHORIZED" ]]; then
    if sudo -n true 2>/dev/null; then
      HARDENING_SUDO_AUTHORIZED="true"
    else
      HARDENING_SUDO_AUTHORIZED="false"
    fi
  fi

  [[ "$HARDENING_SUDO_AUTHORIZED" == "true" ]]
}

# managed_root_file_exists <path>: 0 present, 1 absent, 2 could not tell.
#
# An unprivileged stat cannot tell an absent file from one inside a directory
# this user may not search, so a negative answer is only conclusive when sudo
# could be asked.
managed_root_file_exists() {
  local path="${HARDENING_ROOT:-}$1"

  [[ ! -f "$path" ]] || return 0
  hardening_privileged_read_available || return 2
  sudo -n test -f "$path" 2>/dev/null || return 1
}

# managed_root_file_read <path>: prints the content; 2 when it could not be
# read without a password.
managed_root_file_read() {
  local path="${HARDENING_ROOT:-}$1"

  if [[ -r "$path" ]]; then
    cat -- "$path" 2>/dev/null
    return
  fi

  hardening_privileged_read_available || return 2
  sudo -n cat -- "$path" 2>/dev/null
}

# managed_root_file_mode <path>: prints the mode; 1 when there is none to
# read, 2 when it could not be read without a password.
managed_root_file_mode() {
  local path="${HARDENING_ROOT:-}$1"
  local mode

  mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
  if [[ -z "$mode" ]]; then
    hardening_privileged_read_available || return 2
    mode="$(sudo -n stat -c '%a' "$path" 2>/dev/null || true)"
  fi
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

apply_pam_faillock() {
  command_exists authselect || {
    warn "authselect not found; skipping pam_faillock lockout"
    return 1
  }

  if ! authselect current >/dev/null 2>&1; then
    warn "authselect has no active profile; skipping pam_faillock lockout"
    return 1
  fi

  # Each enabled feature is a `- <name>` line; match the whole line, as
  # verify-hardening.sh does, not any feature containing the name.
  if grep -Fxq -e '- with-faillock' <<<"$(authselect current 2>/dev/null)"; then
    info "pam_faillock already enabled via authselect"
  elif sudo authselect enable-feature with-faillock; then
    success "Enabled pam_faillock via authselect"
  else
    warn "authselect could not enable with-faillock (local modifications?);" \
      "run 'authselect current' and enable it manually if desired"
    return 1
  fi

  write_managed_dropin faillock
}

apply_sudo_audit_log() {
  local tmp

  tmp="$(mktemp)"
  hardening_dropin_content sudo-logfile >"$tmp"

  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    die "Generated sudoers drop-in failed visudo syntax check; not installing it"
  fi

  write_managed_root_file "$(hardening_dropin_path sudo-logfile)" \
    "$(hardening_dropin_mode sudo-logfile)" \
    "$(hardening_dropin_description sudo-logfile)" <"$tmp"
  rm -f "$tmp"
}

apply_auditd_rules() {
  command_exists auditctl || {
    info "Installing auditd"
    sudo dnf install -y audit
  }

  local rules_path
  rules_path="$(hardening_dropin_path auditd-rules)"
  local rooted_rules_path="${HARDENING_ROOT:-}$rules_path"
  local before after

  before=""
  sudo test -f "$rooted_rules_path" && before="$(sudo cat "$rooted_rules_path")"

  write_managed_dropin auditd-rules

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
  local path
  path="$(hardening_dropin_path sysctl)"

  write_managed_dropin sysctl

  info "Applying sysctl settings"
  sudo sysctl -p "${HARDENING_ROOT:-}$path" >/dev/null
}

sshd_present() {
  systemctl is-active --quiet sshd.service ||
    systemctl is-enabled --quiet sshd.service 2>/dev/null
}

# HARDENING_SSH_LEGACY_DROPIN is where this profile wrote the sshd drop-in
# before it sorted first. On a machine installed then it is an owned file
# sshd now reads after the current one, so it changes nothing; it is removed
# so the machine holds one copy of the policy, not two that could drift.
HARDENING_SSH_LEGACY_DROPIN=/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf

remove_legacy_ssh_dropin() {
  local legacy="${HARDENING_ROOT:-}$HARDENING_SSH_LEGACY_DROPIN"

  sudo test -f "$legacy" || return 0
  info "Removing the earlier SSH hardening drop-in, now superseded: $legacy"
  sudo rm -f -- "$legacy"
}

apply_ssh_hardening() {
  if ! sshd_present; then
    info "sshd is not active/enabled; skipping SSH posture (not installing it)"
    return 1
  fi

  local path tmp
  path="${HARDENING_ROOT:-}$(hardening_dropin_path ssh)"

  tmp="$(mktemp)"
  hardening_dropin_content ssh >"$tmp"

  if sudo test -f "$path" && sudo cmp -s "$tmp" "$path"; then
    info "SSH hardening drop-in already applied: $path"
    rm -f "$tmp"
    remove_legacy_ssh_dropin
    return 0
  fi

  sudo install -D -m "$(hardening_dropin_mode ssh)" -o root -g root "$tmp" "$path"
  rm -f "$tmp"

  if ! sudo sshd -t; then
    sudo rm -f -- "$path"
    die "sshd -t rejected the generated drop-in; removed it and aborted SSH hardening"
  fi

  remove_legacy_ssh_dropin

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
