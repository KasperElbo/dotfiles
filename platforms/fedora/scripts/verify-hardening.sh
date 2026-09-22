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

# describe_first_difference <expected> <actual>
#
# Names the first line where two bodies diverge, so a content failure says what
# changed rather than only that something did. Whole-body equality is the test;
# this only explains the verdict to whoever has to fix the machine.
describe_first_difference() {
  local -a expected_lines actual_lines
  local index

  mapfile -t expected_lines <<<"$1"
  mapfile -t actual_lines <<<"$2"

  for ((index = 0; index < ${#expected_lines[@]} || index < ${#actual_lines[@]}; index++)); do
    [[ "${expected_lines[index]-}" != "${actual_lines[index]-}" ]] || continue
    if ((index >= ${#actual_lines[@]})); then
      printf "line %d is missing, expected '%s'" \
        "$((index + 1))" "${expected_lines[index]}"
    elif ((index >= ${#expected_lines[@]})); then
      printf "line %d was added: '%s'" "$((index + 1))" "${actual_lines[index]}"
    else
      printf "line %d is '%s', expected '%s'" "$((index + 1))" \
        "${actual_lines[index]}" "${expected_lines[index]}"
    fi
    return 0
  done
}

# check_owned_root_file <label> <path> <expected-mode> <drop-in name>
#
# An owned drop-in has to exist, carry the mode the installer set, and hold
# byte-for-byte the body hardening_dropin_content generates under <drop-in
# name> -- the one place the installer itself writes it from. Reverting any one
# of those silently disables the control, so each is a failure on its own.
#
# The content test is whole-body equality, not a search for policy lines the
# call site happened to list. A substring search over the file called a
# faillock drop-in with every directive commented out "unmodified"; it accepted
# deny = 50 for an expected deny = 5; and it accepted an sshd drop-in carrying
# PermitRootLogin yes above the expected PermitRootLogin no, which
# sshd_config(5) resolves first-value-wins, so root SSH login was enabled while
# the file verified clean. Whole-line matching alone still accepts that last
# one, since the expected line is genuinely present; only requiring the whole
# body rejects an inserted directive without a per-keyword table to maintain.
#
# Equality is also not a stricter rule than the installer's own:
# write_managed_root_file treats a byte-identical file as "already applied" and
# rewrites anything else, so a file accepted here is a file a re-run would
# leave alone. The one difference is that both bodies are read through command
# substitution, which drops trailing newlines, so extra blank lines at the end
# of the file are tolerated where the installer's cmp would rewrite them; a
# blank line changes none of these five formats. These drop-ins are wholly
# profile-owned ("Safe to delete", says each header) and are meant to be
# overridden by a later-numbered drop-in rather than appended to, so there is
# no operator-added directive to make room for.
check_owned_root_file() {
  local label="$1"
  local path="$2"
  local expected_mode="$3"
  local dropin="$4"
  local actual_mode content expected_content

  if ! managed_root_file_exists "$path"; then
    fail "$label is missing: $path (created by the hardening profile; re-run" \
      "./scripts/install-hardening.sh to restore it)"
    return 1
  fi

  actual_mode="$(managed_root_file_mode "$path" || true)"
  if [[ "$actual_mode" != "$expected_mode" ]]; then
    fail "$label has mode ${actual_mode:-unknown}, expected $expected_mode:" \
      "$path"
    return 1
  fi

  content="$(managed_root_file_read "$path")"
  expected_content="$(hardening_dropin_content "$dropin")"
  if [[ "$content" != "$expected_content" ]]; then
    fail "$label no longer matches the policy the installer wrote" \
      "($(describe_first_difference "$expected_content" "$content")): $path" \
      "-- the control was edited, commented out, or reverted; re-run" \
      "./scripts/install-hardening.sh to restore it"
    return 1
  fi

  pass "$label is present, mode $expected_mode, and unmodified: $path"
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
  warning "SELinux is not available on this kernel (e.g. inside a" \
    "container); environmental, not something this profile can change"
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
    if command_exists authselect &&
      authselect current 2>/dev/null | grep -q with-faillock; then
      pass "authselect has with-faillock enabled"
    else
      fail "authselect no longer reports with-faillock enabled, but the" \
        "hardening profile recorded faillock=true; the lockout policy is" \
        "not in effect -- run: sudo authselect enable-feature with-faillock"
    fi

    check_owned_root_file "faillock policy drop-in" \
      /etc/security/faillock.conf.d/90-dotfiles-hardening.conf 644 faillock
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
    check_owned_root_file "sudo logfile drop-in" \
      /etc/sudoers.d/90-dotfiles-hardening 440 sudo-logfile
  fi

  # -------------------------------------------------------------------------
  # auditd (owned-required: the rules file, the service, and -- because a
  # rules file that was never loaded protects nothing -- the loaded ruleset)
  # -------------------------------------------------------------------------

  section "auditd"

  if [[ "$state_auditd" == "true" ]]; then
    check_owned_root_file "auditd watch rules" \
      /etc/audit/rules.d/90-dotfiles-hardening.rules 640 auditd-rules

    if check_system_service_enabled_and_active auditd.service; then
      if ! command_exists auditctl; then
        not_observed "auditctl is unavailable, so whether the watch rules" \
          "are loaded into the running kernel audit subsystem could not be" \
          "read"
      else
        # One read of the running kernel's ruleset, then every rule the
        # installer wrote is required in it, whole. auditctl -l prints a loaded
        # watch back in the same `-w <path> -p <perms> -k <key>` form the rules
        # file uses, so the generated body is directly comparable line by line.
        #
        # This replaced `auditctl -l | grep -q dotfiles-identity`, which proved
        # only that the substring occurred somewhere in the output: a kernel
        # holding one decoy rule keyed dotfiles-identity-DISABLED reported the
        # watch rules loaded, and dotfiles-sudoers -- the second key the
        # installer writes -- was never looked for at all, so both sudoers
        # watches could be missing from the kernel with nothing to show it.
        loaded_rules="$(sudo auditctl -l 2>/dev/null)"
        missing_rules=()
        while IFS= read -r audit_rule; do
          [[ -n "$audit_rule" ]] || continue
          grep -Fxq -- "$audit_rule" <<<"$loaded_rules" ||
            missing_rules+=("$audit_rule")
        done < <(hardening_dropin_content auditd-rules)

        if ((${#missing_rules[@]} == 0)); then
          pass "all of the dotfiles watch rules are loaded in the running kernel"
        else
          fail "a dotfiles audit watch rule is not loaded in the running" \
            "kernel: '${missing_rules[0]}' (${#missing_rules[@]} of the" \
            "profile's rules are missing, each listed below); the rules file" \
            "is present but ineffective -- run: sudo augenrules --load"
          for audit_rule in "${missing_rules[@]}"; do
            note "not loaded: $audit_rule"
          done
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

  check_owned_root_file "hardening sysctl drop-in" \
    /etc/sysctl.d/90-dotfiles-hardening.conf 644 sysctl

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

  ssh_dropin="/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf"
  case "$state_ssh" in
  hardened)
    check_owned_root_file "sshd hardening drop-in applied" "$ssh_dropin" 644 ssh
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

    automatic_conf=""
    for candidate in /etc/dnf/automatic.conf /etc/dnf/dnf5-plugins/automatic.conf; do
      if [[ -f "$candidate" ]]; then
        automatic_conf="$candidate"
        break
      fi
    done

    if [[ -n "$automatic_conf" ]]; then
      apply_updates="$(grep -E '^[[:space:]]*apply_updates[[:space:]]*=' \
        "$automatic_conf" 2>/dev/null | tail -n1 | cut -d= -f2 | xargs || true)"
      if [[ "$apply_updates" == "yes" ]]; then
        note "apply_updates=yes in $automatic_conf (this system auto-installs updates, not this profile's default)"
      else
        note "apply_updates=${apply_updates:-no} in $automatic_conf (downloads/reports only)"
      fi
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
