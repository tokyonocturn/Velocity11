#Requires -Version 5.1
<#
.SYNOPSIS
    Velocity11 - Windows 11 privacy and gaming performance optimizer.

.DESCRIPTION
    Applies a curated set of Windows 11 privacy and gaming/performance
    registry, service and power-plan changes from a Chris Titus-style window
    (grouped checkboxes, Run Tweaks / Undo Tweaks / Create Restore Point), or
    from a numbered console menu with -Menu.

    Every apply writes a snapshot (state.json + .reg exports) to .\snapshots\<timestamp>\
    before anything is changed, and can be rolled back from that snapshot.

.PARAMETER List
    Print the tweak catalogue and exit. Does not require administrator rights.

.PARAMETER Apply
    Apply every enabled group non-interactively (asks for confirmation unless -Yes).

.PARAMETER Yes
    Skip the confirmation prompt used by -Apply.

.PARAMETER Revert
    Restore a snapshot. Without -Snapshot, the most recent snapshot is used.

.PARAMETER Snapshot
    Snapshot directory to use with -Revert.

.PARAMETER Details
    Print the full registry-level detail of every tweak and exit.

.PARAMETER Menu
    Use the numbered console menu instead of the graphical window.

.EXAMPLE
    powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\Velocity11.ps1

    Opens the GUI (default).

.EXAMPLE
    powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\Velocity11.ps1 -Menu

    Opens the numbered console menu instead of the GUI.

.EXAMPLE
    powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\Velocity11.ps1 -Apply

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Velocity11.ps1 -Revert
#>
[CmdletBinding()]
param(
    [switch]$List,
    [switch]$Apply,
    [switch]$Yes,
    [switch]$Revert,
    [string]$Snapshot,
    [switch]$Details,
    [switch]$Menu
)

# ---------------------------------------------------------------- compatibility
# Dot-sourcing only loads the functions (used by the offline test harness).
$V11DotSourced = ($MyInvocation.InvocationName -eq '.')

$script:V11Root   = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:V11SnapDir = Join-Path $script:V11Root 'snapshots'
$script:V11State   = New-Object System.Collections.ArrayList
$script:V11LogPath = $null
$script:V11Reboot  = New-Object System.Collections.ArrayList
$script:V11Notes   = New-Object System.Collections.ArrayList
$script:V11LogSink = $null      # GUI redirects Write-V11 into its log pane
$script:V11LogBox  = $null

# ---------------------------------------------------------------------- output
function Write-V11 {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host $Message -ForegroundColor $Color
    if ($script:V11LogSink) { & $script:V11LogSink $Message $Color }
    if ($script:V11LogPath) {
        try { Add-Content -Path $script:V11LogPath -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 } catch { }
    }
}

function Write-V11Rule {
    Write-V11 ('=' * 78) 'DarkGray'
}

# ------------------------------------------------------------------ elevation
function Get-V11IsAdmin {
    $id    = [Security.Principal.WindowsIdentity]::GetCurrent()
    $prin  = New-Object Security.Principal.WindowsPrincipal($id)
    return $prin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-V11Elevation {
    param([string]$ArgumentString)
    if (-not (Get-V11IsAdmin)) {
        Write-V11 'Administrator rights are required. Requesting elevation...' 'Yellow'
        try {
            $exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
            Start-Process -FilePath $exe -Verb RunAs -ArgumentList $ArgumentString
            return $true
        } catch {
            Write-V11 "Elevation was declined or failed: $($_.Exception.Message)" 'Red'
            return $false
        }
    }
    return $true
}

<#
    Starts a second, elevated copy of this script. Returns $true when a new
    elevated session was launched, $false when the UAC prompt was declined or
    elevation is unavailable. Kept in one function so the launcher flow stays
    testable without an interactive UAC prompt.
#>
function Start-V11Elevated {
    param([string]$ExtraArgs = '')
    $arg = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" {1}' -f $PSCommandPath, $ExtraArgs
    try {
        $exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList $arg -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# ------------------------------------------------------------------ registry
function Get-V11RegFull {
    param([string]$Hive, [string]$Key)
    return ('{0}:\{1}' -f $Hive, $Key)
}

function New-V11RegKey {
    param([string]$Full)
    if (Test-Path -LiteralPath $Full) { return }
    $parts = $Full -split '\\'
    $cur = $parts[0]
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $cur = '{0}\{1}' -f $cur, $parts[$i]
        if (-not (Test-Path -LiteralPath $cur)) {
            New-Item -Path $cur -Force -ErrorAction Stop | Out-Null
        }
    }
}

function ConvertTo-V11RegData {
    param([string]$RegType, $Data)
    switch ($RegType) {
        'QWord'       { return [long]$Data }
        'DWord'       { return [int]$Data }
        'MultiString' { return [string[]]$Data }
        default       { return [string]$Data }
    }
}

function ConvertFrom-V11RegData {
    param([string]$RegType, $Data)
    if ($null -eq $Data) { return $null }
    switch ($RegType) {
        'QWord'       { return [long]$Data }
        'DWord'       { return [int]$Data }
        'MultiString' { return [string[]]$Data }
        default       { return [string]$Data }
    }
}

<#
    Writes one registry value and records its previous state (or absence) so the
    change can be reverted exactly. Every mutation in Velocity11 goes through here.
#>
function Set-V11RegValue {
    param(
        [ValidateSet('HKLM', 'HKCU', 'HKCR', 'HKU')][string]$Hive = 'HKLM',
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('DWord', 'QWord', 'String', 'ExpandString', 'MultiString')][string]$RegType = 'DWord',
        [Parameter(Mandatory)][AllowNull()]$Data
    )

    $full = Get-V11RegFull -Hive $Hive -Key $Key

    # --- record previous state exactly once per value -------------------------
    $already = $false
    foreach ($e in $script:V11State) {
        if ($e.Kind -eq 'RegValue' -and $e.Hive -eq $Hive -and $e.Key -eq $Key -and $e.Name -eq $Name) { $already = $true; break }
    }
    if (-not $already) {
        $existed = $false; $prevType = $null; $prevData = $null
        $regKey = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
        if ($regKey) {
            $names = $regKey.GetValueNames()
            if ($names -contains $Name) {
                $existed = $true
                $prevType = [string]$regKey.GetValueKind($Name)
                $prevData = $regKey.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        }
        [void]$script:V11State.Add([pscustomobject][ordered]@{
            Kind    = 'RegValue'
            Hive    = $Hive
            Key     = $Key
            Name    = $Name
            Existed = $existed
            Type    = $prevType
            Data    = $prevData
        })
    }

    # --- write ----------------------------------------------------------------
    New-V11RegKey -Full $full
    $value = ConvertTo-V11RegData -RegType $RegType -Data $Data
    New-ItemProperty -LiteralPath $full -Name $Name -Value $value -PropertyType $RegType -Force -ErrorAction Stop | Out-Null
}

# ------------------------------------------------------------------- services
function Set-V11Service {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Automatic', 'Manual', 'Disabled')][string]$StartType = 'Disabled',
        [switch]$Stop
    )

    $svc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name.Replace("'", '')) -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-V11 ("  ! service '{0}' is not present on this system - skipped" -f $Name) 'DarkYellow'
        return
    }

    $already = $false
    foreach ($e in $script:V11State) {
        if ($e.Kind -eq 'Service' -and $e.Name -eq $Name) { $already = $true; break }
    }
    if (-not $already) {
        [void]$script:V11State.Add([pscustomobject][ordered]@{
            Kind      = 'Service'
            Name      = $Name
            StartType = $svc.StartMode
            State     = $svc.State
        })
    }

    Set-Service -Name $Name -StartupType $StartType -ErrorAction Stop
    if ($Stop -and $svc.State -eq 'Running') {
        try { Stop-Service -Name $Name -Force -ErrorAction Stop } catch { Write-V11 ("  ! could not stop {0}: {1}" -f $Name, $_.Exception.Message) 'DarkYellow' }
    }
}

<#
    Disables a scheduled task after recording its current state, and skips tasks
    that are not present on this build. Task names are checked at run time, so a
    machine that lacks one is simply left alone.
#>
function Disable-V11Task {
    param([Parameter(Mandatory)][string]$TaskPath, [Parameter(Mandatory)][string]$TaskName)

    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-V11 ("  ! task {0}{1} not present - skipped" -f $TaskPath, $TaskName) 'DarkGray'
        return
    }
    if ($task.State -eq 'Disabled') { return }          # already off: nothing to record

    [void]$script:V11State.Add([pscustomobject][ordered]@{
        Kind     = 'ScheduledTask'
        TaskPath = $TaskPath
        TaskName = $TaskName
        State    = [string]$task.State
    })
    Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
    Write-V11 ("  disabled scheduled task {0}{1}" -f $TaskPath, $TaskName) 'DarkGray'
}

function Get-V11PowerSettingIndex {
    param([string]$Sub, [string]$Setting, [switch]$Dc)
    $out = & powercfg /query SCHEME_CURRENT $Sub $Setting 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { return $null }
    $tag = if ($Dc) { 'Current DC Power Setting Index' } else { 'Current AC Power Setting Index' }
    if ($out -match ("{0}\s*:\s*0x([0-9A-Fa-f]+)" -f $tag)) { return [Convert]::ToInt64($Matches[1], 16) }
    return $null
}

<#
    Writes one power-plan sub-setting, but only if the machine actually exposes
    it - powercfg sub-GUIDs vary by hardware, and an unknown GUID must be
    skipped rather than written blind. The previous AC/DC indices are recorded
    so the change can be undone exactly.
#>
function Set-V11PowerSetting {
    param([string]$Sub, [string]$Setting, [int]$AcIndex)

    $prevAc = Get-V11PowerSettingIndex -Sub $Sub -Setting $Setting
    if ($null -eq $prevAc) {
        Write-V11 ("  ! power setting {0} not present on this system - skipped" -f $Setting) 'DarkGray'
        return
    }
    $prevDc = Get-V11PowerSettingIndex -Sub $Sub -Setting $Setting -Dc
    [void]$script:V11State.Add([pscustomobject][ordered]@{
        Kind    = 'PowerSetting'
        Sub     = $Sub
        Setting = $Setting
        Ac      = [int]$prevAc
        Dc      = if ($null -ne $prevDc) { [int]$prevDc } else { $null }
    })

    & powercfg /setacvalueindex SCHEME_CURRENT $Sub $Setting $AcIndex 2>&1 | Out-Null
    & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
    Write-V11 ("  power setting {0} -> 0x{1:X}" -f $Setting, $AcIndex) 'DarkGray'
}

function Set-V11Trim {
    $q = (& fsutil behavior query DisableDeleteNotify 2>&1 | Out-String)
    if ($q -notmatch 'DisableDeleteNotify[^:]*:\s*(\d)') {
        Write-V11 '  ! could not read TRIM state (locale?) - skipped' 'DarkGray'
        return
    }
    $cur = [int]$Matches[1]
    if ($cur -eq 0) { Write-V11 '  TRIM/delete notifications already enabled - no change needed' 'DarkGray'; return }

    [void]$script:V11State.Add([pscustomobject][ordered]@{ Kind = 'Trim'; Value = $cur })
    & fsutil behavior set DisableDeleteNotify 0 2>&1 | Out-Null
    Write-V11 '  TRIM/delete notifications enabled' 'DarkGray'
}

