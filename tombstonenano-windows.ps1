<#
.SYNOPSIS
    Block/unblock Chrome's Gemini Nano on-device AI model. Frees ~4 GB.

.DESCRIPTION
    Interactive menu, four actions:
      [1] Block Gemini Nano AI        Set HKLM Chrome policy, delete weights.bin,
                                      replace the model folder with a 1 KB
                                      read-only file locked by a deny-W/D ACL
                                      on the console user's SID.
      [2] Unblock Gemini Nano AI      Reverses [1].
      [3] Disable other Chrome AI     Sets umbrella + per-feature Gen-AI
                                      policies (Help me write, Tab Organizer,
                                      Theme generation, History search,
                                      DevTools GenAI). No lock file.
      [4] Re-enable other Chrome AI   Reverses [3].

    Targets the interactive console user (not the elevation credential), so
    a standard user UAC-elevating with a different admin still cleans up the
    correct profile and the deny ACE pins to the right SID.

.NOTES
    Requires Administrator. Self-elevates via UAC. Tested on Windows 11.
    If SmartScreen blocks: Unblock-File .\tombstonenano-windows.ps1

.LINK
    https://github.com/forkymcforkface/tombstonechromenano
#>

# Copyright (c) 2026 Kev (forkymcforkface) -- https://github.com/forkymcforkface
# SPDX-License-Identifier: MIT  (see LICENSE)

[CmdletBinding()]
param(
    # Internal: set when self-elevation re-launches this script, so the new
    # elevated window stays open after Show-Menu returns. Not for end users.
    [Parameter(DontShow)]
    [switch]$PauseOnExit
)

$Version         = '1.0.0'
$VersionCheckUrl = 'https://raw.githubusercontent.com/forkymcforkface/tombstonechromenano/main/tombstonenano-windows.ps1'

