#!/usr/bin/env bash

# Fedora security-hardening helpers. Source common/lib/common.sh before this
# file. Every writer here is idempotent (safe to rerun) and only ever touches
# a single dotfiles-owned drop-in file per subsystem, so unrelated user
# configuration is never overwritten. The two exceptions are vendor files
# whose program reads no drop-in directory, each edited with a backup through
# replace_vendor_file: the SELINUX= line of /etc/selinux/config, and a marked
# block of /etc/security/faillock.conf, which pam_faillock reads alone.
#
# HARDENING_ROOT is prefixed to every path of those owned drop-ins and to
# both vendor files, for the writes, reads, stats, removals, and reloads
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
# faillock is the one record that is not a file of its own. pam_faillock
# reads exactly one file, /etc/security/faillock.conf (faillock_config.c:
# FAILLOCK_DEFAULT_CONF, with a vendor-directory copy only as a fallback when
# that file is absent), and no faillock.conf.d; this profile once wrote its
# policy into that directory, where nothing read it
# (HARDENING_FAILLOCK_LEGACY_DROPIN).
# So its content is a marked block, kept last in that file because a later
# line for a key replaces an earlier one; its mode is the one the file is
# created with when it does not exist. Only apply_faillock_policy and
# faillock_config_problem may handle it: the whole-file helpers below would
# overwrite, or reject, every line an administrator keeps there.
#
# hardening_dropin_path <name>
hardening_dropin_path() {
  case "$1" in
  faillock) printf '/etc/security/faillock.conf\n' ;;
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
      '# BEGIN dotfiles Fedora hardening profile. Delete through END to undo.' \
      'deny = 5' \
      'unlock_time = 900' \
      '# END dotfiles Fedora hardening profile'
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

# replace_vendor_file <config> <staged> [<mode>]: puts <staged> in place of
# the vendor file <config>, for the files this profile has to edit in place
# because their program reads no drop-in directory. The current file is kept
# as a timestamped backup beside it (reusing an identical backup, so reruns do
# not accumulate copies); the staged file is installed next to it with its
# mode and renamed over it in one step, then relabelled. A <mode> says the
# file does not exist yet: it is created with that mode, and there is nothing
# to back up. The backup's path, or nothing, is left in
# HARDENING_VENDOR_BACKUP for the caller's read-back to name; a global rather
# than output, so a die here stops the installer instead of a subshell.
HARDENING_VENDOR_BACKUP=""
replace_vendor_file() {
  local config="$1" staged="$2" mode="${3:-}" backup="" candidate

  if [[ -z "$mode" ]]; then
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
  fi

  sudo install -m "$mode" -o root -g root "$staged" "$config.dotfiles-new"
  sudo mv -f -- "$config.dotfiles-new" "$config"
  if command_exists restorecon; then
    sudo restorecon "$config"
  fi
  HARDENING_VENDOR_BACKUP="$backup"
}

# persist_selinux_enforcing: makes SELINUX=enforcing survive a reboot. SELinux
# has no drop-in mechanism and this file is boot-relevant, so it is not edited
# with sed -i: the new content is staged and validated first, put in place by
# replace_vendor_file, and read back while the backup is still adjacent.
persist_selinux_enforcing() {
  local config="${HARDENING_ROOT:-}/etc/selinux/config"
  local staged backup

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

  replace_vendor_file "$config" "$staged"
  rm -f -- "$staged"
  backup="$HARDENING_VENDOR_BACKUP"

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

  apply_faillock_policy
}

# HARDENING_FAILLOCK_LEGACY_DROPIN is where this profile wrote the lockout
# policy before it was found that pam_faillock never reads it. It is removed
# so a machine does not carry a file that looks like a policy and is none.
HARDENING_FAILLOCK_LEGACY_DROPIN=/etc/security/faillock.conf.d/90-dotfiles-hardening.conf