# ---------------------------------------------------------------- tweak table
function Get-V11Tweaks {
    $g = New-Object System.Collections.ArrayList

    # =========================================================== PRIVACY
    $privacy = [pscustomobject]@{
        Id      = 'privacy'
        Name    = 'Privacy'
        Desc     = 'Telemetry, tracking, advertising, location and feedback.'
        Enabled = $true
        Tweaks  = @(
            [pscustomobject]@{
                Id = 'telemetry-level'; Name = 'Diagnostic data -> lowest level'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection AllowTelemetry = 0 (DWORD). 0 is honored on Enterprise/Education/Server; on Home/Pro Windows clamps it to 1 (Required).'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'telemetry-service'; Name = 'Stop telemetry service (DiagTrack)'
                Detail = 'Sets "Connected User Experiences and Telemetry" (DiagTrack) to Disabled and stops it. dmwappushservice is left alone because it routes MDM/Intune push messages.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Service'; Name = 'DiagTrack'; StartType = 'Disabled'; Stop = $true }
                )
            },
            [pscustomobject]@{
                Id = 'wap-push'; Name = 'Stop WAP Push service (dmwappushservice) [opt-in]'
                Detail = 'Device Management WAP Push routing. Only relevant if the machine is NOT MDM/Intune managed - if it is, leave this OFF.'
                Reboot = $false; Default = $false
                Actions = @(
                    @{ Type = 'Service'; Name = 'dmwappushservice'; StartType = 'Disabled'; Stop = $true }
                )
            },
            [pscustomobject]@{
                Id = 'advertising-id'; Name = 'Advertising ID off'
                Detail = 'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo Enabled = 0 (DWORD). Per-user; stops apps using your advertising ID.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'activity-history'; Name = 'Activity history off'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System -> EnableActivityFeed / PublishUserActivities / UploadUserActivities = 0 (DWORD). Documented policies; local Timeline behaviour still varies by build.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'EnableActivityFeed'; RegType = 'DWord'; Data = 0 }
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'PublishUserActivities'; RegType = 'DWord'; Data = 0 }
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'UploadUserActivities'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'location-policy'; Name = 'Location tracking off'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors DisableLocation = 1 (DWORD). Documented policy.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'; Name = 'DisableLocation'; RegType = 'DWord'; Data = 1 }
                )
            },
            [pscustomobject]@{
                Id = 'location-service'; Name = 'Geolocation service off [opt-in]'
                Detail = 'Disables "Geolocation Service" (lfsvc). Turns location off at the service level; Find my device and app geofencing stop working.'
                Reboot = $false; Default = $false
                Actions = @(
                    @{ Type = 'Service'; Name = 'lfsvc'; StartType = 'Disabled'; Stop = $true }
                )
            },
            [pscustomobject]@{
                Id = 'feedback'; Name = 'Feedback prompts off'
                Detail = 'HKCU\Software\Microsoft\Siuf\Rules NumberOfSIUFInPeriod = 0 (DWORD) and PeriodInNanoSeconds = 0 (QWORD), plus HKLM\...\DataCollection DoNotShowFeedbackNotifications = 1 (DWORD).'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Siuf\Rules'; Name = 'NumberOfSIUFInPeriod'; RegType = 'DWord'; Data = 0 }
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Siuf\Rules'; Name = 'PeriodInNanoSeconds'; RegType = 'QWord'; Data = 0 }
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'DoNotShowFeedbackNotifications'; RegType = 'DWord'; Data = 1 }
                )
            },
            [pscustomobject]@{
                Id = 'input-personalization'; Name = 'Speech/input personalization off'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization AllowInputPersonalization = 0 (DWORD) plus HKCU\Software\Microsoft\InputPersonalization RestrictImplicitInkCollection / RestrictImplicitTextCollection = 1 (DWORD).'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\InputPersonalization'; Name = 'AllowInputPersonalization'; RegType = 'DWord'; Data = 0 }
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitInkCollection'; RegType = 'DWord'; Data = 1 }
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitTextCollection'; RegType = 'DWord'; Data = 1 }
                )
            },
            [pscustomobject]@{
                Id = 'app-launch-tracking'; Name = 'App launch tracking off'
                Detail = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced Start_TrackProgs = 0 (DWORD). Used for Start/search "most used" ranking.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_TrackProgs'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'tailored-experiences'; Name = 'Tailored experiences off'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent DisableTailoredExperiencesWithDiagnosticData = 1 (DWORD): diagnostic data may no longer be used for tips/recommendations.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableTailoredExperiencesWithDiagnosticData'; RegType = 'DWord'; Data = 1 }
                )
            },
            [pscustomobject]@{
                Id = 'find-my-device'; Name = 'Find my device off'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\FindMyDevice AllowFindMyDevice = 0 (DWORD). Documented policy (Experience CSP, Windows 10 1703+).'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\FindMyDevice'; Name = 'AllowFindMyDevice'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'settings-sync'; Name = 'Settings sync off'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\SettingSync DisableSettingSync = 1 (DWORD). Documented ADMX-backed policy: stops themes, credentials and other settings syncing to a Microsoft account.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableSettingSync'; RegType = 'DWord'; Data = 1 }
                )
            },
            [pscustomobject]@{
                Id = 'background-apps'; Name = 'Apps blocked from running in background'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy LetAppsRunInBackground = 2 (DWORD: 0 = user in control, 1 = force allow, 2 = force deny). Documented Privacy CSP policy.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsRunInBackground'; RegType = 'DWord'; Data = 2 }
                )
            },
            [pscustomobject]@{
                Id = 'app-sensors'; Name = 'App access to location/mic/camera denied [opt-in]'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy -> LetAppsAccessLocation / LetAppsAccessMicrophone / LetAppsAccessCamera = 2 (Force deny, documented). WARNING: breaks voice chat, streaming and camera inside Store (UWP) apps; desktop Win32 apps such as Discord and OBS are not governed by these policies.'
                Reboot = $false; Default = $false
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsAccessLocation'; RegType = 'DWord'; Data = 2 }
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsAccessMicrophone'; RegType = 'DWord'; Data = 2 }
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsAccessCamera'; RegType = 'DWord'; Data = 2 }
                )
            },
            [pscustomobject]@{
                Id = 'telemetry-tasks'; Name = 'Telemetry scheduled tasks disabled'
                Detail = 'Disables (never deletes) the CEIP / compatibility / diagnostic tasks: Compatibility Appraiser, ProgramDataUpdater, Consolidator, UsbCeip, DiskDiagnosticDataCollector, Feedback DmClient and WER QueueReporting. Task names are checked at run time and each task state is recorded for undo (Enable-ScheduledTask).'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Script'; Run = {
                        $tasks = @(
                            @{ Path = '\Microsoft\Windows\Application Experience\';                 Name = 'Microsoft Compatibility Appraiser' }
                            @{ Path = '\Microsoft\Windows\Application Experience\';                 Name = 'ProgramDataUpdater' }
                            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' }
                            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' }
                            @{ Path = '\Microsoft\Windows\DiskDiagnostic\';                          Name = 'Microsoft-Windows-DiskDiagnosticDataCollector' }
                            @{ Path = '\Microsoft\Windows\Feedback\Siuf\';                          Name = 'DmClient' }
                            @{ Path = '\Microsoft\Windows\Windows Error Reporting\';                Name = 'QueueReporting' }
                        )
                        foreach ($t in $tasks) { Disable-V11Task -TaskPath $t.Path -TaskName $t.Name }
                    } }
                )
            },
            [pscustomobject]@{
                Id = 'desktop-spotlight'; Name = 'Desktop Spotlight off'
                Detail = 'HKCU\Software\Policies\Microsoft\Windows\CloudContent DisableSpotlightCollectionOnDesktop = 1 (DWORD) - the registry mapping of the documented Spotlight-on-desktop policy (Experience CSP).'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableSpotlightCollectionOnDesktop'; RegType = 'DWord'; Data = 1 }
                )
            },
            [pscustomobject]@{
                Id = 'wer-service'; Name = 'Windows Error Reporting service off [opt-in]'
                Detail = 'Sets WerSvc (Windows Error Reporting) to Disabled. Stops crash reports being queued/sent; local crash dumps and Event Viewer records are unaffected, but debugging help and some app crash recovery prompts disappear.'
                Reboot = $false; Default = $false
                Actions = @(
                    @{ Type = 'Service'; Name = 'WerSvc'; StartType = 'Disabled'; Stop = $true }
                )
            },
            [pscustomobject]@{
                Id = 'maps-service'; Name = 'Downloaded Maps Manager off [opt-in]'
                Detail = 'Sets MapsBroker to Disabled. Apps that use offline maps may lose map downloads; nothing else depends on it.'
                Reboot = $false; Default = $false
                Actions = @(
                    @{ Type = 'Service'; Name = 'MapsBroker'; StartType = 'Disabled'; Stop = $true }
                )
            },
            [pscustomobject]@{
                Id = 'retail-demo'; Name = 'Retail Demo service off [opt-in]'
                Detail = 'Sets RetailDemo to Disabled. That service only drives in-store demo mode; it is queried first, so a machine without it is left alone.'
                Reboot = $false; Default = $false
                Actions = @(
                    @{ Type = 'Service'; Name = 'RetailDemo'; StartType = 'Disabled'; Stop = $true }
                )
            }
        )
    }

    # =========================================================== SEARCH & WIDGETS
    $search = [pscustomobject]@{
        Id      = 'search'
        Name    = 'Search & widgets'
        Desc     = 'Web results in Start, Cortana, Explorer search suggestions, Widgets.'
        Enabled = $true
        Tweaks  = @(
            [pscustomobject]@{
                Id = 'web-search'; Name = 'Web search results off'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search -> DisableWebSearch = 1 and ConnectedSearchUseWeb = 0 (DWORD). Local/indexed search keeps working.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'DisableWebSearch'; RegType = 'DWord'; Data = 1 }
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'ConnectedSearchUseWeb'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'cortana'; Name = 'Cortana off'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search AllowCortana = 0 (DWORD).'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCortana'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'bing-start'; Name = 'Bing in Start search off (legacy values)'
                Detail = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search -> BingSearchEnabled = 0, CortanaConsent = 0 (DWORD). Widely used values that current builds do not document; harmless if ignored.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BingSearchEnabled'; RegType = 'DWord'; Data = 0 }
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'CortanaConsent'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'explorer-suggestions'; Name = 'File Explorer search suggestions off'
                Detail = 'HKCU\Software\Policies\Microsoft\Windows\Explorer DisableSearchBoxSuggestions = 1 (DWORD): stops Explorer search-box suggestions and stops those queries being saved.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; RegType = 'DWord'; Data = 1 }
                )
            },
            [pscustomobject]@{
                Id = 'widgets'; Name = 'Widgets / News and interests off'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Dsh AllowNewsAndInterests = 0 (DWORD). Removes the Widgets pane from the taskbar.'
                Reboot = $true; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests'; RegType = 'DWord'; Data = 0 }
                )
            }
        )
    }

    # =========================================================== CONTENT & UI
    $content = [pscustomobject]@{
        Id      = 'content'
        Name    = 'Suggestions & lock screen'
        Desc     = 'Promoted apps, Windows tips, Spotlight, lock screen notifications.'
        Enabled = $true
        Tweaks  = @(
            [pscustomobject]@{
                Id = 'consumer-features'; Name = 'Suggested apps / consumer features off'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent DisableWindowsConsumerFeatures = 1 (DWORD): stops post-OOBE app installs, Start suggestions and membership tiles. Microsoft documents this policy for Enterprise editions.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; RegType = 'DWord'; Data = 1 }
                )
            },
            [pscustomobject]@{
                Id = 'tips'; Name = 'Windows tips / soft landing off'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent DisableSoftLanding = 1 (DWORD) plus HKCU ContentDeliveryManager SoftLandingEnabled = 0 and SubscribedContent-338389Enabled = 0. The SubscribedContent-* names are commonly used but not documented by Microsoft.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableSoftLanding'; RegType = 'DWord'; Data = 1 }
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SoftLandingEnabled'; RegType = 'DWord'; Data = 0 }
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338389Enabled'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'silent-installs'; Name = 'Silent app installs off'
                Detail = 'HKCU ContentDeliveryManager -> SilentInstalledAppsEnabled = 0, PreInstalledAppsEnabled = 0, OemPreInstalledAppsEnabled = 0 (DWORD).'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SilentInstalledAppsEnabled'; RegType = 'DWord'; Data = 0 }
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEnabled'; RegType = 'DWord'; Data = 0 }
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'OemPreInstalledAppsEnabled'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'start-suggestions'; Name = 'Start menu suggestions off'
                Detail = 'HKCU ContentDeliveryManager -> SubscribedContent-338388Enabled = 0 and SystemPaneSuggestionsEnabled = 0 (DWORD).'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338388Enabled'; RegType = 'DWord'; Data = 0 }
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SystemPaneSuggestionsEnabled'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'lock-screen'; Name = 'Lock screen Spotlight off'
                Detail = 'HKCU ContentDeliveryManager -> RotatingLockScreenEnabled = 0 and RotatingLockScreenOverlayEnabled = 0 (DWORD): stops rotating Spotlight images and their overlays on the lock screen.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'RotatingLockScreenEnabled'; RegType = 'DWord'; Data = 0 }
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'RotatingLockScreenOverlayEnabled'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'lock-screen-notifications'; Name = 'Lock screen notifications off'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System DisableLockScreenAppNotifications = 1 (DWORD).'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'DisableLockScreenAppNotifications'; RegType = 'DWord'; Data = 1 }
                )
            }
        )
    }

    # =========================================================== GAMING
    $gaming = [pscustomobject]@{
        Id      = 'gaming'
        Name    = 'Gaming'
        Desc     = 'Game Mode, background recording, GPU scheduling, input latency.'
        Enabled = $true
        Tweaks  = @(
            [pscustomobject]@{
                Id = 'game-mode'; Name = 'Game Mode on'
                Detail = 'HKCU\Software\Microsoft\GameBar AutoGameModeEnabled = 1 (DWORD) - the value the Settings Game Mode toggle uses.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; RegType = 'DWord'; Data = 1 }
                )
            },
            [pscustomobject]@{
                Id = 'game-dvr'; Name = 'Background game recording off'
                Detail = 'HKCU\System\GameConfigStore GameDVR_Enabled = 0 (DWORD): turns off Game DVR recording. Game Bar itself stays installed.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'System\GameConfigStore'; Name = 'GameDVR_Enabled'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'hags'; Name = 'Hardware-accelerated GPU scheduling on'
                Detail = 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers HwSchMode = 2 (DWORD), 1 = off. Needs a reboot and a supported GPU/driver; writing it does not add support.'
                Reboot = $true; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'HwSchMode'; RegType = 'DWord'; Data = 2 }
                )
            },
            [pscustomobject]@{
                Id = 'input-latency'; Name = 'Mouse acceleration off, key repeat fast'
                Detail = 'HKCU\Control Panel\Mouse MouseSpeed/MouseThreshold1/MouseThreshold2 = "0" (REG_SZ) disables Enhance pointer precision; HKCU\Control Panel\Keyboard KeyboardDelay = "0", KeyboardSpeed = "31".'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Control Panel\Mouse'; Name = 'MouseSpeed'; RegType = 'String'; Data = '0' }
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Control Panel\Mouse'; Name = 'MouseThreshold1'; RegType = 'String'; Data = '0' }
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Control Panel\Mouse'; Name = 'MouseThreshold2'; RegType = 'String'; Data = '0' }
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Control Panel\Keyboard'; Name = 'KeyboardDelay'; RegType = 'String'; Data = '0' }
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Control Panel\Keyboard'; Name = 'KeyboardSpeed'; RegType = 'String'; Data = '31' }
                )
            }
        )
    }

    # =========================================================== PERFORMANCE
    $perf = [pscustomobject]@{
        Id      = 'performance'
        Name    = 'Power & graphics'
        Desc     = 'High performance power plan, Fast Startup, visual effects.'
        Enabled = $true
        Tweaks  = @(
            [pscustomobject]@{
                Id = 'power-plan'; Name = 'High performance power plan'
                Detail = 'powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c. The previously active plan GUID is restored on revert.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Script'; Run = {
                        $hp = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
                        $prev = & powercfg /getactivescheme 2>$null | Out-String
                        if ($prev -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                            [void]$script:V11State.Add([pscustomobject][ordered]@{ Kind = 'PowerPlan'; Guid = $Matches[1] })
                        }
                        $out = & powercfg /setactive $hp 2>&1 | Out-String
                        if ($LASTEXITCODE -ne 0) {
                            # Scheme may exist but be hidden - duplicate it first, then activate the copy.
                            $dup = & powercfg /duplicatescheme $hp 2>&1 | Out-String
                            if ($dup -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                                $copy = $Matches[1]
                                $out2 = & powercfg /setactive $copy 2>&1 | Out-String
                                if ($LASTEXITCODE -ne 0) { throw "powercfg /setactive failed: $out2" }
                                [void]$script:V11Notes.Add("High performance scheme was duplicated as $copy.")
                            } else {
                                throw "powercfg /setactive failed: $out"
                            }
                        }
                    } }
                )
            },
            [pscustomobject]@{
                Id = 'fast-startup'; Name = 'Fast Startup off (hibernate off)'
                Detail = 'powercfg /hibernate off - removes hiberfil.sys and disables Fast Startup. Also removes the Hibernate option and hybrid sleep; revert turns it back on.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Script'; Run = {
                        $avail = (& powercfg /availablesleepstates 2>$null | Out-String)
                        $hadHibernate = [bool]($avail -match 'Hibernate')
                        [void]$script:V11State.Add([pscustomobject][ordered]@{ Kind = 'Hibernate'; Existed = $hadHibernate })
                        $out = & powercfg /hibernate off 2>&1 | Out-String
                        if ($LASTEXITCODE -ne 0) { throw "powercfg /hibernate off failed: $out" }
                    } }
                )
            },
            [pscustomobject]@{
                Id = 'visual-effects'; Name = 'Visual effects -> best performance'
                Detail = 'HKCU\...\Explorer\VisualEffects VisualFXSetting = 2 (DWORD, "Adjust for best performance"). Takes effect at the next sign-in.'
                Reboot = $true; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Name = 'VisualFXSetting'; RegType = 'DWord'; Data = 2 }
                )
            },
            [pscustomobject]@{
                Id = 'trim'; Name = 'TRIM / delete notifications on'
                Detail = 'fsutil behavior set DisableDeleteNotify 0. Microsoft documents NTFS delete notifications as enabled by default, so this only turns them back on if something disabled them - the current value is read first and no change is made when it is already 0.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Script'; Run = { Set-V11Trim } }
                )
            },
            [pscustomobject]@{
                Id = 'pcie-aspm'; Name = 'PCI Express link state power off (AC)'
                Detail = 'powercfg /setacvalueindex SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0 (None). Documented power setting; 0 = no link-state power saving, 1 = moderate, 2 = maximum. Costs a little idle power for lower latency. Skipped if the setting is not present.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Script'; Run = { Set-V11PowerSetting -Sub '501a4d13-42af-4429-9fd1-a8218c268e20' -Setting 'ee12f906-d277-404b-b6da-e5fa1a576df5' -AcIndex 0 } }
                )
            },
            [pscustomobject]@{
                Id = 'usb-suspend'; Name = 'USB selective suspend off (AC)'
                Detail = 'powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0. These are the standard USB power group/setting GUIDs but could not be confirmed on Microsoft Learn, so the setting is looked up first and skipped when absent. Helps keep controllers/mice from dropping to sleep.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Script'; Run = { Set-V11PowerSetting -Sub '2a737441-1930-4402-8d77-b2bebba308a3' -Setting '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' -AcIndex 0 } }
                )
            },
            [pscustomobject]@{
                Id = 'sysmain'; Name = 'SysMain (Superfetch) off [opt-in]'
                Detail = 'Sets SysMain to Disabled. Microsoft gives no blanket recommendation either way: with an SSD and plenty of RAM it often reduces background disk activity, on a slow disk disabling it can make launches slower. Recorded and reversible.'
                Reboot = $false; Default = $false
                Actions = @(
                    @{ Type = 'Service'; Name = 'SysMain'; StartType = 'Disabled'; Stop = $true }
                )
            }
        )
    }

    # =========================================================== NETWORK
    $net = [pscustomobject]@{
        Id      = 'network'
        Name    = 'Network'
        Desc     = 'Update peer-to-peer sharing and TCP latency behaviour.'
        Enabled = $true
        Tweaks  = @(
            [pscustomobject]@{
                Id = 'delivery-optimization'; Name = 'Update downloads: HTTP only (no P2P)'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization DODownloadMode = 0 (DWORD): no peer-to-peer update sharing. 0 = HTTP only, 1 = LAN peers, 99 = simple mode.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'nagle'; Name = 'Nagle off on active adapters'
                Detail = 'Per active interface: HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{guid} -> TcpAckFrequency = 1 (Microsoft documented, default 2) and TCPNoDelay = 1 (not Microsoft documented, added by this tool). Can affect throughput; values are deleted on revert.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Script'; Run = {
                        $root = 'SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
                        $found = 0
                        foreach ($sub in (Get-ChildItem -LiteralPath (Get-V11RegFull -Hive 'HKLM' -Key $root) -ErrorAction SilentlyContinue)) {
                            $rel  = '{0}\{1}' -f $root, $sub.PSChildName
                            $full = Get-V11RegFull -Hive 'HKLM' -Key $rel
                            $k = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
                            if (-not $k) { continue }
                            $ip   = [string]$k.GetValue('IpAddress', '')
                            $dhcp = [string]$k.GetValue('DhcpIPAddress', '')
                            if ([string]::IsNullOrWhiteSpace($ip) -and [string]::IsNullOrWhiteSpace($dhcp)) { continue }
                            Set-V11RegValue -Hive 'HKLM' -Key $rel -Name 'TcpAckFrequency' -RegType 'DWord' -Data 1
                            Set-V11RegValue -Hive 'HKLM' -Key $rel -Name 'TCPNoDelay'     -RegType 'DWord' -Data 1
                            $found++
                        }
                        [void]$script:V11Notes.Add("Nagle: tuned $found active network interface(s).")
                    } }
                )
            }
        )
    }

    # =========================================================== RESPONSIVENESS
    $responsiveness = [pscustomobject]@{
        Id      = 'responsiveness'
        Name    = 'Responsiveness'
        Desc     = 'Menu delay, animations, startup delay and the multimedia scheduler profile.'
        Enabled = $true
        Tweaks  = @(
            [pscustomobject]@{
                Id = 'transparency'; Name = 'Transparency effects off'
                Detail = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize EnableTransparency = 0 (DWORD) - the value Settings writes for "Transparency effects". Not a Microsoft-documented registry API, but the same switch Settings itself uses.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'animations'; Name = 'Minimize/maximize animation off'
                Detail = 'HKCU\Control Panel\Desktop\WindowMetrics MinAnimate = "0" (REG_SZ). Long-standing switch, still honoured on Windows 11; Microsoft does not document it as a supported interface.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Control Panel\Desktop\WindowMetrics'; Name = 'MinAnimate'; RegType = 'String'; Data = '0' }
                )
            },
            [pscustomobject]@{
                Id = 'menu-delay'; Name = 'Menu show delay = 0'
                Detail = 'HKCU\Control Panel\Desktop MenuShowDelay = "0" (REG_SZ, milliseconds). Microsoft documents the menu-show-delay property, not this registry mechanism.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Control Panel\Desktop'; Name = 'MenuShowDelay'; RegType = 'String'; Data = '0' }
                )
            },
            [pscustomobject]@{
                Id = 'startup-delay'; Name = 'Startup app delay removed'
                Detail = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize StartupDelayInMSec = 0 (DWORD). Note the correct name is StartupDelayInMSec (not StartDelayInMSec); effectiveness on current builds is UNVERIFIED, so treat this as harmless-if-ignored.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'; Name = 'StartupDelayInMSec'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'mmcss'; Name = 'Multimedia scheduler profile for games'
                Detail = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile: SystemResponsiveness = 10 (DWORD - Microsoft documents this as the CPU percentage reserved for low-priority work, default 20) plus NetworkThrottlingIndex = 0xFFFFFFFF (NOT Microsoft-documented) and subkey Tasks\Games: GPU Priority 8, Priority 6, Scheduling Category "High", SFIO Priority "High" (Microsoft documents these types and notes GPU Priority / SFIO Priority are currently unused).'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Name = 'SystemResponsiveness'; RegType = 'DWord'; Data = 10 }
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Name = 'NetworkThrottlingIndex'; RegType = 'DWord'; Data = 4294967295 }
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'GPU Priority'; RegType = 'DWord'; Data = 8 }
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'Priority'; RegType = 'DWord'; Data = 6 }
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'Scheduling Category'; RegType = 'String'; Data = 'High' }
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; Name = 'SFIO Priority'; RegType = 'String'; Data = 'High' }
                )
            }
        )
    }

    # =========================================================== GAMER
    # Opt-in by design: everything here changes real behaviour (power plan,
    # heat, notifications), so nothing is ticked unless you ask for it.
    $gamer = [pscustomobject]@{
        Id      = 'gamer'
        Name    = 'Gamer'
        Desc     = 'Opt-in extras: Ultimate Performance, core parking, controller overlay, popups, capture policy.'
        Enabled = $true
        Tweaks  = @(
            [pscustomobject]@{
                Id = 'controller-gamebar'; Name = 'Controller does not open Game Bar'
                Detail = 'HKCU\Software\Microsoft\GameBar UseNexusForGameBarEnabled = 0 (DWORD). This is the documented Windows 11 "Allow your controller to open Game Bar" toggle (Microsoft settings reference) - stops the Guide button hijacking your screen mid-match.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Software\Microsoft\GameBar'; Name = 'UseNexusForGameBarEnabled'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'ultimate-power'; Name = 'Ultimate Performance power plan [opt-in]'
                Detail = 'powercfg /setactive e9a42b02-d5df-448d-aa00-03f14749eb61, falling back to powercfg /duplicatescheme when the template is not present (both commands are documented by Microsoft; the GUID itself is widely used but not in the Microsoft powercfg table). The previous active plan GUID is recorded first and restored on undo. This runs AFTER the High performance plan, so ticking both leaves you on Ultimate.'
                Reboot = $false; Default = $false
                Actions = @(
                    @{ Type = 'Script'; Run = {
                        $up = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
                        $guid = '([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})'
                        $prev = & powercfg /getactivescheme 2>&1 | Out-String
                        if ($prev -match $guid) {
                            [void]$script:V11State.Add([pscustomobject][ordered]@{ Kind = 'PowerPlan'; Guid = $Matches[1] })
                        }
                        $out = & powercfg /setactive $up 2>&1 | Out-String
                        if ($LASTEXITCODE -ne 0) {
                            $dup = & powercfg /duplicatescheme $up 2>&1 | Out-String
                            if ($dup -match $guid) {
                                $new = $Matches[1]
                                $out2 = & powercfg /setactive $new 2>&1 | Out-String
                                if ($LASTEXITCODE -ne 0) { throw "powercfg /setactive failed: $out2" }
                                [void]$script:V11Notes.Add("Ultimate Performance scheme was created as $new and activated.")
                            } else {
                                throw "Ultimate Performance plan is not available on this machine and could not be created: $dup"
                            }
                        }
                    } }
                )
            },
            [pscustomobject]@{
                Id = 'core-parking'; Name = 'Core parking off while plugged in [opt-in]'
                Detail = 'powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR CPMINCORES 100 - Microsoft documents CPMinCores=100 as "keep 100% of logical processors unparked", i.e. the parking algorithm is disabled. Aliases are looked up first with powercfg /query, so a machine that does not expose the setting is left alone. Trade-off: higher idle power and more heat; Microsoft does not recommend it for gaming.'
                Reboot = $false; Default = $false
                Actions = @(
                    @{ Type = 'Script'; Run = {
                        Set-V11PowerSetting -Sub 'SUB_PROCESSOR' -Setting 'CPMINCORES' -AcIndex 100
                        [void]$script:V11Notes.Add('Core parking disabled on AC power (higher idle power/heat - undo if you do not want that).')
                    } }
                )
            },
            [pscustomobject]@{
                Id = 'no-toast'; Name = 'Toast notifications off [opt-in]'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications NoToastApplicationNotification = 1. Microsoft documents this as the "Turn off toast notifications" policy (ADMX_WPN, Windows 11 21H2+) written in its standard DWORD enable form. No popups during a match - but no app popups at all, including download-complete and chat alerts. Taskbar balloons are not covered by this policy.'
                Reboot = $false; Default = $false
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'NoToastApplicationNotification'; RegType = 'DWord'; Data = 1 }
                )
            },
            [pscustomobject]@{
                Id = 'gamedvr-policy'; Name = 'Game recording/broadcast policy off [opt-in]'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR AllowGameDVR = 0 (DWORD). Microsoft documents the policy as "Enables or disables Windows Game Recording and Broadcasting" but notes it is only enforced on Windows 10 for desktop - on Windows 11 the per-user GameDVR switch (ticked by default in Gaming) is the reliable one. Use this only if you want the policy set as well.'
                Reboot = $false; Default = $false
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name = 'AllowGameDVR'; RegType = 'DWord'; Data = 0 }
                )
            },
            [pscustomobject]@{
                Id = 'mouse-midpoint'; Name = 'Mouse sensitivity back to Windows midpoint [opt-in]'
                Detail = 'HKCU\Control Panel\Mouse MouseSensitivity = "10" (REG_SZ), the neutral midpoint of the Windows 1-20 slider. Third-party folklore rather than a Microsoft-documented value, and it only affects the Windows pointer path - games using raw input ignore it. Tick this if your pointer feels off, leave it off if you tuned sensitivity yourself.'
                Reboot = $false; Default = $false
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKCU'; Key = 'Control Panel\Mouse'; Name = 'MouseSensitivity'; RegType = 'String'; Data = '10' }
                )
            }
        )
    }

    # =========================================================== WINDOWS UPDATE
    $update = [pscustomobject]@{
        Id      = 'updates'
        Name    = 'Windows Update'
        Desc     = 'No surprise restarts, 35-day pause.'
        Enabled = $true
        Tweaks  = @(
            [pscustomobject]@{
                Id = 'no-auto-reboot'; Name = 'No auto-restart while signed in'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU NoAutoRebootWithLoggedOnUsers = 1 (DWORD). Documented legacy policy; a user-scheduled restart can still override it.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoRebootWithLoggedOnUsers'; RegType = 'DWord'; Data = 1 }
                )
            },
            [pscustomobject]@{
                Id = 'pause-updates'; Name = 'Pause updates for 35 days'
                Detail = 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings -> PauseUpdatesExpiryTime = now+35d, PauseFeatureUpdatesStartTime = PauseQualityUpdatesStartTime = now (REG_SZ, ISO 8601). These are the values the Settings app writes; they are NOT a documented policy API, so confirm the pause in Settings > Windows Update after applying.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Script'; Run = {
                        $key = 'SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
                        $now = [datetime]::UtcNow
                        Set-V11RegValue -Hive 'HKLM' -Key $key -Name 'PauseUpdatesExpiryTime'      -RegType 'String' -Data $now.AddDays(35).ToString('yyyy-MM-ddTHH:mm:ssZ')
                        Set-V11RegValue -Hive 'HKLM' -Key $key -Name 'PauseFeatureUpdatesStartTime' -RegType 'String' -Data $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
                        Set-V11RegValue -Hive 'HKLM' -Key $key -Name 'PauseQualityUpdatesStartTime' -RegType 'String' -Data $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
                    } }
                )
            },
            [pscustomobject]@{
                Id = 'au-notify'; Name = 'Updates: notify before download'
                Detail = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU AUOptions = 2 (DWORD). Microsoft documents 2 as "notify when updates are ready to download" - Windows Update still finds and reports updates, it just waits for you. Not the same as hiding updates.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Reg'; Hive = 'HKLM'; Key = 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'AUOptions'; RegType = 'DWord'; Data = 2 }
                )
            }
        )
    }

    # =========================================================== BLOATWARE
    $bloat = [pscustomobject]@{
        Id      = 'bloatware'
        Name    = 'Bloatware'
        Desc     = 'Remove preinstalled apps for this account and from new accounts.'
        Enabled = $true
        Tweaks  = @(
            [pscustomobject]@{
                Id = 'remove-apps'; Name = 'Remove preinstalled apps'
                Detail = 'Removes for the current user and from provisioning (new accounts): Cortana, News, Weather, Get Help, Get Started, Solitaire, Office hub, People, Maps, Feedback Hub, Phone Link, Clipchamp, Media Player, Films & TV, 3D Viewer, Sound Recorder, Alarms, Teams and new Outlook. Every name is queried first, so anything not installed is skipped. Microsoft Store, Xbox/Game Bar, DesktopAppInstaller and frameworks are never touched.'
                Reboot = $false; Default = $true
                Actions = @(
                    @{ Type = 'Script'; Run = {
                        $targets = @(
                            'Microsoft.549981C3F5F10', 'Microsoft.BingNews', 'Microsoft.BingWeather',
                            'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.MicrosoftSolitaireCollection',
                            'Microsoft.MicrosoftOfficeHub', 'Microsoft.People', 'Microsoft.WindowsMaps',
                            'Microsoft.WindowsFeedbackHub', 'Microsoft.YourPhone', 'Clipchamp.Clipchamp',
                            'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'Microsoft.SkypeApp', 'Microsoft.OneConnect',
                            'Microsoft.Microsoft3DViewer', 'Microsoft.WindowsSoundRecorder', 'Microsoft.WindowsAlarms',
                            'MicrosoftTeams', 'MSTeams', 'Microsoft.OutlookForWindows'
                        )
                        $removed = @()
                        foreach ($n in $targets) {
                            $pkgs = @(Get-AppxPackage -Name $n -ErrorAction SilentlyContinue)
                            foreach ($p in $pkgs) {
                                try {
                                    Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
                                    [void]$script:V11State.Add([pscustomobject][ordered]@{ Kind = 'Appx'; Name = $p.Name; PackageFullName = $p.PackageFullName })
                                    $removed += $p.Name
                                } catch {
                                    Write-V11 ("  ! {0}: {1}" -f $p.Name, $_.Exception.Message) 'DarkYellow'
                                }
                            }
                        }
                        $provRemoved = 0
                        foreach ($n in $targets) {
                            $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $n })
                            foreach ($p in $prov) {
                                try {
                                    Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
                                    [void]$script:V11State.Add([pscustomobject][ordered]@{ Kind = 'AppxProvisioned'; Name = $p.DisplayName; PackageName = $p.PackageName })
                                    $provRemoved++
                                } catch {
                                    Write-V11 ("  ! provisioning {0}: {1}" -f $p.DisplayName, $_.Exception.Message) 'DarkYellow'
                                }
                            }
                        }
                        if ($removed.Count) { [void]$script:V11Notes.Add(('Removed for this account: {0}' -f ($removed -join ', '))) }
                        if ($provRemoved)   { [void]$script:V11Notes.Add("Removed from provisioning for new accounts: $provRemoved package(s).") }
                        if (-not $removed.Count -and -not $provRemoved) { [void]$script:V11Notes.Add('No listed preinstalled apps were present.') }
                    } }
                )
            },
            [pscustomobject]@{
                Id = 'onedrive'; Name = 'Uninstall OneDrive [opt-in]'
                Detail = 'Runs OneDriveSetup.exe /uninstall from System32 or SysWOW64 when present (the /uninstall switch is documented by Microsoft; the path is installation-dependent). NOT auto-reversible: WinTune records that it ran, and you reinstall from onedrive.com or the Microsoft Store if you want it back. Left off by default.'
                Reboot = $false; Default = $false
                Actions = @(
                    @{ Type = 'Script'; Run = {
                        $candidates = @( (Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'), (Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe') )
                        $setup = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                        if (-not $setup) {
                            Write-V11 '  ! OneDriveSetup.exe not found - skipped' 'DarkYellow'
                        } else {
                            [void]$script:V11State.Add([pscustomobject][ordered]@{ Kind = 'OneDrive'; Path = $setup })
                            & $setup /uninstall 2>&1 | Out-Null
                            [void]$script:V11Notes.Add('OneDrive uninstaller started - it cannot be auto-reverted; reinstall from onedrive.com if needed.')
                        }
                    } }
                )
            }
        )
    }

    foreach ($grp in @($privacy, $search, $content, $gaming, $perf, $responsiveness, $gamer, $net, $update, $bloat)) {
        foreach ($t in $grp.Tweaks) {
            # Enabled is the live selection state; Default is the shipped preset.
            $t | Add-Member -NotePropertyName Enabled -NotePropertyValue ([bool]$t.Default) -Force
        }
        [void]$g.Add($grp)
    }
    return $g
}

