#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/platforms/windows/install.ps1"
theme_helper="$repo_root/platforms/windows/set-noctty-theme.ps1"

[[ -f "$installer" ]]
[[ -f "$theme_helper" ]]

grep -Fq -- "wsl.exe @arguments" "$installer"
grep -Fq -- "& \$FilePath @Arguments | Out-Host" "$installer"
grep -Fq -- "\$exitCode = \$LASTEXITCODE" "$installer"
grep -Fq -- "--list', '--online', '--quiet" "$installer"
grep -Fq -- "'^FedoraLinux(?:-\d+)?$'" "$installer"
grep -Fq -- 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json' \
  "$installer"
grep -Fq -- 'function Get-WebFedoraDistributions' "$installer"
grep -Fq -- "--set-default-version', '2'" "$installer"
grep -Fq -- "--install', '--distribution', \$Distribution, '--no-launch'" "$installer"
grep -Fq -- "\$arguments += '--web-download'" "$installer"
grep -Fq -- "--set-version', \$Distribution, '2'" "$installer"
grep -Fq -- "[switch]\$ElevatedWslUpdateOnly" "$installer"
grep -Fq -- 'function Invoke-ElevatedWslUpdate' "$installer"
grep -Fq -- "Invoke-NativeCommand -FilePath 'wsl.exe' -Arguments @('--update', '--web-download')" \
  "$installer"

# `wsl --update` always checks api.github.com/repos/Microsoft/WSL/releases
# before doing anything else, and no flag (--web-download included, verified
# to be a no-op for this command in current wsl.exe builds) avoids that
# dependency. That check commonly fails on restricted corporate networks
# even though the already-installed WSL platform can install the requested
# distribution just fine, so a failed update must not block the rest of the
# install.
install_wsl_distribution_body="$(awk '/^function Install-WslDistribution/,/^}/' "$installer")"
grep -Fq 'try {' <<<"$install_wsl_distribution_body"
grep -Fq 'Update-Wsl' <<<"$install_wsl_distribution_body"
grep -Fq 'catch {' <<<"$install_wsl_distribution_body"
grep -Fq 'Could not update WSL; continuing with the currently installed WSL platform' \
  <<<"$install_wsl_distribution_body"
grep -Fq -- '-AllowUnavailable' "$installer"
grep -Fq -- 'Would rediscover the newest official FedoraLinux distribution after the WSL update' \
  "$installer"
grep -Fq -- 'Dry run stopped at this prerequisite' "$installer"

# Start-Process -Verb RunAs opens the elevated phase in its own window whose
# output this process never sees; the elevated phase must transcript its
# output to a log file the parent reads back and shows, so a real failure
# inside the elevated phase is never reported as only an opaque exit code.
grep -Fq -- "[string]\$ElevatedLogPath" "$installer"
grep -Fq -- 'function Invoke-ElevatedPhase' "$installer"
grep -Fq -- 'function Invoke-ElevatedEntryPoint' "$installer"
# $ElevatedLogPath belongs to PowerShell, not Bash.
# shellcheck disable=SC2016
grep -Fq -- 'Start-Transcript -Path $ElevatedLogPath -Append' "$installer"
grep -Fq -- 'Elevated console output' "$installer"
grep -Fq -- 'See the elevated console output above for the actual error' \
  "$installer"

# Start-Process -Verb RunAs is known to intermittently fail to launch or
# track the elevated process with a generic error, unrelated to the elevated
# phase itself; requesting elevation must be retried rather than failing the
# whole install on a transient Windows/UAC hiccup.
invoke_elevated_phase_body="$(awk '/^function Invoke-ElevatedPhase/,/^}/' "$installer")"
grep -Fq 'maxAttempts' <<<"$invoke_elevated_phase_body"
grep -Fq 'Retrying' <<<"$invoke_elevated_phase_body"
start_process_call="Start-Process -FilePath \$powerShellPath -ArgumentList \$arguments -Verb RunAs -Wait -PassThru"
if [[ "$(grep -Fc -- "$start_process_call" <<<"$invoke_elevated_phase_body")" -ne 1 ]]; then
  printf 'Invoke-ElevatedPhase must call Start-Process -Verb RunAs from a single call site.\n' >&2
  exit 1
fi

grep -Fq 'https://get.scoop.sh' "$installer"
grep -Fq 'https://github.com/amanthanvi/scoop-noctty' "$installer"
grep -Fq "'install', 'noctty/noctty'" "$installer"
grep -Fq "ghostty\.config\ghostty\shared.conf" "$installer"
grep -Fq 'config-file = "dotfiles/ghostty.conf"' "$installer"
grep -Fq 'config-file = "dotfiles/theme.conf"' "$installer"
grep -Fq "command = direct:wsl.exe --distribution \$Distribution" "$installer"
grep -Fq 'Sync-NocttyGhosttyConfig' "$installer"
grep -Fq "Get-ChildItem -LiteralPath \$GhosttyThemes -Filter '*.conf'" "$installer"
grep -Fq "Join-Path \$PSScriptRoot 'set-noctty-theme.ps1'" "$installer"
grep -Fq "Where-Object { \$_ -match '^\s*theme\s*=' }" "$installer"
grep -Fq '# BEGIN dotfiles Fedora WSL' "$installer"
grep -Fq 'leaving it in control' "$installer"

grep -Fq "[ValidateSet('latte', 'frappe', 'macchiato', 'mocha')]" "$theme_helper"
grep -Fq "theme = catppuccin-\$Flavor.conf" "$theme_helper"
grep -Fq 'press Ctrl+Shift+, to reload, or restart Noctty' "$theme_helper"

if grep -Fq '+perform-action' "$theme_helper"; then
  printf 'Noctty theme helper must not trigger interactive CLI error dialogs.\n' >&2
  exit 1
fi

if grep -Fqi 'winget install' "$installer"; then
  printf 'Windows bootstrap must use the currently supported Noctty Scoop bucket.\n' >&2
  exit 1
fi

if grep -Fq 'FedoraLinux-44' "$installer"; then
  printf 'Windows bootstrap must discover the current Fedora WSL name dynamically.\n' >&2
  exit 1
fi

shared_config="$repo_root/ghostty/.config/ghostty/shared.conf"
ghostty_config="$repo_root/ghostty/.config/ghostty/config"
grep -Fq 'config-file = shared.conf' "$ghostty_config"
grep -Fq 'theme = catppuccin-macchiato.conf' "$shared_config"
grep -Fq 'shell-integration = zsh' "$shared_config"
grep -Fq 'shell-integration-features = cursor,sudo,title,ssh-env,ssh-terminfo' \
  "$shared_config"

if command -v pwsh >/dev/null 2>&1; then
  # pwsh -Command does not reliably populate $args from a trailing plain
  # argument; pass the path through the environment instead.
  # The variables in this command belong to PowerShell, not Bash.
  # shellcheck disable=SC2016
  for powershell_file in "$installer" "$theme_helper"; do
    POWERSHELL_FILE_TO_PARSE="$powershell_file" pwsh -NoProfile -Command '
      $tokens = $null
      $errors = $null
      [System.Management.Automation.Language.Parser]::ParseFile(
        $env:POWERSHELL_FILE_TO_PARSE, [ref]$tokens, [ref]$errors
      ) | Out-Null
      if ($errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Error $_ }
        exit 1
      }
    '
  done
fi

printf 'Windows Fedora WSL and Noctty bootstrap tests passed.\n'
