#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/verify.sh"
# shellcheck source=../../../common/lib/profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/profile-state.sh"
# shellcheck source=../lib/secure-boot.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/secure-boot.sh"
# shellcheck source=../lib/hardening.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/hardening.sh"

verify_reset

# How long a privileged probe may take to answer. Verification has to finish
# on a machine where one cannot answer at all, and say so, rather than wait.
HARDENING_PROBE_TIMEOUT="${HARDENING_PROBE_TIMEOUT:-30s}"

# ---------------------------------------------------------------------------
# Every check below is one of exactly three kinds, and the kind decides the
# outcome. Conflating them is what let a machine lose its hardening controls
# and still verify clean.
#
#   owned-required            A control this profile's installer created or
#                             enabled on this machine. Missing, altered,
#                             wrong-mode, disabled, or ineffective is a
#                             FAILURE. Only checked when the profile is
#                             actually selected.
#   baseline-required         A Fedora baseline this profile verifies but
#                             never changes (SELinux enforcing, firewalld,
#                             private-key permissions). Still a FAILURE: the
#                             profile's whole claim rests on them.
#   environmental-recommended Depends on hardware, a vendor, or an
#                             organization. A WARNING with the reason.
#   manual-assurance          Reported for a human to read. NOT verified, and
#                             labelled as such, so a pass never implies it.
#
# Nothing here writes, enables, reloads, or relabels anything.
# ---------------------------------------------------------------------------

note() {
  printf '  %s\n' "$*"
}

hardening_state="${HARDENING_STATE_FILE:-$XDG_CONFIG_HOME/dotfiles/hardening.conf}"
hardening_selected="false"
state_selinux=""
state_faillock=""
state_sudo_logfile=""
state_auditd=""
state_ssh=""
state_dnf_automatic=""

read_hardening_state() {
  profile_state_read "$hardening_state" "$1" hardening 2>/dev/null || true
}

if [[ -e "$hardening_state" ]]; then
  hardening_selected="true"
  if profile_state_validate_file "$hardening_state" hardening >/dev/null 2>&1; then
    state_selinux="$(read_hardening_state selinux_mode)"
    state_faillock="$(read_hardening_state faillock)"
    state_sudo_logfile="$(read_hardening_state sudo_logfile)"
    state_auditd="$(read_hardening_state auditd)"
    state_ssh="$(read_hardening_state ssh)"
    state_dnf_automatic="$(read_hardening_state dnf_automatic)"
  else
    fail "the hardening profile is selected but its recorded state is" \
      "unreadable or invalid: $hardening_state -- re-run" \
      "./scripts/install-hardening.sh to re-record it"
    # Owned checks need a trustworthy record of what was applied; without one
    # every result below would be a guess.
    finish_verification "Hardening verification"
    exit 1
  fi
fi

# unreadable_without_password <label> <path>
#
# A control this verifier could not read is not a control that is gone. Saying
# so is the whole point of the distinction: reporting an unreadable drop-in as
# missing would send someone to re-run the installer over a machine that is
# fine, and reporting it as present would be a guess.
unreadable_without_password() {
  not_observed "$1 could not be read without a sudo password, so whether it" \
    "is still the file the installer wrote was not checked: $2 -- run" \
    "'sudo -v' first, or run verification as root"
}