# ------------------------------------------------------------------- snapshot
function New-V11SnapshotDir {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $script:V11SnapDir $stamp
    $i = 1
    while (Test-Path -LiteralPath $dir) { $dir = Join-Path $script:V11SnapDir ('{0}-{1}' -f $stamp, $i); $i++ }
    New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    return $dir
}

function Save-V11State {
    param([string]$Dir)
    $path = Join-Path $Dir 'state.json'
    ($script:V11State | ConvertTo-Json -Depth 6) | Set-Content -Path $path -Encoding UTF8
}

function Export-V11RegKeys {
    param([string]$Dir)
    $seen = @{}
    foreach ($e in $script:V11State) {
        if ($e.Kind -ne 'RegValue') { continue }
        $full = Get-V11RegFull -Hive $e.Hive -Key $e.Key
        if ($seen.ContainsKey($full)) { continue }
        $seen[$full] = $true
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $native = $full -replace ':', ''          # reg.exe wants HKLM\SOFTWARE\..., not HKLM:\SOFTWARE\...
        $safe   = ($native -replace '[^0-9a-zA-Z]+', '_')
        $file   = Join-Path $Dir ('reg_{0}.reg' -f $safe.Substring(0, [Math]::Min(60, $safe.Length)))
        & reg.exe export $native $file /y 2>&1 | Out-Null
    }
}

