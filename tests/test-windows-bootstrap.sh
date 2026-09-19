#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/platforms/windows/install.ps1"
wsl_version_helper="$repo_root/platforms/windows/lib/wsl-version.ps1"
theme_helper="$repo_root/platforms/windows/set-noctty-theme.ps1"
windows_manifest="$repo_root/platforms/windows/manifest.psd1"
windows_verifier="$repo_root/platforms/windows/verify.ps1"
network_sources="$repo_root/config/network-sources.tsv"
dictation_doc="$repo_root/docs/profiles/dictation.md"

[[ -f "$installer" ]]
[[ -f "$wsl_version_helper" ]]
[[ -f "$theme_helper" ]]
[[ -f "$windows_manifest" ]]
[[ -f "$windows_verifier" ]]
[[ -f "$dictation_doc" ]]

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
grep -Fq -- '& wsl.exe --version' "$installer"
grep -Fq -- 'Older versions may work but are unvalidated.' "$installer"
grep -Fq -- 'Unable to determine the installed WSL version.' "$installer"

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
grep -Fq 'https://github.com/amanthanvi/scoop-noctty' "$windows_manifest"
grep -Fq "QualifiedName = 'noctty/noctty'" "$windows_manifest"

# Voice dictation on Windows is Handy, installed per-user from Scoop's
# official `extras` bucket, where its manifest is sha256-pinned. That is why
# the Windows bootstrap stays entirely on Scoop and why the `winget install`
# guard further down is deliberately left as a global prohibition rather than
# narrowed to Noctty. See docs/profiles/dictation.md.
grep -Fq 'https://github.com/ScoopInstaller/Extras' "$windows_manifest"
grep -Fq "Name = 'extras'" "$windows_manifest"
grep -Fq "QualifiedName = 'extras/handy'" "$windows_manifest"
grep -Fq "Executable = 'handy.exe'" "$windows_manifest"
grep -Fq 'scoop-extras-bucket' "$network_sources"
grep -Fq 'https://github.com/ScoopInstaller/Extras' "$network_sources"

# The manifest is the single source of truth for bucket and package names.
for hardcoded_scoop_name in 'https://github.com/ScoopInstaller/Extras' 'extras/handy'; do
  if grep -Fq -- "$hardcoded_scoop_name" "$installer"; then
    printf 'Scoop names belong in platforms/windows/manifest.psd1, not the installer: %s\n' \
      "$hardcoded_scoop_name" >&2
    exit 1
  fi
done

# Dictation is opt-in desktop tooling: it must never become a prerequisite of
# the WSL/terminal bootstrap, so the installer defines Install-Handy and calls
# it from exactly one guarded call site.
grep -Fq -- 'function Install-Handy' "$installer"
# These identifiers belong to PowerShell, not Bash.
# shellcheck disable=SC2016
grep -Fq -- '[switch]$Handy' "$installer"
# shellcheck disable=SC2016
grep -Fq -- 'if ($Handy) {' "$installer"
# shellcheck disable=SC2016
grep -Fq -- 'HandySelected = $Handy.IsPresent' "$installer"
if [[ "$(grep -Fc -- 'Install-Handy' "$installer")" -ne 2 ]]; then
  printf 'Install-Handy must be defined once and called from one guarded call site.\n' >&2
  exit 1
fi

install_handy_body="$(awk '/^function Install-Handy/,/^}/' "$installer")"
grep -Fq 'Scoop.ExtrasBucket' <<<"$install_handy_body"
grep -Fq 'Scoop.HandyPackage' <<<"$install_handy_body"
# Reuses the shared Scoop helpers instead of duplicating them, stays
# idempotent, and keeps --DryRun honest.
grep -Fq 'Test-ScoopPackageInstalled' <<<"$install_handy_body"
grep -Fq 'Handy is already installed' <<<"$install_handy_body"
grep -Fq 'Add-ScoopBucket -Scoop' <<<"$install_handy_body"
grep -Fq 'Install-ScoopPackage -Scoop' <<<"$install_handy_body"
grep -Fq 'Would install' <<<"$install_handy_body"
if grep -Fqi 'winget' <<<"$install_handy_body"; then
  printf 'Handy is a Scoop extras package; it must not be installed through WinGet.\n' >&2
  exit 1
fi

# Privacy: Handy keeps its models, settings and any transcription history in
# the Windows user profile. The installer must create nothing inside the
# checkout, and no recording, transcript or downloaded model may be tracked.
if grep -Fq 'RepositoryRoot' <<<"$install_handy_body"; then
  printf 'The dictation install must not write anything into the checkout.\n' >&2
  exit 1
fi
if git -C "$repo_root" ls-files -- \
  '*.wav' '*.mp3' '*.m4a' '*.flac' '*.ogg' '*.gguf' '*.onnx' '*.bin' '*.pt' \
  '*.safetensors' | grep -q .; then
  printf 'Recorded audio, transcripts and speech models must never be tracked.\n' >&2
  exit 1
fi

grep -Fq '## Windows' "$dictation_doc"
grep -Fq 'extras/handy' "$dictation_doc"
# The decision record has to say why the issue's WinGet boundary change was
# investigated and then not made.
grep -Fqi 'winget' "$dictation_doc"
grep -Fq "Import-PowerShellDataFile (Join-Path \$PSScriptRoot 'manifest.psd1')" "$installer"
grep -Fq 'function Write-WindowsSelectionState' "$installer"
# $selectedFedora belongs to PowerShell, not Bash.
# shellcheck disable=SC2016
grep -Fq 'Write-WindowsSelectionState -Distribution $selectedFedora' "$installer"
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

# Deliberately a global prohibition, not a Noctty-only one: every Windows
# application this repository installs is Scoop-owned, Handy included.
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
  powershell_files=(
    "$installer"
    "$wsl_version_helper"
    "$theme_helper"
    "$windows_verifier"
    "$repo_root/verify.ps1"
    # The Windows-only suites themselves: a parse error in one of them would
    # otherwise surface only on the Windows runner.
    "$repo_root/tests/test-windows-bootstrap.ps1"
    "$repo_root/tests/test-windows-verifier.ps1"
  )
  for powershell_file in "${powershell_files[@]}"; do
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

printf 'Windows Fedora WSL, Noctty and Handy bootstrap tests passed.\n'