# --- Self-elevate via UAC if not already admin ---
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # When invoked via `irm <url> | iex`, there is no .ps1 file on disk and
    # $PSCommandPath is empty -- so the elevated child would have nothing to run.
    # Persist our own source to %TEMP% in that case.
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        $scriptPath = $PSCommandPath
    } else {
        $scriptPath = Join-Path $env:TEMP 'tombstonenano-windows.ps1'
        $MyInvocation.MyCommand.ScriptBlock.ToString() | Set-Content -LiteralPath $scriptPath -Encoding UTF8 -Force
    }

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $scriptPath), '-PauseOnExit')
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -ErrorAction Stop
    } catch {
        Write-Error 'Elevation cancelled or failed. Re-run from an elevated PowerShell prompt.'
        exit 1
    }
    exit
}

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve the target user (the one Chrome runs as), not the elevated context.
# If the script self-elevated with different admin credentials, the current
# SID and $env:LOCALAPPDATA belong to that admin -- not to the person whose
# Chrome we want to clean up. Win32_ComputerSystem.UserName gives us the
# interactive console user instead.
# ---------------------------------------------------------------------------
function Resolve-TargetUser {
    $consoleUser = $null
    try { $consoleUser = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName } catch { }

    if ([string]::IsNullOrWhiteSpace($consoleUser)) {
        # No interactive console (server / SSH / scheduled task). Fall back.
        $consoleUser = "$env:USERDOMAIN\$env:USERNAME"
    }

    try {
        $nt  = New-Object System.Security.Principal.NTAccount($consoleUser)
        $sid = $nt.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        throw "Could not resolve SID for '$consoleUser': $($_.Exception.Message)"
    }

    $profilePath = $null
    try {
        $profilePath = (Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$sid'" -ErrorAction Stop).LocalPath
    } catch { }

    if ([string]::IsNullOrWhiteSpace($profilePath) -or -not (Test-Path -LiteralPath $profilePath)) {
        $name        = $consoleUser.Split('\')[-1]
        $profilePath = Join-Path $env:SystemDrive "Users\$name"
    }

    [pscustomobject]@{
        Account = $consoleUser
        Sid     = $sid
        Profile = $profilePath
    }
}

$target    = Resolve-TargetUser
$RegPath   = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
$RegName   = 'GenAILocalFoundationalModelSettings'
$ModelRoot = Join-Path $target.Profile 'AppData\Local\Google\Chrome\User Data\OptGuideOnDeviceModel'

# Policies set by the "Disable ALL Chrome AI features" action.
# Value 2 = "Do not allow" for the 0/1/2 = allow/improvement/disable Chrome
# Gen-AI policy family. The umbrella (GenAiDefaultSettings) covers any feature
# without its own specific policy; the explicit per-feature entries below are
# belt-and-suspenders against the umbrella being overridden by future Chrome
# defaults.
$ExtraAiPolicies = [ordered]@{
    'GenAiDefaultSettings'  = 2   # Umbrella: default for all Gen-AI features
    'HelpMeWriteSettings'   = 2   # "Help me write" in text fields
    'TabOrganizerSettings'  = 2   # AI tab grouping
    'CreateThemesSettings'  = 2   # AI theme generation
    'HistorySearchSettings' = 2   # AI-powered history search
    'DevToolsGenAiSettings' = 2   # AI assistance in DevTools
}

# Remove HKLM\...\Google\Chrome (and its Google parent) if they have no
# remaining values or subkeys. Preserves unrelated Chrome policies.
function Remove-EmptyParentKeys {
    if (-not (Test-Path $RegPath)) { return }
    $hasProps   = [bool](Get-Item $RegPath).Property
    $hasSubkeys = [bool](Get-ChildItem $RegPath -ErrorAction SilentlyContinue)
    if ($hasProps -or $hasSubkeys) { return }

    Remove-Item -Path $RegPath -Force
    Write-Host "[OK] Removed empty key: $RegPath" -ForegroundColor Green

    $googleKey = 'HKLM:\SOFTWARE\Policies\Google'
    if (-not (Test-Path $googleKey)) { return }
    $gP = [bool](Get-Item $googleKey).Property
    $gS = [bool](Get-ChildItem $googleKey -ErrorAction SilentlyContinue)
    if ($gP -or $gS) { return }

    Remove-Item -Path $googleKey -Force
    Write-Host "[OK] Removed empty key: $googleKey" -ForegroundColor Green
}

# Run a menu action with consistent error handling and a return-to-menu pause.
function Invoke-MenuAction {
    param([scriptblock]$Action)
    try { & $Action } catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
    Write-Host ''
    [void](Read-Host 'Press Enter to return to menu')
}

# Check GitHub once per session for a newer $Version. Returns the remote
# version string if newer than local, '' if same, $null on any failure
# (offline, repo missing, parse miss). Cached so menu redraws don't re-fetch.
$script:UpdateChecked = $false
$script:UpdateAvailable = $null
function Get-UpdateAvailable {
    if ($script:UpdateChecked) { return $script:UpdateAvailable }
    $script:UpdateChecked = $true
    try {
        $resp = Invoke-WebRequest -Uri $VersionCheckUrl -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        if ($resp.Content -match '\$Version\s*=\s*''([0-9.]+)''') {
            $remote = $Matches[1]
            if ([version]$remote -gt [version]$Version) {
                $script:UpdateAvailable = $remote
            }
        }
    } catch { }
    return $script:UpdateAvailable
}

# ---------------------------------------------------------------------------
# INSTALL
# ---------------------------------------------------------------------------
function Invoke-Install {
    Write-Host ''
    Write-Host '=== Blocking Gemini Nano AI ===' -ForegroundColor White
    Write-Host ''

    # 1. Registry policy
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
    New-ItemProperty -Path $RegPath -Name $RegName -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Host "[OK] Policy set: $RegPath\$RegName = 1 (DWORD)" -ForegroundColor Green

    # 2. Delete any weights.bin under the model root
    $deleted = 0
    $freed   = 0L
    if (Test-Path -LiteralPath $ModelRoot -PathType Container) {
        Get-ChildItem -Path $ModelRoot -Filter 'weights.bin' -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $size = $_.Length
                Remove-Item -LiteralPath $_.FullName -Force
                $deleted++
                $freed += $size
                Write-Host ('[OK] Deleted: {0} ({1} GB)' -f $_.FullName, [math]::Round($size / 1GB, 2)) -ForegroundColor Green
            } catch {
                Write-Warning "Could not delete $($_.FullName): $($_.Exception.Message). Close Chrome and try again."
            }
        }
    }
    if ($deleted -eq 0) {
        Write-Host '[INFO] No weights.bin found (already removed or never downloaded).' -ForegroundColor Cyan
    } else {
        Write-Host ('[OK] Freed {0} GB.' -f [math]::Round($freed / 1GB, 2)) -ForegroundColor Green
    }

    # 3. Tombstone the OptGuideOnDeviceModel path
    if (Test-Path -LiteralPath $ModelRoot -PathType Leaf) {
        Write-Host "[INFO] Permanent lock already in place at $ModelRoot." -ForegroundColor Cyan
    } else {
        if (Test-Path -LiteralPath $ModelRoot -PathType Container) {
            Remove-Item -LiteralPath $ModelRoot -Recurse -Force
        }
        $parent = Split-Path $ModelRoot -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -Path $parent -ItemType Directory -Force | Out-Null
        }

        $note   = 'TOMBSTONE: blocks Chrome Gemini Nano on-device model. To remove, re-run this script and choose Uninstall.'
        $bytes  = [System.Text.Encoding]::ASCII.GetBytes($note)
        $padded = New-Object byte[] 1024
        [Array]::Copy($bytes, $padded, [Math]::Min($bytes.Length, 1024))
        [System.IO.File]::WriteAllBytes($ModelRoot, $padded)

        Set-ItemProperty -LiteralPath $ModelRoot -Name IsReadOnly -Value $true

        & icacls $ModelRoot /inheritance:r                            2>&1 | Out-Null
        & icacls $ModelRoot /grant "*$($target.Sid):(R)"              2>&1 | Out-Null
        & icacls $ModelRoot /deny  "*$($target.Sid):(W,D,DC,WDAC,WO)" 2>&1 | Out-Null

        Write-Host "[OK] Permanent lock installed at $ModelRoot" -ForegroundColor Green
        Write-Host '     (1 KB read-only file; Chrome cannot recreate the folder)' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host 'Done. Reboot recommended so the policy applies to running Chrome processes.' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# UNINSTALL
# ---------------------------------------------------------------------------
function Invoke-Uninstall {
    Write-Host ''
    Write-Host '=== Unblocking Gemini Nano AI ===' -ForegroundColor White
    Write-Host ''

    # 1. Remove the permanent lock (tombstone) if present
    if (Test-Path -LiteralPath $ModelRoot -PathType Leaf) {
        try {
            & takeown /F $ModelRoot     2>&1 | Out-Null
            & icacls  $ModelRoot /reset 2>&1 | Out-Null
            Set-ItemProperty -LiteralPath $ModelRoot -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $ModelRoot -Force
            Write-Host "[OK] Permanent lock removed: $ModelRoot" -ForegroundColor Green
        } catch {
            Write-Warning "Could not remove the permanent lock at ${ModelRoot}: $($_.Exception.Message)"
        }
    } elseif (Test-Path -LiteralPath $ModelRoot -PathType Container) {
        Write-Host "[INFO] $ModelRoot is a normal folder (no permanent lock to remove)." -ForegroundColor Cyan
    } else {
        Write-Host "[INFO] No permanent lock found." -ForegroundColor Cyan
    }

    # 2. Remove the registry policy value, then clean up empty parent keys
    if (Test-Path $RegPath) {
        $prop = Get-ItemProperty -Path $RegPath -Name $RegName -ErrorAction SilentlyContinue
        if ($prop) {
            Remove-ItemProperty -Path $RegPath -Name $RegName -Force
            Write-Host "[OK] Policy value removed: $RegPath\$RegName" -ForegroundColor Green
        } else {
            Write-Host '[INFO] Policy value not present.' -ForegroundColor Cyan
        }

        Remove-EmptyParentKeys
    } else {
        Write-Host '[INFO] Registry policy key not present.' -ForegroundColor Cyan
    }

    Write-Host ''
    Write-Host 'Done. Restart Chrome -- it will re-download the model the next time it needs it.' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# DISABLE ALL CHROME AI (umbrella + per-feature policies)
# ---------------------------------------------------------------------------
function Invoke-DisableAllAi {
    Write-Host ''
    Write-Host '=== Disabling other Chrome AI features ===' -ForegroundColor White
    Write-Host ''

    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
    foreach ($name in $ExtraAiPolicies.Keys) {
        $val = $ExtraAiPolicies[$name]
        New-ItemProperty -Path $RegPath -Name $name -Value $val -PropertyType DWord -Force | Out-Null
        Write-Host "[OK] Policy set: $name = $val" -ForegroundColor Green
    }

    Write-Host ''
    Write-Host 'Done. Reboot or restart Chrome so the policies take effect.' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# RE-ENABLE ALL CHROME AI (remove what DisableAllAi set, leave foundational
# policy and tombstone alone)
# ---------------------------------------------------------------------------
function Invoke-EnableAllAi {
    Write-Host ''
    Write-Host '=== Re-enabling other Chrome AI features ===' -ForegroundColor White
    Write-Host ''

    if (-not (Test-Path $RegPath)) {
        Write-Host '[INFO] Registry policy key not present -- nothing to remove.' -ForegroundColor Cyan
        return
    }

    foreach ($name in $ExtraAiPolicies.Keys) {
        if (Get-ItemProperty -Path $RegPath -Name $name -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $RegPath -Name $name -Force
            Write-Host "[OK] Removed: $name" -ForegroundColor Green
        } else {
            Write-Host "[INFO] Not set: $name" -ForegroundColor Cyan
        }
    }

    Remove-EmptyParentKeys

    Write-Host ''
    Write-Host 'Done. Restart Chrome so the policy changes take effect.' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# MENU
# ---------------------------------------------------------------------------
function Get-CurrentStatus {
    $regOn   = $false
    $tombOn  = $false
    $allAiOn = $false
    try {
        if ((Get-ItemPropertyValue -Path $RegPath -Name $RegName -ErrorAction Stop) -eq 1) { $regOn = $true }
    } catch { }
    if (Test-Path -LiteralPath $ModelRoot -PathType Leaf) { $tombOn = $true }

    # All-AI block is "on" when the umbrella is set to 2.
    try {
        if ((Get-ItemPropertyValue -Path $RegPath -Name 'GenAiDefaultSettings' -ErrorAction Stop) -eq 2) { $allAiOn = $true }
    } catch { }

    [pscustomobject]@{
        Policy    = $regOn
        Tombstone = $tombOn
        AllAi     = $allAiOn
    }
}

function Show-Menu {
    while ($true) {
        $status = Get-CurrentStatus
        Clear-Host
        Write-Host ''
        Write-Host '================================================' -ForegroundColor White
        Write-Host "   TombstoneChromeNano v$Version" -ForegroundColor White
        Write-Host '================================================' -ForegroundColor White
        Write-Host '   by Kev (forkymcforkface)' -NoNewline -ForegroundColor Cyan
        Write-Host '  https://github.com/forkymcforkface' -ForegroundColor DarkCyan
        $newer = Get-UpdateAvailable
        if ($newer) {
            Write-Host "   * Update available: v$newer  (re-run the install one-liner to upgrade)" -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host '  TombstoneChromeNano deletes Chrome''s 4 GB Gemini Nano AI model,'      -ForegroundColor Gray
        Write-Host '  disables the Chrome AI setting, and drops a 1 KB "permanent'      -ForegroundColor Gray
        Write-Host '  lock" file in the model''s place. The lock prevents Chrome from'  -ForegroundColor Gray
        Write-Host '  downloading and overwriting it -- even if the AI setting is'      -ForegroundColor Gray
        Write-Host '  ever turned back on later.'                                       -ForegroundColor Gray
        Write-Host ''
        Write-Host "  User             : $($target.Account)" -ForegroundColor Cyan

        $regLabel   = if ($status.Policy)    { 'BLOCKED'  } else { 'allowed' }
        $tombLabel  = if ($status.Tombstone) { 'ON'       } else { 'off' }
        $allAiLabel = if ($status.AllAi)     { 'DISABLED' } else { 'allowed' }
        $regColor   = if ($status.Policy)    { 'Green'   } else { 'DarkGray' }
        $tombColor  = if ($status.Tombstone) { 'Green'   } else { 'DarkGray' }
        $allAiColor = if ($status.AllAi)     { 'Green'   } else { 'DarkGray' }
        Write-Host '  Gemini Nano AI   : ' -NoNewline; Write-Host $regLabel   -ForegroundColor $regColor
        Write-Host '  Permanent lock   : ' -NoNewline; Write-Host $tombLabel  -ForegroundColor $tombColor
        Write-Host '  Other AI features: ' -NoNewline; Write-Host $allAiLabel -ForegroundColor $allAiColor
        Write-Host ''
        Write-Host '  [1] Block Gemini Nano AI         (frees ~4 GB, installs permanent lock)' -ForegroundColor White
        Write-Host '  [2] Unblock Gemini Nano AI       (let Chrome use it again)'                -ForegroundColor White
        Write-Host '  [3] Disable other Chrome AI features (Help me write, etc. - no lock)'      -ForegroundColor White
        Write-Host '  [4] Re-enable other Chrome AI features'                                    -ForegroundColor White
        Write-Host '  [Q] Quit'                                                        -ForegroundColor White
        Write-Host ''
        $choice = Read-Host 'Choose an option'

        switch ($choice.Trim().ToUpper()) {
            '1'     { Invoke-MenuAction { Invoke-Install } }
            '2'     { Invoke-MenuAction { Invoke-Uninstall } }
            '3'     { Invoke-MenuAction { Invoke-DisableAllAi } }
            '4'     { Invoke-MenuAction { Invoke-EnableAllAi } }
            'Q'     { return }
            ''      { return }
            default {
                Write-Host "Invalid choice: '$choice'" -ForegroundColor Red
                Start-Sleep -Milliseconds 800
            }
        }
    }
}

Show-Menu

if ($PauseOnExit) {
    Write-Host ''
    [void](Read-Host 'Press Enter to exit')
}
