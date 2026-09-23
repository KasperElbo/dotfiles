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
check_sshd_effective_policy() {
  local effective status=0 keyword value actual in_effect="" failed=0

  if ! hardening_privileged_read_available; then
    not_observed "reading sshd's effective configuration needs sudo, and" \
      "verification never asks for a password, so whether the SSH policy is" \
      "in effect was not checked -- run 'sudo -v' first, or run" \
      "verification as root"
    return 0
  fi

  effective="$(sudo -n sshd -T 2>&1)" || status=$?
  if ((status != 0)); then
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

    check_owned_root_file "faillock policy drop-in" faillock
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