function Get-V11Snapshots {
    if (-not (Test-Path -LiteralPath $script:V11SnapDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:V11SnapDir -Directory |
             Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'state.json') } |
             Sort-Object Name -Descending)
}

function Restore-V11Snapshot {
    param([string]$Dir)

    $statePath = Join-Path $Dir 'state.json'
    if (-not (Test-Path -LiteralPath $statePath)) {
        Write-V11 "No state.json in $Dir" 'Red'
        return $false
    }
    $parsed = Get-Content -Path $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries = @()
    if ($null -ne $parsed) { $entries = @($parsed) }
    if ($entries.Count -eq 0) { Write-V11 'Snapshot is empty - nothing to revert.' 'Yellow'; return $true }

    Write-V11 ("Restoring {0} recorded change(s) from {1}" -f $entries.Count, $Dir) 'Cyan'
    $failed = 0

    # reverse order: last change first
    for ($i = $entries.Count - 1; $i -ge 0; $i--) {
        $e = $entries[$i]
        try {
            switch ($e.Kind) {
                'RegValue' {
                    $full = Get-V11RegFull -Hive $e.Hive -Key $e.Key
                    if (-not $e.Existed) {
                        if (Test-Path -LiteralPath $full) {
                            Remove-ItemProperty -LiteralPath $full -Name $e.Name -ErrorAction Stop
                        }
                    } else {
                        if (-not (Test-Path -LiteralPath $full)) { New-V11RegKey -Full $full }
                        $type = if ([string]::IsNullOrEmpty($e.Type)) { 'String' } else { [string]$e.Type }
                        $val  = ConvertFrom-V11RegData -RegType $type -Data $e.Data
                        New-ItemProperty -LiteralPath $full -Name $e.Name -Value $val -PropertyType $type -Force -ErrorAction Stop | Out-Null
                    }
                    Write-V11 ("  restored {0}\{1} [{2}]" -f $e.Hive, $e.Key, $e.Name) 'DarkGray'
                }
                'Service' {
                    $st = switch ($e.StartType) { 'Auto' { 'Automatic' } 'Manual' { 'Manual' } 'Disabled' { 'Disabled' } default { [string]$e.StartType } }
                    Set-Service -Name $e.Name -StartupType $st -ErrorAction Stop
                    if ($e.State -eq 'Running') { try { Start-Service -Name $e.Name -ErrorAction Stop } catch { } }
                    Write-V11 ("  restored service {0} ({1}/{2})" -f $e.Name, $st, $e.State) 'DarkGray'
                }
                'PowerPlan' {
                    & powercfg /setactive $e.Guid 2>&1 | Out-Null
                    Write-V11 ("  restored power plan {0}" -f $e.Guid) 'DarkGray'
                }
                'Hibernate' {
                    if ($e.Existed) { & powercfg /hibernate on 2>&1 | Out-Null; Write-V11 '  re-enabled hibernation / Fast Startup' 'DarkGray' }
                    else { Write-V11 '  hibernation was already off - left off' 'DarkGray' }
                }
                'ScheduledTask' {
                    if ($e.State -eq 'Disabled') {
                        Disable-ScheduledTask -TaskPath $e.TaskPath -TaskName $e.TaskName -ErrorAction Stop | Out-Null
                    } else {
                        Enable-ScheduledTask -TaskPath $e.TaskPath -TaskName $e.TaskName -ErrorAction Stop | Out-Null
                    }
                    Write-V11 ("  restored scheduled task {0}{1}" -f $e.TaskPath, $e.TaskName) 'DarkGray'
                }
                'PowerSetting' {
                    & powercfg /setacvalueindex SCHEME_CURRENT $e.Sub $e.Setting $e.Ac 2>&1 | Out-Null
                    if ($null -ne $e.Dc) { & powercfg /setdcvalueindex SCHEME_CURRENT $e.Sub $e.Setting $e.Dc 2>&1 | Out-Null }
                    & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
                    Write-V11 ("  restored power setting {0} to 0x{1}" -f $e.Setting, $e.Ac) 'DarkGray'
                }
                'Trim' {
                    & fsutil behavior set DisableDeleteNotify $e.Value 2>&1 | Out-Null
                    Write-V11 ("  restored DisableDeleteNotify = {0}" -f $e.Value) 'DarkGray'
                }
                'OneDrive' {
                    Write-V11 ("  OneDrive cannot be restored automatically - reinstall from onedrive.com ({0})" -f $e.Path) 'DarkYellow'
                }
                { $_ -in 'Appx', 'AppxProvisioned' } {
                    Write-V11 ("  cannot restore {0} automatically - reinstall it from the Microsoft Store or winget" -f $e.Name) 'DarkYellow'
                }
                default {
                    Write-V11 ("  ! unknown snapshot entry kind '{0}'" -f $e.Kind) 'DarkYellow'
                }
            }
        } catch {
            $failed++
            Write-V11 ("  ! failed to revert {0}: {1}" -f $e.Kind, $_.Exception.Message) 'Red'
        }
    }

    if ($failed -eq 0) { Write-V11 'Revert complete.' 'Green'; return $true }
    Write-V11 "Revert finished with $failed failure(s)." 'Yellow'
    return $false
}

