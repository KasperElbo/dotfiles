#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/verify.sh"
# shellcheck source=../../../common/lib/profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/profile-state.sh"
# shellcheck source=../../../common/lib/capabilities.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/capabilities.sh"
# shellcheck source=../../../common/lib/tool-floors.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/tool-floors.sh"
# shellcheck source=../lib/parrot.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/parrot.sh"

verify_reset
# A manual assurance is an outcome this run could not establish, so it goes
# through the counted helper. It used to be a bare printf with no counter, and
# four "NOT OBSERVED:" lines were printed the same way, so a healthy run ended
# on the unqualified "Parrot CTF verification passed." while reporting six
# degraded outcomes -- among them that the account's shell change had not taken
# effect yet, and that host isolation cannot be proven from the guest.
# finish_verification reserves that wording for zero failures, zero warnings
# and zero unobserved checks, and now sees them (issue #396, GAP-21).
manual() { warning "MANUAL ASSURANCE REQUIRED: $*"; }

command_diagnostics() {
  local command_name="$1"
  printf '  command -v: %s\n' "$(command -v "$command_name" 2>/dev/null || printf 'missing')" >&2
  type -a "$command_name" >&2 2>/dev/null || true
}

# font_charset_covers <fontconfig charset> <hex codepoint>: whether any range
# in the charset contains the codepoint.
#
# The test used to be `grep -Eq 'e0b0(-e0c8)?'`, which reduces to "does this
# text contain e0b0", so the answer turned on how fontconfig happened to split
# its ranges rather than on coverage, and gave three different wrong ones: a
# range e0a0-e0d4, which does contain U+E0B0, failed; f0001-f1af0, which does
# not contain U+F000, passed, and that is a range Nerd Font charsets genuinely
# carry; and 1e0b0-1e0b5, which covers none of the Powerline block, passed too
# (issue #390, GAP-23). A bound is read as a number here rather than matched as
# text. Ranges are compared in Bash arithmetic because Parrot's awk is mawk,
# which has no strtonum.
font_charset_covers() {
  local charset="$1"
  local target=$((16#$2))
  local entry low high

  while read -r entry; do
    [[ "$entry" =~ ^[0-9a-fA-F]+(-[0-9a-fA-F]+)?$ ]] || continue
    low=$((16#${entry%%-*}))
    high=$((16#${entry##*-}))
    if ((target >= low && target <= high)); then
      return 0
    fi
  done < <(tr -s '[:space:]' '\n' <<<"$charset")
  return 1
}

is_apt_owned_command() {
  local command_name="$1"
  local command_path
  local resolved_path

  command_path="$(command -v "$command_name" 2>/dev/null || true)"
  [[ "$command_path" == /* ]] || return 1
  resolved_path="$(realpath -e "$command_path" 2>/dev/null || printf '%s' "$command_path")"

  [[ "$command_path" != "$HOME/"* && "$resolved_path" != "$HOME/"* ]] || return 1
  dpkg-query -S "$command_path" >/dev/null 2>&1 ||
    dpkg-query -S "$resolved_path" >/dev/null 2>&1
}

require_parrot || exit 1
vm_type="$(require_qemu_vm)" || exit 1
if require_guest_channels; then
  pass "KVM/QEMU guest channels are present ($vm_type)"
else
  exit 1
fi

# The PATH a fresh Zsh login is given, captured BEFORE this verifier touches
# its own. establish_parrot_command_environment appends /usr/local/sbin,
# /usr/sbin, /sbin and, when it exists, /snap/bin, using append_path, which
# also strips prior duplicates of the entry it adds. Asserting afterwards that
# $PATH retains those entries therefore asserts what this script did two lines
# earlier, whatever the deployed Zsh hook does, and the duplicate scan could
# not see a duplicate of any of the six directories just added -- precisely
# the ones an unconditionally-appending profile would duplicate (issue #398,
# GAP-20). The marker idiom is the one the macOS verifier uses: a login shell
# is free to write before the printf, so the answer is taken from the marked
# line rather than from the whole of stdout.
# shellcheck disable=SC2016 # Expansion belongs to the child Zsh process.
configured_login_path="$(
  zsh -lic 'printf "\n__DOTFILES_VERIFY_PATH__%s\n" "$PATH"' 2>/dev/null |
    sed -n 's/^__DOTFILES_VERIFY_PATH__//p' |
    tail -n 1
)"

# Match the environment installed for the next login shell. Verification must
# not depend on whether the caller has restarted Bash/Zsh since installation.
establish_user_tool_environment
establish_parrot_command_environment

zsh_path="$(resolve_zsh_path 2>/dev/null || true)"
login_shell="$(login_shell_for_user "$(id -un)" 2>/dev/null || true)"
if [[ -n "$zsh_path" ]] && shell_paths_match "$login_shell" "$zsh_path"; then
  pass "Account login shell is the installed Zsh ($login_shell)"
else
  fail "Account login shell is not the installed Zsh: ${login_shell:-unknown}"
fi
if [[ -n "${SHELL:-}" ]] && shell_paths_match "$SHELL" "$zsh_path"; then
  pass "Current login session reports Zsh in SHELL"
else
  manual "start a new graphical login session, then confirm SHELL and the Konsole process use $zsh_path"
fi
if zsh -lic 'exit 0' >/dev/null 2>&1; then
  pass "Zsh login startup succeeds"
else
  fail "Zsh login startup failed"
fi

# The APT packages this guest must own are read from config/capabilities.tsv,
# the same rows the installers are checked against, so this list cannot drift
# from what is installed. Both rows are Parrot's: base is the working
# environment and vm-guest the guest agents. One declared package is not an
# APT package: mise is installed by its official upstream installer into
# ~/.local/bin, so dpkg has no record of it. It is excluded by name here, and
# proven instead by the mise-managed uv and Neovim checks below.
for capability in base vm-guest; do
  if ! declared_packages="$(capability_packages parrot-ctf "$capability")"; then
    fail "config/capabilities.tsv has no parrot-ctf $capability row to verify packages against"
    continue
  fi
  while IFS= read -r package; do
    case "$package" in
    "" | mise) continue ;;
    esac
    status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
    if [[ "$status" == "install ok installed" ]]; then
      pass "$package is APT-owned"
    else
      fail "APT package missing: $package"
    fi
  done <<<"$declared_packages"
done

# Run each command rather than only finding it. xclip and xxd have no
# --version, so they are checked for resolution only; nvim, bat and fd have
# their own startup checks below.
commands=(eza fzf gh git jq lazygit pipx python python3 rg sqlite3 starship stow tmux zoxide zsh)
for command_name in "${commands[@]}"; do
  check_command "$command_name" --probe
done
for command_name in bat fd nvim xclip xxd; do
  check_command "$command_name"
done

for command_name in bat fd; do
  if "$command_name" --version >/dev/null 2>&1; then
    pass "$command_name starts in the intended install-time PATH"
  else
    fail "$command_name is present but cannot start"
    command_diagnostics "$command_name"
  fi
done

check_mise_context

mise_command="$(resolve_mise_command 2>/dev/null || true)"
if [[ -n "$mise_command" ]] &&
  run_mise "$mise_command" exec -- uv --version >/dev/null 2>&1; then
  pass "mise-managed uv starts"
else
  fail "mise-managed uv is unavailable"
fi

mise_config="$XDG_CONFIG_HOME/mise/config.toml"
mapfile -t mise_tools < <(
  awk '
    /^\[tools\]$/ { in_tools = 1; next }
    /^\[/ { in_tools = 0 }
    in_tools && /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=/ {
      key = $0
      sub(/[[:space:]]*=.*/, "", key)
      sub(/^[[:space:]]*/, "", key)
      print key
    }
  ' "$mise_config" 2>/dev/null | sort
)
# The backend named here is the one the manifest must declare: Parrot's own
# Neovim is below the floor, so this profile takes it from GitHub releases
# rather than from mise's registry, which is a trust root of its own.
# network-source: neovim-github-releases
if [[ "${mise_tools[*]}" == "nvim uv" ]] &&
  grep -Fqx 'nvim = "github:neovim/neovim"' "$mise_config"; then
  pass "Parrot mise manifest is limited to uv and the Neovim exception"
else
  fail "Unexpected Parrot mise tools: ${mise_tools[*]:-(unreadable manifest)}"
fi

nvim_path=""
if [[ -n "$mise_command" ]]; then
  nvim_path="$(run_mise "$mise_command" which nvim 2>/dev/null || true)"
fi
mise_data_dir="${MISE_DATA_DIR:-$XDG_DATA_HOME/mise}"
if [[ -x "$nvim_path" && "$nvim_path" == "$mise_data_dir/installs/"* ]]; then
  pass "Neovim resolves to the mise-managed installation"
else
  fail "Neovim is not resolved from mise: ${nvim_path:-missing}"
  command_diagnostics nvim
fi

nvim_version=""
if [[ -n "$mise_command" ]]; then
  nvim_version="$(tool_version nvim run_mise "$mise_command" exec -- nvim)"
fi
check_version_at_least "Neovim" "$nvim_version" "$(tool_floor nvim)"

# Through run_mise, as the version read two lines above already is. Called
# directly, mise resolved from this verifier's working directory with no
# ceiling, so a stray directory configuration anywhere at or above it decided
# which Neovim started -- and the check reported a pass earned in a context the
# verifier had just declared non-deterministic. In the suite's contaminated
# run, "Neovim unknown does not satisfy the >= 0.12 baseline" and "Reduced
# LazyVim profile starts headlessly" were printed by the same run.
#
# The bound stays: timeout moves inside `mise exec`, because run_mise is a
# shell function and timeout can only run a program. It goes around nvim
# itself, which is what was being bounded. The assignment is exported in a
# subshell rather than written as a prefix, because a `VAR=x func` prefix on a
# function call leaves VAR set in the shell afterwards.
nvim_log="$(mktemp)"
if [[ -n "$mise_command" ]] && (
  export DOTFILES_NVIM_PROFILE=parrot-ctf
  run_mise "$mise_command" exec -- \
    timeout --kill-after=10s 2m nvim --headless +qa
) >"$nvim_log" 2>&1; then
  pass "Reduced LazyVim profile starts headlessly"
else
  fail "Reduced LazyVim profile failed headless startup"
  sed 's/^/  /' "$nvim_log" >&2
fi
rm -f -- "$nvim_log"

parrot_lock="$XDG_CONFIG_HOME/nvim/profiles/parrot-ctf/lazy-lock.json"
plugin_lock_failures=0
plugin_lock_entries=0
while IFS=$'\t' read -r plugin_name expected_commit; do
  [[ -n "$plugin_name" && -n "$expected_commit" ]] || continue
  plugin_lock_entries=$((plugin_lock_entries + 1))
  plugin_dir="$XDG_DATA_HOME/nvim/lazy/$plugin_name"
  actual_commit="$(git -C "$plugin_dir" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$actual_commit" != "$expected_commit" ]]; then
    fail "Lazy plugin lock mismatch: $plugin_name (expected $expected_commit, found ${actual_commit:-missing})"
    plugin_lock_failures=$((plugin_lock_failures + 1))
  fi
done < <(jq -r 'to_entries[] | [.key, .value.commit] | @tsv' "$parrot_lock" 2>/dev/null)
if ((plugin_lock_entries > 0 && plugin_lock_failures == 0)); then
  pass "Reduced LazyVim plugins match the Parrot lockfile"
elif ((plugin_lock_entries == 0)); then
  fail "Parrot LazyVim lockfile is missing or empty: $parrot_lock"
fi

# Two separate questions about Mason here, and the reduced profile needs both.
#
# The set has to match exactly, which is stricter than check_mason_inventory:
# a package Mason holds that the profile does not list is a failure and not a
# warning, because this guest is an isolation boundary and must not quietly
# gain tooling. The inventory read is the deployed copy under XDG_CONFIG_HOME,
# not the repository's, so it verifies what was actually stowed.
#
# Then each listed package has to really be installed, which is lib/mason.sh's
# rule and the same one every other platform's verifier applies: Mason writes a
# package's receipt last, so a directory is evidence that an installation was
# started and never that one finished. Comparing names alone let an empty or
# interrupted package satisfy the set (#366).
expected_mason_file="$XDG_CONFIG_HOME/nvim/profiles/parrot-ctf/mason-packages.txt"
parrot_mason_root="$(mason_root)"
mapfile -t expected_mason < <(mason_read_inventory "$expected_mason_file" | sort)
mapfile -t actual_mason < <(
  if [[ -d "$parrot_mason_root/packages" ]]; then
    find "$parrot_mason_root/packages" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
  fi
)
if [[ "${actual_mason[*]}" == "${expected_mason[*]}" && ${#expected_mason[@]} -gt 0 ]]; then
  pass "Mason inventory exactly matches the reduced Parrot profile"
else
  fail "Mason inventory mismatch"
  printf '  expected: %s\n  actual:   %s\n' "${expected_mason[*]:-(empty)}" "${actual_mason[*]:-(empty)}" >&2
fi

if verify_mason_ready; then
  for mason_package in ${expected_mason[@]+"${expected_mason[@]}"}; do
    check_mason_package "$parrot_mason_root" "$mason_package" || true
  done
fi

for command_name in python python3; do
  if is_apt_owned_command "$command_name"; then
    pass "$command_name remains Parrot/APT-owned"
  else
    fail "$command_name is missing or shadowed by a user/mise executable"
    command_diagnostics "$command_name"
  fi
done

protected_tools=(nmap hashcat john sqlmap gobuster ffuf hydra)
for command_name in "${protected_tools[@]}"; do
  if [[ -e "$HOME/.local/bin/$command_name" || -e "$mise_data_dir/shims/$command_name" ]]; then
    fail "Protected security-tool shim present: $command_name"
    command_diagnostics "$command_name"
  elif command_exists "$command_name"; then
    if is_apt_owned_command "$command_name"; then
      pass "$command_name remains Parrot/APT-owned"
    else
      fail "$command_name is shadowed by a non-APT executable"
      command_diagnostics "$command_name"
    fi
  else
    fail "$command_name is installed by Parrot but is not resolvable in the supported environment"
    command_diagnostics "$command_name"
  fi
done

# A login that answered nothing leaves these three checks with no evidence at
# all. Falling back to $PATH is what made them tautologies, so the absence is
# reported instead.
if [[ -z "$configured_login_path" ]]; then
  fail "A fresh Zsh login did not report a PATH, so the deployed command" \
    "environment could not be read; the checks below need it"
else
  for required_path in /usr/bin /bin /usr/local/sbin /usr/sbin /sbin; do
    case ":$configured_login_path:" in
    *":$required_path:"*) pass "The Zsh login PATH retains $required_path" ;;
    *) fail "The Zsh login PATH is missing standard Parrot directory: $required_path" ;;
    esac
  done

  duplicate_paths="$(
    tr ':' '\n' <<<"$configured_login_path" | awk 'NF && seen[$0]++ { print }' | sort -u
  )"
  if [[ -z "$duplicate_paths" ]]; then
    pass "Zsh login PATH entries are unique"
  else
    fail "The Zsh login PATH contains duplicate entries: ${duplicate_paths//$'\n'/, }"
  fi

  # The appender and this check keying on the same -d /snap/bin predicate is
  # what made the Snap case a tautology. This one asks the deployed hook, which
  # reaches its own decision from the same directory but in the login shell.
  if [[ -d /snap/bin ]]; then
    case ":$configured_login_path:" in
    *:/snap/bin:*) pass "The Zsh login PATH retains the installed Snap command directory" ;;
    *) fail "The Zsh login PATH is missing the installed Snap command directory: /snap/bin" ;;
    esac
  else
    pass "Snap is absent, so /snap/bin is deliberately omitted"
  fi
fi

selected_theme="macchiato"
theme_file="$XDG_CONFIG_HOME/dotfiles/theme"
if [[ -r "$theme_file" ]]; then
  read -r selected_theme <"$theme_file" || true
fi
starship_config="$XDG_CONFIG_HOME/starship/catppuccin-${selected_theme}.toml"
starship_log="$(mktemp)"
if TERM=xterm-256color STARSHIP_CONFIG="$starship_config" STARSHIP_SHELL=zsh \
  starship prompt >/dev/null 2>"$starship_log" &&
  ! grep -Eiq '(warn|error|failed to load config)' "$starship_log"; then
  pass "Starship config loads cleanly"
else
  fail "Starship config emitted a warning or error"
  sed 's/^/  /' "$starship_log" >&2
fi
rm -f -- "$starship_log"

font_family="$(fc-match --format='%{family}\n' 'Hack Nerd Font Mono' 2>/dev/null || true)"
if grep -Fq 'Hack Nerd Font Mono' <<<"$font_family"; then
  pass "Hack Nerd Font Mono is available to fontconfig"
else
  fail "Hack Nerd Font Mono is not available to fontconfig"
fi
font_file="$(fc-match --format='%{file}\n' 'Hack Nerd Font Mono' 2>/dev/null || true)"
font_charset="$(fc-query --format='%{charset}\n' "$font_file" 2>/dev/null || true)"
# U+E0B0 is the Powerline separator Starship's prompt draws with, and U+F000
# stands for the Nerd Font private-use block the theme's icons come from.
uncovered_glyphs=()
for representative_glyph in e0b0 f000; do
  font_charset_covers "$font_charset" "$representative_glyph" ||
    uncovered_glyphs+=("U+${representative_glyph^^}")
done
if [[ -z "$font_charset" ]]; then
  fail "fontconfig reported no character set for ${font_file:-the terminal font}"
elif ((${#uncovered_glyphs[@]} == 0)); then
  pass "Terminal font covers representative Starship Powerline and Nerd Font glyphs"
else
  fail "Terminal font does not cover ${uncovered_glyphs[*]}: ${font_file:-unknown}"
fi

konsole_profile="$XDG_DATA_HOME/konsole/Dotfiles-Parrot-CTF.profile"
konsolerc="$XDG_CONFIG_HOME/konsolerc"
if grep -Fxq 'Font=Hack Nerd Font Mono,10,-1,5,50,0,0,0,0,0' "$konsole_profile" 2>/dev/null &&
  ! grep -Eq '^[[:space:]]*Command=' "$konsole_profile" 2>/dev/null; then
  pass "Parrot Konsole profile selects the Nerd Font and inherits the account shell"
else
  fail "Parrot Konsole profile font or shell-inheritance policy is incorrect"
fi
if grep -Eq '^DefaultProfile=Dotfiles-Parrot-CTF\.profile$' "$konsolerc" 2>/dev/null; then
  pass "Dotfiles Parrot CTF is the effective Konsole profile"
else
  fail "Dotfiles Parrot CTF is not the effective Konsole profile"
fi

missing_bat_themes=()
for flavour in Latte Frappe Macchiato Mocha; do
  bat --list-themes 2>/dev/null | grep -Fxq "Catppuccin $flavour" ||
    missing_bat_themes+=("$flavour")
done
if ((${#missing_bat_themes[@]} == 0)); then
  pass "Bat provides every Catppuccin syntax theme referenced by Delta"
else
  fail "Bat is missing Catppuccin themes: ${missing_bat_themes[*]}"
fi

# The pinned plugin checkout tmux/.tmux.conf runs.
check_catppuccin_tmux

# verifies: vm-guest
#
# The Parrot CTF profile owns the guest agents that config/capabilities.tsv
# records as the vm-guest capability on this platform; the marker says so in
# the spelling scripts/validate-capabilities.py checks for.
#
# Both are deliberately is-active checks, not enabled-and-active ones. Debian
# and Parrot ship qemu-guest-agent.service as a static unit that its virtio
# device activates, so there is no enablement to check, and the guest
# installer only starts spice-vdagentd.socket, which listens on demand.
# Requiring either to be enabled would fail a correct installation.
check_system_service_active qemu-guest-agent.service
check_system_service_active spice-vdagentd.socket

printf '\nGuest isolation evidence\n'
default_route="$(ip route show default 2>/dev/null | head -n 1)"
if [[ -n "$default_route" && "$default_route" == *' dev '* ]]; then
  printf 'VERIFIED: default route/interface observed: %s\n' "$default_route"
else
  fail "No default route/interface is observable"
fi

shared_mounts="$(
  findmnt --raw --noheadings --output FSTYPE,TARGET,SOURCE 2>/dev/null |
    awk '$1 == "9p" || $1 == "virtiofs" { print }'
)"
if [[ -z "$shared_mounts" ]]; then
  not_observed "mounted 9p or virtiofs host filesystem"
else
  fail "Host filesystem passthrough is mounted: ${shared_mounts//$'\n'/; }"
fi

runtime_dir="/run/user/$(id -u)"
for socket_name in SSH_AUTH_SOCK GPG_AGENT_INFO; do
  socket_path="${!socket_name:-}"
  if [[ -z "$socket_path" ]]; then
    not_observed "$socket_name forwarding socket"
  elif [[ "$socket_path" == "$runtime_dir/"* ]]; then
    printf 'VERIFIED: %s uses a guest runtime path: %s\n' "$socket_name" "$socket_path"
    manual "confirm the local process behind $socket_name is not backed by an added host channel"
  else
    manual "review nonstandard $socket_name path: $socket_path"
  fi
done
if command_exists gpgconf; then
  gpg_socket="$(gpgconf --list-dirs agent-socket 2>/dev/null || true)"
  if [[ "$gpg_socket" == "$runtime_dir/"* ]]; then
    printf 'VERIFIED: GPG agent socket uses a guest runtime path: %s\n' "$gpg_socket"
  elif [[ -n "$gpg_socket" ]]; then
    manual "review nonstandard GPG agent socket path: $gpg_socket"
  else
    not_observed "GPG agent socket"
  fi
else
  not_observed "gpgconf-based GPG agent socket evidence"
fi
manual "guest observations cannot prove libvirt NAT, absence of inactive passthrough devices, or host-side forwarding; run the host verifier with --domain"

# Every link is checked against the exact repository file Stow should have
# linked, not only against the package that owns it. A link redirected at
# another file inside the expected package resolved under the expected root and
# was reported green (issue #369). That matters most here: this guest gets a
# narrowed mise manifest and its own command shims, and the weak check could
# not tell the CTF copy of a file from the workstation copy once both were
# inside the named package.
#
# The third argument is written out per link, read off the package layout,
# rather than derived from the deployed path: deriving it would recompute the
# same $HOME-relative mapping Stow itself applied, so a wrong link and a wrong
# expectation would agree.
section "Stow ownership"
parrot_stow="$DOTFILES_ROOT/platforms/parrot-ctf/stow"
check_symlink "$HOME/.zshenv" "$DOTFILES_ROOT/zsh" \
  "$DOTFILES_ROOT/zsh/.zshenv"
check_symlink "$XDG_CONFIG_HOME/zsh/.zshrc" "$DOTFILES_ROOT/zsh" \
  "$DOTFILES_ROOT/zsh/.config/zsh/.zshrc"
check_symlink "$XDG_CONFIG_HOME/zsh/platform-env.zsh" \
  "$parrot_stow/zsh-platform" \
  "$parrot_stow/zsh-platform/.config/zsh/platform-env.zsh"
check_symlink "$XDG_CONFIG_HOME/zsh/platform.zsh" \
  "$parrot_stow/zsh-platform" \
  "$parrot_stow/zsh-platform/.config/zsh/platform.zsh"
check_symlink "$XDG_CONFIG_HOME/git/config" "$DOTFILES_ROOT/git" \
  "$DOTFILES_ROOT/git/.config/git/config"
check_symlink "$XDG_CONFIG_HOME/mise/config.toml" \
  "$parrot_stow/mise-ctf" \
  "$parrot_stow/mise-ctf/.config/mise/config.toml"
check_symlink "$XDG_CONFIG_HOME/nvim/init.lua" "$DOTFILES_ROOT/nvim-lazyvim" \
  "$DOTFILES_ROOT/nvim-lazyvim/.config/nvim/init.lua"
check_symlink "$XDG_CONFIG_HOME/dotfiles/neovim-profile" \
  "$parrot_stow/neovim-profile" \
  "$parrot_stow/neovim-profile/.config/dotfiles/neovim-profile"
check_symlink "$HOME/.tmux.conf" "$DOTFILES_ROOT/tmux" \
  "$DOTFILES_ROOT/tmux/.tmux.conf"
check_symlink "$HOME/.local/bin/bat" \
  "$parrot_stow/command-shims" \
  "$parrot_stow/command-shims/.local/bin/bat"
check_symlink "$HOME/.local/bin/fd" \
  "$parrot_stow/command-shims" \
  "$parrot_stow/command-shims/.local/bin/fd"

state_file="$XDG_CONFIG_HOME/dotfiles/parrot-ctf.conf"
if profile_state_validate_file "$state_file" parrot-ctf &&
  [[ "$(profile_state_read "$state_file" host_secrets parrot-ctf)" == not-shared ]] &&
  [[ "$(profile_state_read "$state_file" security_tools parrot-ctf)" == parrot-apt-owned ]]; then
  pass "CTF guest installer intent is recorded (not isolation proof)"
else
  fail "Parrot CTF safety state is missing or invalid"
fi

finish_verification "Parrot CTF verification"