# check_owned_root_file <label> <drop-in>
#
# An owned drop-in has to exist, carry the mode the installer set, and still
# hold the content it was written with. Reverting any one of those silently
# disables the control, so each is a failure on its own.
#
# The content is compared whole, against the same
# platforms/fedora/lib/hardening.sh table the installer wrote it from. Asking
# only whether each policy line occurs somewhere in the file cannot see a line
# that was added, and an added line is enough to reverse a policy: sshd reads
# the first value it finds for a keyword, so a `PermitRootLogin yes` inserted
# above this profile's `PermitRootLogin no` enables root SSH login with every
# written line still in place. These files are small, generated, and marked
# safe to delete, so anything that is not the generated content is drift.
check_owned_root_file() {
  local label="$1"
  local dropin="$2"
  local path expected_mode actual_mode content expected status

  path="$(hardening_dropin_path "$dropin")"
  # stat(1) reports a mode without the leading zero install(1) is given.
  expected_mode="$(hardening_dropin_mode "$dropin")"
  expected_mode="${expected_mode#0}"

  managed_root_file_exists "$path"
  status=$?
  case "$status" in
  0) ;;
  1)
    fail "$label is missing: $path (created by the hardening profile; re-run" \
      "./scripts/install-hardening.sh to restore it)"
    return 1
    ;;
  *)
    unreadable_without_password "$label" "$path"
    return 0
    ;;
  esac

  status=0
  actual_mode="$(managed_root_file_mode "$path")" || status=$?
  if ((status == 2)); then
    unreadable_without_password "$label" "$path"
    return 0
  fi
  if [[ "$actual_mode" != "$expected_mode" ]]; then
    fail "$label has mode ${actual_mode:-unknown}, expected $expected_mode:" \
      "$path"
    return 1
  fi

  status=0
  content="$(managed_root_file_read "$path")" || status=$?
  if ((status == 2)); then
    unreadable_without_password "$label" "$path"
    return 0
  fi
  expected="$(hardening_dropin_content "$dropin")"
  if [[ "$content" != "$expected" ]]; then
    fail "$label no longer matches the policy the hardening profile wrote:" \
      "$path ($(hardening_dropin_difference "$expected" "$content")); the" \
      "control was reverted or edited -- re-run ./scripts/install-hardening.sh"
    return 1
  fi

  pass "$label is present, mode $expected_mode, and unmodified: $path"
}