# ---------------------------------------------------------------- apply engine
function Invoke-V11Action {
    param($Action)
    switch ($Action.Type) {
        'Reg' {
            Set-V11RegValue -Hive $Action.Hive -Key $Action.Key -Name $Action.Name -RegType $Action.RegType -Data $Action.Data
        }
        'Service' {
            $stop = $false
            if ($Action.ContainsKey('Stop')) { $stop = [bool]$Action.Stop }
            Set-V11Service -Name $Action.Name -StartType $Action.StartType -Stop:$stop
        }
        'Script' {
            & $Action.Run
        }
        default { throw "Unknown action type '$($Action.Type)'" }
    }
}

function Invoke-V11Apply {
    param($Groups, [string]$SnapshotDir)

    # ---- snapshot folder first: if it is not writable (read-only USB stick,
    # ---- write-protect switch), abort before anything at all is changed.
    $dir = $SnapshotDir
    try {
        if (-not $dir) { $dir = New-V11SnapshotDir }
        else { New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
    } catch {
        Write-V11 ("Could not create the snapshot folder: {0}" -f $_.Exception.Message) 'Red'
        Write-V11 'Nothing was changed. Move this folder somewhere writable, or clear the USB write-protect switch.' 'Yellow'
        return $false
    }
    $probe = Join-Path $dir 'write-probe.tmp'
    try {
        Set-Content -Path $probe -Value 'probe' -Encoding UTF8 -ErrorAction Stop
        Remove-Item -Path $probe -Force -ErrorAction Stop
    } catch {
        Write-V11 ("Cannot write to {0}: {1}" -f $dir, $_.Exception.Message) 'Red'
        Write-V11 'Nothing was changed. Move this folder somewhere writable, or clear the USB write-protect switch.' 'Yellow'
        return $false
    }

    $script:V11LogPath = Join-Path $dir 'changes.log'
    Write-V11 "Snapshot directory: $dir" 'Cyan'
    Save-V11State -Dir $dir

    $ok = 0; $fail = 0
    $script:V11Reboot.Clear()
    $script:V11Notes.Clear()

    foreach ($grp in $Groups) {
        foreach ($t in $grp.Tweaks) {
            if (-not $t.Enabled) { continue }
            Write-V11 ("[{0}] {1}" -f $grp.Name, $t.Name) 'White'
            try {
                foreach ($a in $t.Actions) { Invoke-V11Action -Action $a }
                if ($t.Reboot -and -not ($script:V11Reboot -contains $t.Name)) { [void]$script:V11Reboot.Add($t.Name) }
                $ok++
                Save-V11State -Dir $dir
            } catch {
                $fail++
                Write-V11 ("    FAILED: {0}" -f $_.Exception.Message) 'Red'
                Save-V11State -Dir $dir
            }
        }
    }

    Export-V11RegKeys -Dir $dir
    Save-V11State -Dir $dir

    Write-V11Rule
    Write-V11 ("Applied {0} tweak(s), {1} failure(s)." -f $ok, $fail) 'Green'
    foreach ($n in $script:V11Notes) { Write-V11 ("  note: $n") 'DarkCyan' }
    if ($script:V11Reboot.Count) {
        Write-V11 'Reboot or sign out needed for:' 'Yellow'
        foreach ($r in $script:V11Reboot) { Write-V11 ("    - $r") 'Yellow' }
    }
    Write-V11 "Snapshot kept at: $dir" 'Cyan'
    Write-V11 ("Revert with:  {0} -Revert -Snapshot `"{1}`"" -f $PSCommandPath, $dir) 'DarkGray'
    $script:V11LogPath = $null
    return ($fail -eq 0)
}

# -------------------------------------------------------------------- review
function Show-V11Review {
    param($Groups)
    Write-V11Rule
    Write-V11 ' REVIEW - what will be changed' 'Cyan'
    Write-V11Rule
    $count = 0
    foreach ($grp in $Groups) {
        if (-not $grp.Enabled) {
            Write-V11 ("  [{0}] {1} - skipped (group off)" -f $grp.Id, $grp.Name) 'DarkGray'
            continue
        }
        Write-V11 ("[{0}] {1} - {2}" -f $grp.Name, $grp.Id, $grp.Desc) 'White'
        foreach ($t in $grp.Tweaks) {
            if (-not $t.Enabled) {
                Write-V11 ("    {0,-45} off" -f $t.Name) 'DarkGray'
                continue
            }
            $count++
            $flag = if ($t.Default) { 'apply' } else { 'opt-in, selected' }
            Write-V11 ("    {0,-45} {1}" -f $t.Name, $flag) 'Gray'
        }
    }
    Write-V11Rule
    Write-V11 ("{0} tweak(s) will be applied. A snapshot is written first." -f $count) 'Cyan'
    return $count
}

function Show-V11Details {
    param($Groups)
    foreach ($grp in $Groups) {
        Write-V11Rule
        Write-V11 ("{0}  ({1})" -f $grp.Name.ToUpper(), $grp.Id) 'Cyan'
        foreach ($t in $grp.Tweaks) {
            Write-V11 ("  * {0}" -f $t.Name) 'White'
            Write-V11 ("      {0}" -f $t.Detail) 'DarkGray'
        }
    }
    Write-V11Rule
}

# ---------------------------------------------------------------------- menu
function Show-V11Menu {
    param($Groups, $Status)
    Clear-Host
    Write-V11Rule
    Write-V11 '  WINTUNE - Windows 11 privacy + gaming performance' 'Cyan'
    $os = $null
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }
    if ($os) { Write-V11 ("  {0}  (build {1})" -f $os.Caption, $os.BuildNumber) 'DarkGray' }
    Write-V11 ("  elevated: {0}    snapshots: {1}" -f $(if (Get-V11IsAdmin) { 'yes' } else { 'NO - required to apply' }), $script:V11SnapDir) 'DarkGray'
    if ($Status) { Write-V11 ("  {0}" -f $Status) 'Green' }
    Write-V11Rule
    for ($i = 0; $i -lt $Groups.Count; $i++) {
        $g = $Groups[$i]
        $n = @($g.Tweaks).Count
        $on = @($g.Tweaks | Where-Object { $_.Enabled }).Count
        $state = if ($g.Enabled) { 'ON ' } else { 'OFF' }
        $color = if ($g.Enabled) { 'Green' } else { 'DarkGray' }
        Write-V11 ("  [{0}] {1,-4} {2,-20} {3}/{4} tweaks" -f ($i + 1), $state, $g.Name, $on, $n) $color
    }
    Write-V11Rule
    Write-V11 ('  [Enter] refresh   [1-{0}] toggle group   [e] edit group tweaks   [d] details' -f $Groups.Count) 'Yellow'
    Write-V11 '  [a] apply   [r] revert last snapshot   [q] quit' 'Yellow'
    Write-Host '> ' -ForegroundColor DarkCyan
}

function Invoke-V11EditTweaks {
    param($Groups)
    while ($true) {
        Write-V11Rule
        Write-V11 ' Which group? (number, or Enter to go back)' 'Cyan'
        for ($i = 0; $i -lt $Groups.Count; $i++) {
            Write-V11 ("  [{0}] {1}" -f ($i + 1), $Groups[$i].Name) 'White'
        }
        $sel = (Read-Host).Trim().ToLower()
        if ($sel -eq '') { return }
        $n = 0
        if (-not [int]::TryParse($sel, [ref]$n) -or $n -lt 1 -or $n -gt $Groups.Count) {
            Write-V11 ' Invalid choice.' 'Red'; Start-Sleep -Seconds 1; continue
        }
        $grp = $Groups[$n - 1]
        while ($true) {
            Write-V11Rule
            Write-V11 (" {0} - number toggles a tweak, b = back" -f $grp.Name.ToUpper()) 'Cyan'
            $list = @($grp.Tweaks)
            for ($i = 0; $i -lt $list.Count; $i++) {
                $t = $list[$i]
                $mark = if ($t.Enabled) { '[x]' } else { '[ ]' }
                $color = if ($t.Enabled) { 'Green' } else { 'DarkGray' }
                $hint = if ($t.Default) { '' } else { '  (opt-in)' }
                Write-V11 ("  {0} {1,2}. {2}{3}" -f $mark, ($i + 1), $t.Name, $hint) $color
            }
            $key = (Read-Host).Trim().ToLower()
            if ($key -eq 'b' -or $key -eq '') { break }
            $i = 0
            if ([int]::TryParse($key, [ref]$i) -and $i -ge 1 -and $i -le $list.Count) {
                $list[$i - 1].Enabled = -not $list[$i - 1].Enabled
            }
        }
        return
    }
}

function Invoke-V11Menu {
    $groups = Get-V11Tweaks
    $status = 'Ready. Nothing has been changed yet.'

    while ($true) {
        Show-V11Menu -Groups $groups -Status $status
        $key = Read-Host
        $k = "$key".Trim().ToLower()

        if ($k -eq 'q') { Write-V11 'Bye.' 'Cyan'; return }
        if ($k -eq 'e') { Invoke-V11EditTweaks -Groups $groups; $status = 'Tweak selection updated.'; continue }
        if ($k -eq 'd') {
            Show-V11Details -Groups $groups
            Write-Host 'Press Enter to return... ' -ForegroundColor DarkGray
            [void](Read-Host)
            continue
        }
        if ($k -match '^[0-9]+$') {
            $idx = [int]$k - 1
            if ($idx -ge 0 -and $idx -lt $groups.Count) {
                $groups[$idx].Enabled = -not $groups[$idx].Enabled
                $status = ("Group '{0}' is now {1}." -f $groups[$idx].Name, $(if ($groups[$idx].Enabled) { 'ON' } else { 'OFF' }))
            }
            continue
        }
        if ($k -eq 'a') {
            $selected = @($groups | Where-Object { $_.Enabled })
            if (-not $selected.Count) { $status = 'No groups enabled.'; continue }
            $count = Show-V11Review -Groups $selected
            if ($count -eq 0) { $status = 'Nothing to apply.'; Start-Sleep -Seconds 2; continue }

            if (-not (Get-V11IsAdmin)) {
                Write-Host 'Apply requires administrator rights. Continue? [Y/n] ' -ForegroundColor Yellow
                $ans = (Read-Host).Trim().ToLower()
                if ($ans -eq 'n') { $status = 'Apply cancelled (not elevated).'; continue }
                # Relaunch the menu elevated rather than -Apply, so the group
                # selection you made here is not silently replaced by apply-all.
                $arg = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Menu' -f $PSCommandPath
                if (Request-V11Elevation -ArgumentString $arg) { return }
                $status = 'Elevation failed.'; continue
            }

            Write-Host 'Apply these changes now? [y/N] ' -ForegroundColor Yellow
            $ans = (Read-Host).Trim().ToLower()
            if ($ans -ne 'y' -and $ans -ne 'yes') { $status = 'Apply cancelled.'; continue }

            $dir = New-V11SnapshotDir
            $good = Invoke-V11Apply -Groups $selected -SnapshotDir $dir
            $status = if ($good) { "Applied. Snapshot: $dir" } else { "Applied with failures - see $dir\changes.log" }
            continue
        }
        if ($k -eq 'r') {
            $snaps = @(Get-V11Snapshots)
            if (-not $snaps.Count) { $status = 'No snapshots found.'; Start-Sleep -Seconds 2; continue }

            Write-V11Rule
            Write-V11 ' Snapshots (newest first)' 'Cyan'
            for ($i = 0; $i -lt $snaps.Count -and $i -lt 10; $i++) {
                Write-V11 ("  [{0}] {1}" -f ($i + 1), $snaps[$i].Name) 'White'
            }
            Write-V11 '  [Enter] newest   [q] cancel' 'DarkGray'
            $sel = (Read-Host).Trim().ToLower()
            if ($sel -eq 'q') { $status = 'Revert cancelled.'; continue }
            $target = if ($sel -eq '') { $snaps[0].FullName } else {
                $n = 0
                if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $snaps.Count) { $snaps[$n - 1].FullName } else { $null }
            }
            if (-not $target) { $status = 'Invalid selection.'; Start-Sleep -Seconds 2; continue }

            if (-not (Get-V11IsAdmin)) {
                Write-Host 'Revert requires administrator rights. Continue? [Y/n] ' -ForegroundColor Yellow
                $ans = (Read-Host).Trim().ToLower()
                if ($ans -eq 'n') { $status = 'Revert cancelled (not elevated).'; continue }
                $arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Revert -Snapshot "{1}" -Yes' -f $PSCommandPath, $target
                if (Request-V11Elevation -ArgumentString $arg) { return }
                $status = 'Elevation failed.'; continue
            }

            Write-Host ("Restore snapshot {0}? [y/N] " -f (Split-Path $target -Leaf)) -ForegroundColor Yellow
            $ans = (Read-Host).Trim().ToLower()
            if ($ans -ne 'y' -and $ans -ne 'yes') { $status = 'Revert cancelled.'; continue }

            $script:V11LogPath = Join-Path $target 'revert.log'
            $good = Restore-V11Snapshot -Dir $target
            $script:V11LogPath = $null
            $status = if ($good) { "Reverted from $target" } else { "Revert finished with problems - see $target\revert.log" }
            continue
        }
        $status = 'Ready.'
    }
}

# ----------------------------------------------------------------------- GUI
# Chris Titus-style window: grouped checkboxes on the left, activity log on the
# right, Run Tweaks / Undo Tweaks / Create Restore Point on top. The window is
# built from the SAME tweak catalogue and reuses the same snapshot engine as the
# console menu - there is no second copy of any tweak anywhere.



function Initialize-V11GuiAssembly {
    # WPF assemblies are not loaded until something asks for them.
    if ('System.Windows.Window' -as [type]) { return }
    foreach ($asm in @('PresentationFramework', 'PresentationCore', 'WindowsBase')) {
        Add-Type -AssemblyName $asm -ErrorAction Stop
    }
}

function Get-V11GuiXaml {
    return @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Velocity11 - Windows 11 privacy + gaming performance"
        Width="1180" Height="830" MinWidth="980" MinHeight="660"
        WindowStartupLocation="CenterScreen"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        Background="#FF0B0B11"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
        Foreground="#FFEFEFF7">
  <Window.Resources>

    <SolidColorBrush x:Key="Surface"     Color="#FF101018"/>
    <SolidColorBrush x:Key="Card"        Color="#FF14141E"/>
    <SolidColorBrush x:Key="CardBorder"  Color="#FF242432"/>
    <SolidColorBrush x:Key="Accent"      Color="#FF7C5CFF"/>
    <SolidColorBrush x:Key="AccentDim"   Color="#FF2B2350"/>
    <SolidColorBrush x:Key="Text"        Color="#FFEFEFF7"/>
    <SolidColorBrush x:Key="Muted"       Color="#FF8A8A9E"/>
    <SolidColorBrush x:Key="Field"       Color="#FF171722"/>

    <!-- pill button template: rounded, hover fade, press fade -->
    <ControlTemplate x:Key="PillButton" TargetType="Button">
      <Border x:Name="Bd" Background="{TemplateBinding Background}"
              BorderBrush="{TemplateBinding BorderBrush}"
              BorderThickness="{TemplateBinding BorderThickness}"
              CornerRadius="9" Padding="{TemplateBinding Padding}">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter TargetName="Bd" Property="Opacity" Value="0.86"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter TargetName="Bd" Property="Opacity" Value="0.68"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter TargetName="Bd" Property="Opacity" Value="0.45"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>

    <Style x:Key="AccentButton" TargetType="Button">
      <Setter Property="Template"   Value="{StaticResource PillButton}"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize"   Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding"    Value="24,10"/>
      <Setter Property="Margin"     Value="6,0,0,0"/>
      <Setter Property="Cursor"     Value="Hand"/>
    </Style>

    <Style x:Key="GhostButton" TargetType="Button">
      <Setter Property="Template"   Value="{StaticResource PillButton}"/>
      <Setter Property="Background" Value="{StaticResource Card}"/>
      <Setter Property="BorderBrush" Value="{StaticResource CardBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontSize"   Value="14"/>
      <Setter Property="Padding"    Value="18,10"/>
      <Setter Property="Margin"     Value="6,0,0,0"/>
      <Setter Property="Cursor"     Value="Hand"/>
    </Style>

    <!-- rounded checkbox: 18px tile that fills with the accent colour when ticked -->
    <ControlTemplate x:Key="TileCheck" TargetType="CheckBox">
      <Grid Background="Transparent">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
          <Border x:Name="Box" Width="18" Height="18" CornerRadius="6"
                  Background="#FF1B1B27" BorderBrush="#FF33334A" BorderThickness="1.5"
                  VerticalAlignment="Center">
            <Path x:Name="Tick" Data="M 3.5,9 L 7,12.5 L 14.5,4.5"
                  Stroke="White" StrokeThickness="2" Stretch="None"
                  StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                  Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ContentPresenter Margin="11,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="False"/>
        </StackPanel>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
          <Setter TargetName="Box" Property="Background" Value="{StaticResource AccentDim}"/>
        </Trigger>
        <Trigger Property="IsChecked" Value="True">
          <Setter TargetName="Box" Property="Background" Value="{StaticResource Accent}"/>
          <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
          <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Opacity" Value="0.5"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>

    <Style x:Key="Check" TargetType="CheckBox">
      <Setter Property="Template"  Value="{StaticResource TileCheck}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontSize"  Value="13"/>
      <Setter Property="Margin"    Value="0,5,0,5"/>
      <Setter Property="Cursor"    Value="Hand"/>
    </Style>

    <Style x:Key="GroupTitle" TargetType="TextBlock">
      <Setter Property="FontSize"   Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
    </Style>

    <!-- slim dark scrollbar: the stock light one clashes with the theme -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="9"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Margin" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="#FF3C3C52" CornerRadius="4" Margin="2,1"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

  </Window.Resources>

  <DockPanel>

    <!-- ============================ header ============================ -->
    <Border DockPanel.Dock="Top" Background="{StaticResource Surface}" Padding="20,14,20,14" BorderBrush="{StaticResource CardBorder}" BorderThickness="0,0,0,1">
      <DockPanel LastChildFill="False">
        <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="36" Height="36" CornerRadius="11" Background="{StaticResource AccentDim}" Margin="0,0,13,0">
            <TextBlock Text="V11" Foreground="{StaticResource Accent}" FontWeight="Bold" FontSize="12"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="Velocity11" FontSize="19" FontWeight="Bold" Foreground="{StaticResource Text}"/>
            <TextBlock Text="Windows 11 privacy + gaming performance" FontSize="12" Foreground="{StaticResource Muted}"/>
          </StackPanel>
        </StackPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Border Background="{StaticResource Field}" CornerRadius="9"
                  BorderBrush="{StaticResource CardBorder}" BorderThickness="1" Padding="12,7" Margin="6,0,10,0"
                  VerticalAlignment="Center">
            <Grid>
              <TextBlock x:Name="FilterHint" Text="Filter tweaks..." Foreground="#FF6C6C80"
                         VerticalAlignment="Center" IsHitTestVisible="False"/>
              <TextBox x:Name="FilterBox" Background="Transparent" BorderThickness="0" Padding="0"
                       Width="150" Foreground="{StaticResource Text}" CaretBrush="{StaticResource Text}"
                       VerticalAlignment="Center" FontSize="13"/>
            </Grid>
          </Border>
          <Button x:Name="RestorePointButton" Content="Create Restore Point" Style="{StaticResource GhostButton}"/>
          <Button x:Name="UndoButton"         Content="Undo Tweaks"          Style="{StaticResource GhostButton}"/>
          <Button x:Name="RunButton"          Content="Run Tweaks"           Style="{StaticResource AccentButton}"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- =========================== status bar ========================== -->
    <Border DockPanel.Dock="Bottom" Background="{StaticResource Surface}" Padding="20,10" BorderBrush="{StaticResource CardBorder}" BorderThickness="0,1,0,0">
      <StackPanel Orientation="Horizontal">
        <Border x:Name="StatusDot" Width="8" Height="8" CornerRadius="4" Background="#FF4ADE80" Margin="0,0,11,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="StatusLabel" Foreground="{StaticResource Muted}"
                   Text="Ready. Nothing has been changed yet." VerticalAlignment="Center"/>
      </StackPanel>
    </Border>

    <!-- ============================ content =========================== -->
    <Grid Margin="16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="5*"/>
        <ColumnDefinition Width="4*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="{StaticResource Card}" CornerRadius="14"
              BorderBrush="{StaticResource CardBorder}" BorderThickness="1" Padding="14,14,10,6">
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="SectionHost" Margin="4,0,4,8"/>
        </ScrollViewer>
      </Border>

      <Border Grid.Column="1" Background="{StaticResource Card}" CornerRadius="14"
              BorderBrush="{StaticResource CardBorder}" BorderThickness="1" Padding="14" Margin="12,0,0,0">
        <DockPanel>
          <DockPanel DockPanel.Dock="Top" Margin="2,2,2,10">
            <Border Width="7" Height="7" CornerRadius="3.5" Background="{StaticResource Accent}" Margin="0,0,9,0" VerticalAlignment="Center"/>
            <TextBlock Text="ACTIVITY LOG" FontWeight="SemiBold" Foreground="{StaticResource Muted}" FontSize="11" VerticalAlignment="Center"/>
          </DockPanel>
          <TextBox x:Name="LogBox" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                   Background="#FF0D0D14" Foreground="#FFC9C9DA" BorderThickness="0"
                   FontFamily="Cascadia Mono, Consolas" FontSize="12" Padding="8"/>
        </DockPanel>
      </Border>
    </Grid>

  </DockPanel>
</Window>
'@
}

function Add-V11GuiSections {
    param($Window, $Groups)

    $sectionHost = Get-V11GuiName -Window $Window -Name 'SectionHost'
    $sectionHost.Children.Clear()

    $cardBrush   = $Window.FindResource('Card')
    $cardBorder  = $Window.FindResource('CardBorder')
    $accent      = $Window.FindResource('Accent')
    $accentDim   = $Window.FindResource('AccentDim')
    $textBrush   = $Window.FindResource('Text')
    $muted       = $Window.FindResource('Muted')
    $fieldBrush  = $Window.FindResource('Field')
    $titleStyle  = $Window.FindResource('GroupTitle')
    $checkStyle  = $Window.FindResource('Check')

    $count = 0
    foreach ($g in $Groups) {
        $stack  = New-Object System.Windows.Controls.StackPanel
        $on     = @($g.Tweaks | Where-Object { $_.Enabled }).Count
        $total  = @($g.Tweaks).Count

        # ---- card header: accent dot + name + count pill -----------------
        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'

        $dot = New-Object System.Windows.Controls.Border
        $dot.Width = 8; $dot.Height = 8
        $dot.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $dot.Background = $accent
        $dot.Margin = [System.Windows.Thickness]::new(0, 7, 10, 0)
        [void]$head.Children.Add($dot)

        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = $g.Name
        $title.Style = $titleStyle
        [void]$head.Children.Add($title)

        $pill = New-Object System.Windows.Controls.Border
        $pill.Background = $accentDim
        $pill.CornerRadius = [System.Windows.CornerRadius]::new(9)
        $pill.Padding = [System.Windows.Thickness]::new(8, 2, 8, 2)
        $pill.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
        $pillText = New-Object System.Windows.Controls.TextBlock
        $pillText.Text = '{0}/{1}' -f $on, $total
        $pillText.Foreground = $Window.FindResource('Accent')
        $pillText.FontSize = 11
        $pillText.FontWeight = 'SemiBold'
        $pill.Child = $pillText
        [void]$head.Children.Add($pill)
        [void]$stack.Children.Add($head)

        # ---- group description ------------------------------------------
        $desc = New-Object System.Windows.Controls.TextBlock
        $desc.Text        = $g.Desc
        $desc.Foreground  = $muted
        $desc.FontSize    = 12
        $desc.TextWrapping = 'Wrap'
        $desc.Margin      = [System.Windows.Thickness]::new(18, 5, 0, 8)
        [void]$stack.Children.Add($desc)

        # ---- tweaks ------------------------------------------------------
        foreach ($t in $g.Tweaks) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content   = $t.Name
            $cb.IsChecked = [bool]$t.Enabled
            $cb.Tag       = $t
            $cb.ToolTip   = $t.Detail
            $cb.Style     = $checkStyle
            [void]$stack.Children.Add($cb)
            $count++
        }

        $card = New-Object System.Windows.Controls.Border
        $card.Background      = $cardBrush
        $card.BorderBrush     = $cardBorder
        $card.BorderThickness = [System.Windows.Thickness]::new(1)
        $card.CornerRadius    = [System.Windows.CornerRadius]::new(12)
        $card.Padding         = [System.Windows.Thickness]::new(16, 14, 16, 14)
        $card.Margin          = [System.Windows.Thickness]::new(0, 0, 0, 12)
        $card.Child           = $stack
        [void]$sectionHost.Children.Add($card)
    }

    return $count
}

function Update-V11GuiFilter {
    param($Window, [string]$Query)

    $sectionHost = Get-V11GuiName -Window $Window -Name 'SectionHost'
    $q = "$Query".Trim().ToLower()
    $empty = [string]::IsNullOrEmpty($q)

    foreach ($card in $sectionHost.Children) {
        if ($card -isnot [System.Windows.Controls.Border]) { continue }
        $cardVisible = $empty
        foreach ($el in $card.Child.Children) {
            if ($el -isnot [System.Windows.Controls.CheckBox]) { continue }
            if ($empty) {
                $el.Visibility = [System.Windows.Visibility]::Visible
                continue
            }
            $hit = ([string]$el.Content).ToLower().Contains($q)
            if (-not $hit -and $el.Tag -and $el.Tag.Detail) {
                $hit = ([string]$el.Tag.Detail).ToLower().Contains($q)
            }
            if ($hit) {
                $el.Visibility = [System.Windows.Visibility]::Visible
                $cardVisible = $true
            } else {
                $el.Visibility = [System.Windows.Visibility]::Collapsed
            }
        }
        $card.Visibility = if ($cardVisible) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    }
}

function Get-V11GuiName {
    param($Window, [string]$Name)
    $el = $Window.FindName($Name)
    if (-not $el -and $Window.Content) { $el = $Window.Content.FindName($Name) }
    if (-not $el) { throw "XAML control '$Name' was not found" }
    return $el
}

function New-V11GuiWindow {
    Initialize-V11GuiAssembly
    $win = [Windows.Markup.XamlReader]::Parse((Get-V11GuiXaml))
    foreach ($n in @('SectionHost', 'LogBox', 'StatusLabel', 'RunButton', 'UndoButton', 'RestorePointButton')) {
        $null = Get-V11GuiName -Window $win -Name $n
    }
    return $win
}



function Sync-V11GuiToModel {
    param($Window)
    $sectionHost = Get-V11GuiName -Window $Window -Name 'SectionHost'
    $count = 0
    foreach ($card in $sectionHost.Children) {
        if ($card -isnot [System.Windows.Controls.Border]) { continue }
        if (-not $card.Child) { continue }
        foreach ($el in $card.Child.Children) {
            if ($el -isnot [System.Windows.Controls.CheckBox]) { continue }
            if (-not $el.Tag) { continue }
            $el.Tag.Enabled = [bool]$el.IsChecked
            if ($el.Tag.Enabled) { $count++ }
        }
    }
    return $count
}

function Update-V11GuiLog {
    param($Box, [string]$Message)
    if (-not $Box) { return }
    $Box.AppendText(('[{0}] {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $Message, [Environment]::NewLine))
    $Box.ScrollToEnd()
    # pump the dispatcher so the pane repaints while a long apply is running
    $Box.Dispatcher.Invoke([action] { }, [System.Windows.Threading.DispatcherPriority]::Background)
}

function Show-V11GuiMessage {
    param([string]$Message, [string]$Title = 'Velocity11', [string]$Buttons = 'OK', [string]$Icon = 'Information')
    return [System.Windows.MessageBox]::Show($Message, $Title, $Buttons, $Icon)
}

function Invoke-V11GuiApply {
    param($Window, $Groups, $Status)
    if (-not (Get-V11IsAdmin)) {
        [void](Show-V11GuiMessage "Administrator rights are required to change anything.`n`nRight-click Velocity11.cmd and choose 'Run as administrator'." 'Administrator rights' 'OK' 'Warning')
        return $false
    }
    $count = Sync-V11GuiToModel -Window $Window
    if ($count -eq 0) {
        [void](Show-V11GuiMessage 'No tweaks are selected - tick something first.')
        return $false
    }
    $ans = Show-V11GuiMessage ("Apply $count tweak(s)?`n`nA snapshot of your current settings is written FIRST, so Undo Tweaks can put everything back.`n`nEverything the tool will change is listed in the activity log.") 'Run Tweaks' 'YesNo' 'Question'
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { $Status.Text = 'Apply cancelled.'; return $false }

    $dir = $null
    try { $dir = New-V11SnapshotDir }
    catch {
        [void](Show-V11GuiMessage ("Could not create the snapshot folder:`n$($_.Exception.Message)`n`nNothing was changed."))
        return $false
    }
    $Status.Text = 'Applying tweaks...'
    $ok = Invoke-V11Apply -Groups $Groups -SnapshotDir $dir
    $Status.Text = if ($ok) { "Applied. Snapshot: $dir" } else { "Finished with failures - see $dir\changes.log" }
    if ($ok -and $script:V11Reboot.Count) {
        [void](Show-V11GuiMessage ("Reboot or sign out for these to take effect:`n`n- " + ($script:V11Reboot -join "`n- ")) 'Reboot needed' 'OK' 'Information')
    }
    return $ok
}

function Invoke-V11GuiUndo {
    param($Window, $Status)
    if (-not (Get-V11IsAdmin)) {
        [void](Show-V11GuiMessage "Administrator rights are required to undo changes.`n`nRight-click Velocity11.cmd and choose 'Run as administrator'." 'Administrator rights' 'OK' 'Warning')
        return $false
    }
    $snaps = @(Get-V11Snapshots)
    if (-not $snaps.Count) {
        [void](Show-V11GuiMessage "No snapshots found - there is nothing to undo.`n`nNothing has ever been applied from this copy of Velocity11." 'Undo Tweaks')
        $Status.Text = 'No snapshots found.'
        return $false
    }
    $latest = $snaps[0]
    $ans = Show-V11GuiMessage ("Restore the snapshot from`n`n$($latest.Name)`n`nEvery value Velocity11 changed goes back to what it was before.") 'Undo Tweaks' 'YesNo' 'Question'
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { $Status.Text = 'Undo cancelled.'; return $false }

    $Status.Text = 'Restoring snapshot...'
    $ok = Restore-V11Snapshot -Dir $latest.FullName
    $Status.Text = if ($ok) { "Reverted from $($latest.Name)" } else { 'Revert finished with problems - see the log' }
    return $ok
}

function Invoke-V11GuiRestorePoint {
    param($Status)
    if (-not (Get-V11IsAdmin)) {
        [void](Show-V11GuiMessage "Administrator rights are required to create a restore point.`n`nRight-click Velocity11.cmd and choose 'Run as administrator'." 'Administrator rights' 'OK' 'Warning')
        return $false
    }
    $ans = Show-V11GuiMessage "Create a System Restore point now?`n`nThis is independent of the snapshot Velocity11 takes before applying." 'Create Restore Point' 'YesNo' 'Question'
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { $Status.Text = 'Restore point cancelled.'; return $false }
    $Status.Text = 'Creating restore point...'
    try {
        Checkpoint-Computer -Description ('Velocity11 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')) -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-V11 'System Restore point created.' 'Green'
        $Status.Text = 'Restore point created.'
        return $true
    } catch {
        Write-V11 ("Could not create a restore point: {0}" -f $_.Exception.Message) 'Red'
        $Status.Text = 'Restore point failed - see the log.'
        return $false
    }
}