# faillock_config_value <key>: reads a faillock.conf on stdin and prints the
# value pam_faillock ends up with for <key>, or nothing when no line sets it.
# This is read_config_file's grammar: a # starts a comment anywhere on a
# line, the key runs to the first whitespace or =, the value follows after
# whitespace and at most one =, and a later line for a key replaces an
# earlier one.
faillock_config_value() {
  awk -v key="$1" '
    {
      sub(/#.*/, "")
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      if ($0 == "") next
      match($0, /^[^[:space:]=]+/)
      name = substr($0, 1, RLENGTH)
      rest = substr($0, RLENGTH + 1)
      sub(/^[[:space:]]*=?[[:space:]]*/, "", rest)
      if (name == key) { value = rest; seen = 1 }
    }
    END { if (seen) print value }
  '
}

# faillock_config_problem: reads a faillock.conf on stdin and prints what
# keeps it from carrying this profile's policy, or nothing when it does. The
# marked block has to be there once and exactly as written, and every key it
# sets has to resolve to its value in the whole file: a line added below the
# block for the same key wins over it with the block intact.
faillock_config_problem() {
  local config block expected begin end begins ends key value actual

  config="$(cat)"
  expected="$(hardening_dropin_content faillock)"
  begin="$(head -n1 <<<"$expected")"
  end="$(tail -n1 <<<"$expected")"

  begins="$(grep -cFx -- "$begin" <<<"$config" || true)"
  ends="$(grep -cFx -- "$end" <<<"$config" || true)"
  if ((begins == 0)); then
    printf 'it has no dotfiles block'
    return 0
  elif ((begins != 1 || ends != 1)); then
    printf 'its dotfiles block is duplicated or has no END line'
    return 0
  fi
  block="$(awk -v begin="$begin" -v end="$end" '
    $0 == begin { inside = 1 }
    inside { print }
    inside && $0 == end { exit }
  ' <<<"$config")"
  if [[ "$block" != "$expected" ]]; then
    printf 'its dotfiles block changed: %s' \
      "$(hardening_dropin_difference "$expected" "$block")"
    return 0
  fi

  while read -r key _ value; do
    [[ -n "$key" && "$key" != \#* ]] || continue
    actual="$(faillock_config_value "$key" <<<"$config")"
    if [[ "$actual" != "$value" ]]; then
      printf 'pam_faillock reads %s = %s from it, but the dotfiles block' \
        "$key" "$actual"
      printf ' sets %s = %s; a later line for %s overrides the block' \
        "$key" "$value" "$key"
      return 0
    fi
  done <<<"$expected"
}

# faillock_config_without_block: reads a faillock.conf on stdin and prints it
# without this profile's block, so the block can be written again at the end.
faillock_config_without_block() {
  local expected
  expected="$(hardening_dropin_content faillock)"
  awk -v begin="$(head -n1 <<<"$expected")" -v end="$(tail -n1 <<<"$expected")" '
    $0 == begin { inside = 1 }
    !inside { print }
    inside && $0 == end { inside = 0 }
  '
}

# apply_faillock_policy: writes the lockout policy into the one file
# pam_faillock reads. Every line an administrator keeps there stays; this
# profile's block is taken out wherever it is and written again last, so a
# rerun converges on one copy, placed where it wins. The file is replaced
# through replace_vendor_file (backup, staged install, rename) and read back.
apply_faillock_policy() {
  local config legacy="${HARDENING_ROOT:-}$HARDENING_FAILLOCK_LEGACY_DROPIN"
  local staged exists=false current="" problem expected begin

  config="${HARDENING_ROOT:-}$(hardening_dropin_path faillock)"

  expected="$(hardening_dropin_content faillock)"
  begin="$(head -n1 <<<"$expected")"
  if sudo test -f "$config"; then
    exists=true
    current="$(sudo cat -- "$config")"
  fi

  # A block with no end, or more than one, is not something to rewrite
  # around: taking it out would take the administrator's lines after it too.
  if [[ "$(grep -cFx -- "$begin" <<<"$current" || true)" -gt 1 ]] ||
    { grep -qFx -- "$begin" <<<"$current" &&
      ! grep -qFx -- "$(tail -n1 <<<"$expected")" <<<"$current"; }; then
    die "Refusing to rewrite $config: its dotfiles block is duplicated or" \
      "has no END line. Remove the block by hand, then rerun the hardening" \
      "profile."
  fi

  staged="$(mktemp)"
  {
    [[ "$exists" != true ]] || faillock_config_without_block <<<"$current"
    printf '%s\n' "$expected"
  } >"$staged"

  if [[ "$exists" == true ]] && sudo cmp -s "$staged" "$config"; then
    info "$(hardening_dropin_description faillock) already applied: $config"
    rm -f -- "$staged"
  else
    if [[ "$exists" == true ]]; then
      replace_vendor_file "$config" "$staged"
    else
      replace_vendor_file "$config" "$staged" \
        "$(hardening_dropin_mode faillock)"
    fi
    rm -f -- "$staged"
    problem="$(sudo cat -- "$config" | faillock_config_problem)"
    [[ -z "$problem" ]] ||
      die "$config does not carry the lockout policy after the rewrite:" \
        "$problem.${HARDENING_VENDOR_BACKUP:+ Restore it with: sudo cp -a $HARDENING_VENDOR_BACKUP $config}"
    info "Wrote $(hardening_dropin_description faillock) into $config" \
      "${HARDENING_VENDOR_BACKUP:+(backup: $HARDENING_VENDOR_BACKUP)}"
  fi

  if sudo test -f "$legacy"; then
    info "Removing the earlier faillock drop-in, which pam_faillock never read: $legacy"
    sudo rm -f -- "$legacy"
  fi
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