# check_faillock_policy
#
# pam_faillock reads one file, /etc/security/faillock.conf, and then its own
# module arguments, which win over the file (pam_faillock.c applies argv after
# read_config_file). So the file is the policy, and reading it the way
# pam_faillock does says what is in effect: the dotfiles block has to be there
# as written and each of its keys has to resolve to the block's value, and no
# pam_faillock line in the PAM stack authselect writes may pass the same key
# as an argument. Until #535 this profile wrote a faillock.conf.d drop-in
# nothing read, and this check compared that file with itself.
check_faillock_policy() {
  local path status content problem pam_file overrides in_effect key value

  path="$(hardening_dropin_path faillock)"
  managed_root_file_exists "$path"
  status=$?
  case "$status" in
  0) ;;
  1)
    fail "$path is missing, so pam_faillock runs on its built-in defaults" \
      "(deny = 3, unlock_time = 600) -- re-run ./scripts/install-hardening.sh"
    return 1
    ;;
  *)
    unreadable_without_password "faillock policy" "$path"
    return 0
    ;;
  esac

  status=0
  content="$(managed_root_file_read "$path")" || status=$?
  if ((status == 2)); then
    unreadable_without_password "faillock policy" "$path"
    return 0
  fi

  problem="$(faillock_config_problem <<<"$content")"
  if [[ -n "$problem" ]]; then
    fail "the faillock policy in $path is not in effect: $problem -- re-run" \
      "./scripts/install-hardening.sh"
    return 1
  fi

  in_effect=""
  while read -r key _ value; do
    [[ -n "$key" && "$key" != \#* ]] || continue
    in_effect+="${in_effect:+, }$key = $value"
    for pam_file in system-auth password-auth; do
      overrides="$(awk -v key="$key" '
        /^[[:space:]]*#/ || !/pam_faillock\.so/ { next }
        { for (i = 1; i <= NF; i++) if (index($i, key "=") == 1 || index($i, "conf=") == 1) print $i }
      ' "${HARDENING_ROOT:-}/etc/pam.d/$pam_file" 2>/dev/null | head -n1)"
      [[ -z "$overrides" ]] && continue
      fail "/etc/pam.d/$pam_file passes $overrides to pam_faillock, which" \
        "overrides $path -- remove it, or re-select the authselect profile"
      return 1
    done
  done < <(hardening_dropin_content faillock)

  pass "pam_faillock reads $in_effect from $path"
}

# check_sshd_effective_policy
#
# A byte-identical drop-in proves what the file says, not what sshd does.
# sshd_config(5) keeps the first value it reads for a keyword, across Include
# boundaries too, so a `PermitRootLogin yes` read earlier -- above the Include
# line in /etc/ssh/sshd_config, or in a drop-in that sorts before this one,
# like the 01-permitrootlogin.conf Anaconda writes -- wins over this profile's
# drop-in while the drop-in stays untouched. `sshd -T` prints the
# configuration sshd resolved, so every directive the drop-in declares is
# looked up there, the way auditd is checked against the loaded ruleset and
# sysctl against live values.
#
# It is asked under the same timeout as sudo -l, for the same reason:
# verification has to finish, and say what it could not see, on a machine
# where the privileged probe never answers.
check_sshd_effective_policy() {
  local effective status=0 keyword value actual in_effect="" failed=0

  if ! hardening_privileged_read_available; then
    not_observed "reading sshd's effective configuration needs sudo, and" \
      "verification never asks for a password, so whether the SSH policy is" \
      "in effect was not checked -- run 'sudo -v' first, or run" \
      "verification as root"
    return 0
  fi

  effective="$(timeout --kill-after=5s "$HARDENING_PROBE_TIMEOUT" \
    sudo -n sshd -T 2>&1)" || status=$?
  if ((status == 124 || status == 137)); then
    not_observed "sshd -T did not answer within $HARDENING_PROBE_TIMEOUT," \
      "so whether the SSH policy is in effect was not checked"
    return 0
  elif ((status != 0)); then
    not_observed "sshd -T could not report the configuration sshd would run" \
      "with (exit $status: $(head -n1 <<<"$effective")), so whether the SSH" \
      "policy is in effect was not checked"
    return 0
  fi

  while read -r keyword value; do
    [[ -n "$keyword" && "$keyword" != \#* ]] || continue
    # sshd -T prints each keyword lower-cased, once, followed by its value.
    actual="$(grep -m1 -i "^${keyword} " <<<"$effective" || true)"
    actual="${actual#* }"
    if [[ "${actual,,}" != "${value,,}" ]]; then
      fail "sshd's effective configuration has $keyword ${actual:-unset}," \
        "but the hardening drop-in declares $keyword $value; a value sshd" \
        "reads first, in /etc/ssh/sshd_config above its Include line or in a" \
        "drop-in sorting before $(hardening_dropin_path ssh), overrides it --" \
        "check: sudo sshd -T | grep -i $keyword"
      failed=1
    fi
    in_effect+="${in_effect:+, }$keyword $value"
  done < <(hardening_dropin_content ssh)

  ((failed == 0)) || return 1
  pass "sshd's effective configuration has $in_effect"
}

# sudo_defaults_entries: reads Defaults entries -- a sudoers `Defaults` line
# without its keyword, or the body of sudo -l's "Matching Defaults entries"
# section -- on stdin and prints one per line, in order, as `name=value`,
# `!name` or `name`. Entries are split on commas outside double quotes; a
# backslash takes the next character literally, which is how sudo -l prints a
# value holding its own separators (secure_path=/sbin\:/bin), and the quotes
# it puts around a value holding whitespace are dropped. Lines are joined
# first, because sudo wraps a long list at whitespace.
sudo_defaults_entries() {
  local text char current="" quoted=false escaped=false i

  text="$(tr '\n' ' ')"
  sudo_defaults_flush() {
    [[ "$current" =~ ^[[:space:]]*(!*)([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*(([+-]?=)[[:space:]]*(.*[^[:space:]]|))?[[:space:]]*$ ]] ||
      return 0
    printf '%s%s%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
      "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
  }
  for ((i = 0; i < ${#text}; i++)); do
    char="${text:i:1}"
    if [[ "$escaped" == true ]]; then
      current+="$char"
      escaped=false
    elif [[ "$char" == \\ ]]; then
      escaped=true
    elif [[ "$char" == '"' ]]; then
      [[ "$quoted" == true ]] && quoted=false || quoted=true
    elif [[ "$char" == , && "$quoted" == false ]]; then
      sudo_defaults_flush
      current=""
    else
      current+="$char"
    fi
  done
  sudo_defaults_flush
}

# check_sudo_effective_policy
#
# The same gap check_sshd_effective_policy closes, with the precedence running
# the other way: sudoers(5) keeps the last Defaults entry it reads for a
# setting, and #includedir reads /etc/sudoers.d in lexical order, so a
# `Defaults !logfile` in a drop-in sorting after 90-dotfiles-hardening, or
# below the includedir line in /etc/sudoers, turns sudo command logging off
# while this profile's drop-in stays byte-identical (#535). `sudo -l` prints
# every Defaults entry that applies to the user running it, in the order sudo
# read them, so each setting the drop-in declares is resolved there, last
# entry winning. It is asked as this user, not through `sudo sudo -l`, which
# would list root's defaults and miss a `Defaults:<user> !logfile`.
#
# The listing is asked for under LC_ALL=C because its section header is
# translated, and under a timeout because verification must finish on a
# machine where sudo cannot answer (an unreachable sssd, say).
check_sudo_effective_policy() {
  local listing status=0 entries expected name actual in_effect="" failed=0

  if ! hardening_privileged_read_available; then
    not_observed "reading sudo's effective policy needs sudo, and" \
      "verification never asks for a password, so whether sudo command" \
      "logging is in effect was not checked -- run 'sudo -v' first, or run" \
      "verification as root"
    return 0
  fi

  listing="$(LC_ALL=C timeout --kill-after=5s "$HARDENING_PROBE_TIMEOUT" \
    sudo -n -l 2>&1)" || status=$?
  if ((status == 124 || status == 137)); then
    not_observed "sudo -l did not answer within $HARDENING_PROBE_TIMEOUT," \
      "so whether sudo command logging is in effect was not checked"
    return 0
  elif ((status != 0)); then
    not_observed "sudo -l could not report the policy sudo applies" \
      "(exit $status: $(head -n1 <<<"$listing")), so whether sudo command" \
      "logging is in effect was not checked"
    return 0
  fi

  # The section runs from its header to the first line that is not indented:
  # the blank line before the next section, or the next header.
  if ! grep -q '^Matching Defaults entries for ' <<<"$listing"; then
    not_observed "sudo -l answered without a 'Matching Defaults entries'" \
      "section, so whether sudo command logging is in effect was not checked"
    return 0
  fi
  entries="$(awk '
    /^Matching Defaults entries for / { inside = 1; next }
    inside && !/^[[:space:]]+[^[:space:]]/ { exit }
    inside { print }
  ' <<<"$listing" | sudo_defaults_entries)"

  while IFS= read -r expected; do
    name="${expected#!}"
    name="${name%%[+=-]*}"
    # The last entry that sets, negates or names this setting is the one sudo
    # applies; none at all means it is unset.
    actual="$(grep -E "^!*${name}([+-]?=|$)" <<<"$entries" | tail -n1 || true)"
    if [[ "$actual" != "$expected" ]]; then
      fail "sudo's effective policy has ${actual:-$name unset}, but the" \
        "hardening drop-in declares $expected; a Defaults entry sudo reads" \
        "later, in a drop-in sorting after" \
        "$(hardening_dropin_path sudo-logfile) or below the includedir line" \
        "in /etc/sudoers, overrides it -- check: sudo -l"
      failed=1
    fi
    in_effect+="${in_effect:+, }$expected"
  done < <(hardening_dropin_content sudo-logfile |
    sed -n 's/^Defaults[[:space:]]\{1,\}//p' | sudo_defaults_entries)

  ((failed == 0)) || return 1
  pass "sudo's effective policy has $in_effect"
}

# ---------------------------------------------------------------------------
# SELinux (baseline-required; the installer only ever raises permissive to
# enforcing, it never lowers the mode)
# ---------------------------------------------------------------------------

section "SELinux"

selinux_observed="$(selinux_mode)"
case "$selinux_observed" in
enforcing)
  pass "SELinux is enforcing"
  ;;
permissive)
  if [[ "$state_selinux" == "enforcing" ]]; then
    fail "SELinux is permissive, not enforcing; the hardening profile" \
      "recorded selinux_mode=enforcing, so this was reverted after" \
      "installation -- run: sudo setenforce 1"
  else
    fail "SELinux is permissive, not enforcing"
  fi
  ;;
disabled)
  fail "SELinux is disabled"
  ;;
unavailable)
  # /sys/fs/selinux is absent both inside a container, where SELinux is a
  # host-kernel feature this profile cannot reach, and on a Fedora install
  # booted with selinux=0, where it is the control being reported on. The
  # record tells them apart the way the permissive arm above already does: a
  # machine whose installation saw a working SELinux and now has none lost it
  # after installation. A record that itself says unavailable is the container
  # case, recorded as such, and stays environmental.
  case "$state_selinux" in
  "" | unavailable)
    warning "SELinux is not available on this kernel (e.g. inside a" \
      "container); environmental, not something this profile can change"
    ;;
  *)
    fail "SELinux is not available on this kernel at all, but the hardening" \
      "profile recorded selinux_mode=$state_selinux, so this kernel had" \
      "SELinux when the profile was installed and no longer does -- check" \
      "the kernel command line (grep selinux= /proc/cmdline) and" \
      "/etc/selinux/config"
    ;;
  esac
  ;;
*)
  warning "Could not determine SELinux mode"
  ;;
esac

# ---------------------------------------------------------------------------
# firewalld (baseline-required)
# ---------------------------------------------------------------------------

section "firewalld"

if check_system_service_enabled_and_active firewalld.service; then
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
      not_observed "manual assurance: whether the exposed services and open" \
        "ports above are the ones this machine should offer is a human" \
        "judgement; this profile never changes firewalld zones"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Secure Boot (environmental-recommended; report only, never modified)
# ---------------------------------------------------------------------------

section "Secure Boot"

case "$(secure_boot_state)" in
enabled)
  pass "Secure Boot is enabled"
  ;;