function Invoke-V11Gui {
    $groups = Get-V11Tweaks
    $win    = New-V11GuiWindow
    $boxes  = Add-V11GuiSections -Window $win -Groups $groups
    $status = Get-V11GuiName -Window $win -Name 'StatusLabel'
    $dot    = Get-V11GuiName -Window $win -Name 'StatusDot'
    $filter = Get-V11GuiName -Window $win -Name 'FilterBox'
    $hint   = Get-V11GuiName -Window $win -Name 'FilterHint'
    $script:V11LogBox  = Get-V11GuiName -Window $win -Name 'LogBox'
    $script:V11LogSink = { param($msg, $color) Update-V11GuiLog -Box $script:V11LogBox -Message $msg }

    $admin = Get-V11IsAdmin
    $dot.Background = if ($admin) { [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF4ADE80') }
                      else        { [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFF59E0B') }
    $status.Text = if ($admin) { "Ready - running elevated. $boxes tweaks in $($groups.Count) sections." }
                   else        { 'Not elevated: Run Tweaks will ask you to restart as administrator.' }

    Write-V11 ("Velocity11 ready - {0} tweak(s) in {1} sections. Nothing has been changed yet." -f $boxes, $groups.Count) 'Gray'
    Write-V11 'Hover a checkbox for the exact registry path and value it writes; use the filter box to narrow the list.' 'DarkGray'

    $filter.Add_TextChanged({
        try {
            Update-V11GuiFilter -Window $win -Query $filter.Text
            $hint.Visibility = if ($filter.Text.Length -gt 0) { [System.Windows.Visibility]::Collapsed }
                               elseif ($filter.IsKeyboardFocused) { [System.Windows.Visibility]::Collapsed }
                               else { [System.Windows.Visibility]::Visible }
        } catch { }
    })
    $filter.Add_GotFocus({ $hint.Visibility = [System.Windows.Visibility]::Collapsed })
    $filter.Add_LostFocus({
        $hint.Visibility = if ($filter.Text.Length -eq 0) { [System.Windows.Visibility]::Visible }
                           else { [System.Windows.Visibility]::Collapsed }
    })

    (Get-V11GuiName -Window $win -Name 'RunButton').Add_Click({
        try { Invoke-V11GuiApply -Window $win -Groups $groups -Status $status }
        catch { Write-V11 ("FAILED: {0}" -f $_.Exception.Message) 'Red' }
    })
    (Get-V11GuiName -Window $win -Name 'UndoButton').Add_Click({
        try { Invoke-V11GuiUndo -Window $win -Status $status }
        catch { Write-V11 ("FAILED: {0}" -f $_.Exception.Message) 'Red' }
    })
    (Get-V11GuiName -Window $win -Name 'RestorePointButton').Add_Click({
        try { Invoke-V11GuiRestorePoint -Status $status }
        catch { Write-V11 ("FAILED: {0}" -f $_.Exception.Message) 'Red' }
    })

    [void]$win.ShowDialog()
    $script:V11LogSink = $null
    $script:V11LogBox  = $null
}

# ---------------------------------------------------------------------- main
function Invoke-V11Main {
    if ($List)    { Show-V11Details -Groups (Get-V11Tweaks); return }
    if ($Details) { Show-V11Details -Groups (Get-V11Tweaks); return }

    if ($Revert) {
        $dir = $Snapshot
        if (-not $dir) {
            $snaps = @(Get-V11Snapshots)
            if (-not $snaps.Count) { Write-V11 'No snapshots found in .\snapshots' 'Red'; exit 1 }
            $dir = $snaps[0].FullName
        }
        if (-not (Get-V11IsAdmin)) {
            $arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Revert -Snapshot "{1}" -Yes' -f $PSCommandPath, $dir
            if (-not (Request-V11Elevation -ArgumentString $arg)) { exit 1 }
            exit 0
        }
        $script:V11LogPath = Join-Path $dir 'revert.log'
        $ok = Restore-V11Snapshot -Dir $dir
        $script:V11LogPath = $null
        if (-not $ok) { exit 1 }
        exit 0
    }

    if ($Apply) {
        $groups = Get-V11Tweaks
        $count  = Show-V11Review -Groups $groups
        if ($count -eq 0) { Write-V11 'Nothing selected.' 'Yellow'; exit 0 }
        if (-not $Yes) {
            Write-Host 'Apply these changes now? [y/N] ' -ForegroundColor Yellow
            $ans = (Read-Host).Trim().ToLower()
            if ($ans -ne 'y' -and $ans -ne 'yes') { Write-V11 'Cancelled.' 'Yellow'; exit 0 }
        }
        if (-not (Get-V11IsAdmin)) {
            $arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Apply -Yes' -f $PSCommandPath
            if (-not (Request-V11Elevation -ArgumentString $arg)) { Write-V11 'Administrator rights are required.' 'Red'; exit 1 }
            exit 0
        }
        $good = Invoke-V11Apply -Groups $groups -SnapshotDir $null
        if (-not $good) { exit 1 }
        exit 0
    }

    if ($Menu) {
        # Console menu: hand off to one elevated session up front, so applying
        # later never interrupts with a second prompt. Declining UAC leaves the
        # menu usable - it will only ask again when you choose [a]pply.
        if (-not (Get-V11IsAdmin)) {
            Write-V11 'Requesting administrator rights (accept the UAC prompt)...' 'Yellow'
            if (Start-V11Elevated -ExtraArgs '-Menu') {
                Write-V11 'An elevated window is opening - you can close this one.' 'Cyan'
                exit 7                  # 7 = handed off; the .cmd launcher knows not to pause
            }
            Write-V11 'Continuing without administrator rights - apply will ask again then.' 'DarkYellow'
            Start-Sleep -Milliseconds 600
        }
        Invoke-V11Menu
        return
    }

    # Default: the Chris Titus-style GUI. Hand off to an elevated session up
    # front so the first click on Run Tweaks just works; declining UAC still
    # opens the window (apply is then blocked with a clear message).
    if (-not (Get-V11IsAdmin)) {
        Write-V11 'Requesting administrator rights (accept the UAC prompt)...' 'Yellow'
        if (Start-V11Elevated) {
            Write-V11 'An elevated window is opening - you can close this one.' 'Cyan'
            exit 7                      # 7 = handed off; the .cmd launcher knows not to pause
        }
        Write-V11 'Continuing without administrator rights - Run Tweaks will be unavailable.' 'DarkYellow'
        Start-Sleep -Milliseconds 600
    }

    Invoke-V11Gui
}

if (-not $V11DotSourced) { Invoke-V11Main }