disabled)
  warning "Secure Boot is disabled; this is firmware state that the profile" \
    "never changes and that not every machine requires"
  ;;
*)
  warning "Secure Boot state could not be determined (firmware-dependent)"
  ;;
esac

# ---------------------------------------------------------------------------
# Profile-owned controls
#
# Only checked when the profile was actually selected: on a machine that never
# installed it, the absence of these files is correct, not a defect.
# ---------------------------------------------------------------------------

if [[ "$hardening_selected" != "true" ]]; then
  section "Hardening profile controls"
  not_observed "no hardening profile selection is recorded in" \
    "$hardening_state; profile-owned controls are not required on this" \
    "machine and were not checked"
else
  # -------------------------------------------------------------------------
  # pam_faillock (owned-required when the installer recorded that it applied)
  # -------------------------------------------------------------------------

  section "pam_faillock lockout"

  if [[ "$state_faillock" == "true" ]]; then
    # `authselect current` lists each enabled feature as its own `- <name>`
    # line, so the feature is matched as that whole line: a substring match
    # would take any feature whose name merely contains with-faillock, which a
    # custom authselect profile is free to define.
    authselect_features=""
    ! command_exists authselect ||
      authselect_features="$(authselect current 2>/dev/null || true)"
    if grep -Fxq -e '- with-faillock' <<<"$authselect_features"; then
      pass "authselect has with-faillock enabled"
    else
      fail "authselect no longer reports with-faillock enabled, but the" \
        "hardening profile recorded faillock=true; the lockout policy is" \
        "not in effect -- run: sudo authselect enable-feature with-faillock"
    fi

    check_faillock_policy
  else
    warning "the installer could not enable pam_faillock on this machine" \
      "(recorded faillock=${state_faillock:-unknown}); account lockout is" \
      "not enforced -- check 'authselect current' and enable it by hand"
  fi

  # -------------------------------------------------------------------------
  # sudo audit logging (owned-required)
  # -------------------------------------------------------------------------

  section "sudo audit logging"

  if [[ "$state_sudo_logfile" == "false" ]]; then
    warning "the installer recorded sudo_logfile=false; sudo command logging" \
      "is not configured by this profile on this machine"
  else
    check_owned_root_file "sudo logfile drop-in" sudo-logfile
    check_sudo_effective_policy
  fi

  # -------------------------------------------------------------------------
  # auditd (owned-required: the rules file, the service, and -- because a
  # rules file that was never loaded protects nothing -- the loaded ruleset)
  # -------------------------------------------------------------------------

  section "auditd"

  if [[ "$state_auditd" == "true" ]]; then
    check_owned_root_file "auditd watch rules" auditd-rules

    if check_system_service_enabled_and_active auditd.service; then
      if ! command_exists auditctl; then
        not_observed "auditctl is unavailable, so whether the watch rules" \
          "are loaded into the running kernel audit subsystem could not be" \
          "read"
      elif ! hardening_privileged_read_available; then
        not_observed "reading the loaded audit rules needs sudo, and" \
          "verification never asks for a password, so whether the watch" \
          "rules reached the running kernel was not checked -- run 'sudo -v'" \
          "first, or run verification as root"
      else
        # Every rule the installer wrote has to be in the running kernel, not
        # merely something carrying one of its keys: a partial load leaves the
        # unloaded watches recording nothing, and a key is a substring anyone
        # can put in a rule of their own. auditctl prints a loaded watch back
        # in the spelling the rules file uses, so the comparison is line for
        # line against the same source the file was written from.
        loaded_rules="$(sudo -n auditctl -l 2>/dev/null || true)"
        missing_rule=""
        while IFS= read -r audit_rule; do
          [[ -n "$audit_rule" ]] || continue
          grep -Fxq -- "$audit_rule" <<<"$loaded_rules" && continue
          missing_rule="$audit_rule"
          break
        done < <(hardening_dropin_content auditd-rules)

        if [[ -z "$missing_rule" ]]; then
          pass "every dotfiles watch rule is loaded in the running kernel"
        else
          fail "the dotfiles audit watch rule '$missing_rule' is not loaded" \
            "in the running kernel; the rules file is present but" \
            "ineffective -- run: sudo augenrules --load"
        fi
      fi
    else
      note "the hardening profile recorded auditd=true, so its watch rules" \
        "record nothing until auditd is enabled and running -- run: sudo" \
        "systemctl enable --now auditd.service"
    fi
  else
    warning "the installer recorded auditd=${state_auditd:-unknown}; audit" \
      "watch rules are not enforced by this profile on this machine"
  fi

  # -------------------------------------------------------------------------
  # sysctl hardening (owned-required: the drop-in and the values now in
  # effect, because a correct file that was never applied changes nothing)
  # -------------------------------------------------------------------------

  section "sysctl hardening"

  check_owned_root_file "hardening sysctl drop-in" sysctl

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

  # -------------------------------------------------------------------------
  # SSH posture (owned-required only when the installer actually hardened an
  # sshd that was already present; this profile never installs or enables one)
  # -------------------------------------------------------------------------

  section "SSH posture"

  case "$state_ssh" in
  hardened)
    check_owned_root_file "sshd hardening drop-in applied" ssh
    check_sshd_effective_policy
    ;;
  present-not-hardened)
    warning "sshd was present at installation but could not be hardened" \
      "(recorded ssh=present-not-hardened); re-run" \
      "./scripts/install-hardening.sh once sshd accepts the drop-in"
    ;;
  *)
    if sshd_present; then
      warning "sshd is now active/enabled but was absent at installation" \
        "(recorded ssh=${state_ssh:-not-present}); re-run" \
        "./scripts/install-hardening.sh to apply the SSH posture"
    else
      pass "sshd is not active/enabled; SSH posture is not applicable"
    fi
    ;;
  esac

  # -------------------------------------------------------------------------
  # Automatic update notifications (owned-required when the installer enabled
  # the timer)
  # -------------------------------------------------------------------------

  section "Update notifications"

  if systemctl is-enabled --quiet dnf5-automatic.timer 2>/dev/null; then
    pass "dnf5-automatic.timer is enabled"

    # DNF_AUTOMATIC_ROOT prefixes the search the way HARDENING_ROOT prefixes
    # the owned drop-ins, so a fixture can answer for this file. Empty (the
    # default) means the real root. Unlike the drop-ins this file belongs to
    # dnf: the profile enables the timer and never writes the configuration.
    automatic_conf=""
    for candidate in /etc/dnf/automatic.conf /etc/dnf/dnf5-plugins/automatic.conf; do
      candidate="${DNF_AUTOMATIC_ROOT:-}$candidate"
      if [[ -f "$candidate" ]]; then
        automatic_conf="$candidate"
        break
      fi
    done

    if [[ -n "$automatic_conf" ]]; then
      apply_updates="$(grep -E '^[[:space:]]*apply_updates[[:space:]]*=' \
        "$automatic_conf" 2>/dev/null | tail -n1 | cut -d= -f2 | xargs || true)"
      # dnf reads this key with libdnf5's OptionBool, which lower-cases the
      # value and accepts 1/yes/true/on and 0/no/false/off, rejecting anything
      # else. Comparing against the single spelling "yes" reported a machine
      # set to apply_updates = true -- which does auto-install updates -- as
      # downloading and reporting only.
      case "${apply_updates,,}" in
      1 | yes | true | on)
        note "apply_updates=$apply_updates in $automatic_conf (this system auto-installs updates, not this profile's default)"
        ;;
      0 | no | false | off)
        note "apply_updates=$apply_updates in $automatic_conf (downloads/reports only)"
        ;;
      "")
        note "$automatic_conf sets no apply_updates; the packaged default (no) applies (downloads/reports only)"
        ;;
      *)
        note "could not read apply_updates from $automatic_conf: '$apply_updates' is not a boolean dnf accepts (1/yes/true/on, 0/no/false/off), so whether this system auto-installs updates is unknown"
        ;;
      esac
    else
      note "no /etc override; using the packaged default (apply_updates=no, download_updates=yes)"
    fi
  elif [[ "$state_dnf_automatic" == "notifyonly" ]]; then
    fail "dnf5-automatic.timer is not enabled, but the hardening profile" \
      "enabled it (recorded dnf_automatic=notifyonly); update notifications" \
      "were turned off -- run: sudo systemctl enable --now dnf5-automatic.timer"
  else
    warning "dnf5-automatic.timer is not enabled and the installer did not" \
      "enable it (recorded dnf_automatic=${state_dnf_automatic:-unknown})"
  fi
fi

# ---------------------------------------------------------------------------
# Mount options (manual-assurance)
# ---------------------------------------------------------------------------

section "Mount options (manual assurance, not verified)"

for mount_point in /tmp /dev/shm /boot /home; do
  if command_exists findmnt && findmnt -no OPTIONS "$mount_point" >/dev/null 2>&1; then
    note "$mount_point: $(findmnt -no OPTIONS "$mount_point")"
  fi
done
not_observed "manual assurance: mount options are reported for review only." \
  "This profile deliberately sets none (noexec on /tmp breaks common" \
  "toolchains), so a pass here asserts nothing about them"

# ---------------------------------------------------------------------------
# Service watch-list (manual-assurance; never auto-disabled)
# ---------------------------------------------------------------------------

section "Service watch-list (manual assurance, not verified)"

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

not_observed "manual assurance: the services and listening sockets above are" \
  "reported for review. This profile never disables a service, so a pass" \
  "here does not mean the set is correct for this machine"

# ---------------------------------------------------------------------------
# Credential/secrets permission audit (baseline-required; never modifies
# files, but a world-readable private key is a real defect)
# ---------------------------------------------------------------------------

section "Credential permissions"

check_private_key_mode() {
  local path="$1"
  local mode

  [[ -f "$path" ]] || return 0

  mode="$(verify_file_mode "$path" 2>/dev/null || true)"
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

finish_verification "Hardening verification"
