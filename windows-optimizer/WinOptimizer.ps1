#Requires -Version 5.1
<#
.SYNOPSIS
    WinOptimizer - a safe, reversible tune-up tool for Windows 10/11 laptops.

.DESCRIPTION
    Interactive menu that cleans junk files, switches power plans, applies a few
    well-known gaming tweaks and runs Windows' own maintenance tools.

    Every registry change is backed up first and can be undone from the
    "Undo all tweaks" menu entry. Nothing here disables security features,
    Windows services or the page file.

.NOTES
    Start it with Run-WinOptimizer.bat, or from a terminal:
        powershell -NoProfile -ExecutionPolicy Bypass -File .\WinOptimizer.ps1
    It asks for administrator rights (UAC) because cleaning C:\Windows\Temp,
    changing power plans and running SFC/DISM all require them.
#>
[CmdletBinding()]
param()

# ---------------------------------------------------------------------------
# Startup checks
# ---------------------------------------------------------------------------

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'WinOptimizer only runs on Windows.' -ForegroundColor Red
    exit 1
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Relaunch elevated, and always in Windows PowerShell 5.1 (Checkpoint-Computer
# and a few other cmdlets used here do not exist in PowerShell 7).
if (-not (Test-IsAdmin) -or $PSVersionTable.PSEdition -eq 'Core') {
    Write-Host 'Requesting administrator rights...' -ForegroundColor Yellow
    try {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments -ErrorAction Stop
    } catch {
        Write-Host 'Administrator rights are required. Exiting.' -ForegroundColor Red
        Read-Host 'Press Enter to close' | Out-Null
    }
    exit
}

$Host.UI.RawUI.WindowTitle = 'WinOptimizer'

$StateDir   = Join-Path $env:LOCALAPPDATA 'WinOptimizer'
$BackupFile = Join-Path $StateDir 'registry-backup.json'
$LogFile    = Join-Path $StateDir ('log-{0:yyyyMMdd-HHmmss}.txt' -f (Get-Date))
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
try { Start-Transcript -Path $LogFile | Out-Null } catch { }

# Built-in power scheme GUIDs (these are the same on every Windows install).
$PowerSchemeHighPerformance  = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$PowerSchemeUltimate         = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$GuidPattern = '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'

# ---------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host ('=== {0} ===' -f $Title) -ForegroundColor Cyan
}

function Write-Ok([string]$Message)   { Write-Host ('  [OK]   {0}' -f $Message) -ForegroundColor Green }
function Write-Info([string]$Message) { Write-Host ('  [..]   {0}' -f $Message) }
function Write-Warn([string]$Message) { Write-Host ('  [!!]   {0}' -f $Message) -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host ('  [XX]   {0}' -f $Message) -ForegroundColor Red }

function Confirm-Choice([string]$Prompt) {
    $answer = Read-Host ('{0} [y/N]' -f $Prompt)
    return ($answer -match '^\s*(y|yes)\s*$')
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return '{0:N0} bytes' -f $Bytes
}

# ---------------------------------------------------------------------------
# Registry tweaks with backup / undo
# ---------------------------------------------------------------------------

function Get-Backup {
    if (-not (Test-Path -LiteralPath $BackupFile)) { return @() }
    # Assign first: in PowerShell 5.1 piping a JSON array into ConvertFrom-Json
    # yields the array as one object, which breaks @() wrapping.
    $data = ConvertFrom-Json (Get-Content -LiteralPath $BackupFile -Raw)
    return $data
}

function Save-Backup($Entries) {
    ConvertTo-Json -InputObject @($Entries) -Depth 4 | Set-Content -LiteralPath $BackupFile -Encoding UTF8
}

function Set-RegistryTweak {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] $Value,
        [ValidateSet('DWord', 'String')] [string]$Type = 'DWord'
    )

    # Only the first change to a value is backed up, so undo always returns to
    # the state from before WinOptimizer was ever used.
    $backup = @(Get-Backup)
    $already = $backup | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name }
    if (-not $already) {
        $entry = [ordered]@{ Path = $Path; Name = $Name; Existed = $false; Value = $null; Type = $null }
        if (Test-Path -LiteralPath $Path) {
            $key = Get-Item -LiteralPath $Path
            if ($key.GetValueNames() -contains $Name) {
                $entry.Existed = $true
                $entry.Value = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
                $entry.Type = $key.GetValueKind($Name).ToString()
            }
        }
        Save-Backup ($backup + [pscustomobject]$entry)
    }

    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Undo-RegistryTweaks {
    Write-Section 'Undo all tweaks'
    $backup = @(Get-Backup)
    if ($backup.Count -eq 0) {
        Write-Info 'Nothing to undo - no registry tweaks have been applied.'
        return
    }

    foreach ($entry in $backup) {
        Write-Info ('{0} : {1}' -f $entry.Path, $entry.Name)
    }
    if (-not (Confirm-Choice ('Restore these {0} value(s) to how they were?' -f $backup.Count))) { return }

    $failed = 0
    foreach ($entry in $backup) {
        try {
            if ($entry.Existed) {
                $value = $entry.Value
                switch ($entry.Type) {
                    'Binary'      { $value = [byte[]]$entry.Value }
                    'MultiString' { $value = [string[]]$entry.Value }
                }
                if (-not (Test-Path -LiteralPath $entry.Path)) { New-Item -Path $entry.Path -Force | Out-Null }
                New-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Value $value -PropertyType $entry.Type -Force | Out-Null
            } elseif (Test-Path -LiteralPath $entry.Path) {
                Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue
            }
        } catch {
            $failed++
            Write-Fail ('Could not restore {0}\{1}: {2}' -f $entry.Path, $entry.Name, $_.Exception.Message)
        }
    }

    if ($failed -eq 0) {
        Remove-Item -LiteralPath $BackupFile -Force
        Write-Ok 'All tweaks undone. Sign out or restart for every change to take effect.'
    } else {
        Write-Warn 'Some values could not be restored; the backup file was kept so you can try again.'
    }
}

# ---------------------------------------------------------------------------
# 1. System report
# ---------------------------------------------------------------------------

function Show-SystemReport {
    Write-Section 'System report'
    $tips = New-Object System.Collections.Generic.List[string]

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $uptime = (Get-Date) - $os.LastBootUpTime

    Write-Host ('  Windows : {0} (build {1})' -f $os.Caption, $os.BuildNumber)
    Write-Host ('  CPU     : {0} - {1} cores / {2} threads, {3}% busy right now' -f `
        $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors, $cpu.LoadPercentage)

    foreach ($gpu in @(Get-CimInstance -ClassName Win32_VideoController)) {
        Write-Host ('  GPU     : {0} (driver {1})' -f $gpu.Name, $gpu.DriverVersion)
    }

    $totalRam = [double]$os.TotalVisibleMemorySize * 1KB
    $freeRam = [double]$os.FreePhysicalMemory * 1KB
    $ramUsedPct = [math]::Round(100 * ($totalRam - $freeRam) / $totalRam)
    Write-Host ('  RAM     : {0} used of {1} ({2}%)' -f (Format-Size ($totalRam - $freeRam)), (Format-Size $totalRam), $ramUsedPct)
    if ($ramUsedPct -ge 85) { $tips.Add('RAM is over 85% used - close programs you are not using (see the list below).') }

    Write-Host ('  Uptime  : {0} days {1} hours' -f $uptime.Days, $uptime.Hours)
    if ($uptime.TotalDays -ge 7) {
        $tips.Add('No restart for 7+ days. Use Restart (not Shut down): with Fast Startup on, Shut down does not fully reset Windows.')
    }

    Write-Host ''
    Write-Host '  Drives:'
    foreach ($vol in @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 })) {
        $freePct = [math]::Round(100 * $vol.SizeRemaining / $vol.Size)
        Write-Host ('    {0}:  {1} free of {2} ({3}%)' -f $vol.DriveLetter, (Format-Size $vol.SizeRemaining), (Format-Size $vol.Size), $freePct)
        if ($freePct -lt 10) { $tips.Add(('Drive {0}: is under 10% free - run "Clean junk files" and uninstall things you do not use.' -f $vol.DriveLetter)) }
    }
    try {
        foreach ($disk in @(Get-PhysicalDisk -ErrorAction Stop)) {
            Write-Host ('    {0} - {1}, health: {2}' -f $disk.FriendlyName, $disk.MediaType, $disk.HealthStatus)
            if ($disk.HealthStatus -ne 'Healthy') { $tips.Add(('Disk "{0}" reports health "{1}" - back up your files.' -f $disk.FriendlyName, $disk.HealthStatus)) }
        }
    } catch { }

    $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($battery) {
        Write-Host ''
        $line = '  Battery : {0}% charged' -f $battery.EstimatedChargeRemaining
        try {
            $design = (Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
            $full = (Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
            if ($design -gt 0 -and $full -gt 0) {
                $health = [math]::Round(100 * $full / $design)
                $line += (', holds {0}% of its original capacity' -f $health)
                if ($health -lt 80) { $tips.Add('Battery holds under 80% of its design capacity - normal wear, but expect shorter battery life.') }
            }
        } catch { }
        Write-Host $line
    }

    Write-Host ''
    Write-Host ('  Power plan: {0}' -f ((powercfg /getactivescheme) -replace '^.*?:\s*', ''))

    Write-Host ''
    Write-Host '  Biggest memory users right now:'
    Get-Process |
        Group-Object -Property ProcessName |
        ForEach-Object {
            [pscustomobject]@{
                Name  = $_.Name
                Count = $_.Count
                Bytes = ($_.Group | Measure-Object -Property WorkingSet64 -Sum).Sum
            }
        } |
        Sort-Object -Property Bytes -Descending |
        Select-Object -First 8 |
        ForEach-Object {
            $label = $_.Name
            if ($_.Count -gt 1) { $label = '{0} (x{1})' -f $_.Name, $_.Count }
            Write-Host ('    {0,-34} {1,10}' -f $label, (Format-Size $_.Bytes))
        }

    $startupCount = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction SilentlyContinue).Count
    Write-Host ''
    Write-Host ('  Startup entries registered: {0} (see menu option 6)' -f $startupCount)
    if ($startupCount -ge 10) { $tips.Add('Lots of startup programs - disabling ones you do not need speeds up boot.') }

    Write-Section 'Suggestions'
    if ($tips.Count -eq 0) {
        Write-Ok 'Nothing obvious to fix. Keep Windows Update and your GPU driver current.'
    } else {
        foreach ($tip in $tips) { Write-Warn $tip }
    }
}

# ---------------------------------------------------------------------------
# 2. Junk file cleanup
# ---------------------------------------------------------------------------

# Walks a folder without following junctions or symbolic links, so a link
# inside a temp folder can never lead the cleaner into other folders.
function Get-TreeItems([string]$Root) {
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $item
            if ($item.PSIsContainer) { $stack.Push($item.FullName) }
        }
    }
}

# Refuses empty paths and drive roots so a missing environment variable can
# never point the cleaner at a whole drive.
function Test-CleanablePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path.TrimEnd('\').Length -le 2) { return $false }
    return (Test-Path -LiteralPath $Path -PathType Container)
}

function Get-CleanableBytes([string]$Path, [int]$MinAgeHours) {
    if (-not (Test-CleanablePath $Path)) { return 0 }
    $cutoff = (Get-Date).AddHours(-$MinAgeHours)
    $sum = (Get-TreeItems $Path |
        Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $cutoff } |
        Measure-Object -Property Length -Sum).Sum
    if ($sum) { return [double]$sum }
    return 0
}

function Clear-FolderContents([string]$Path, [int]$MinAgeHours) {
    if (-not (Test-CleanablePath $Path)) { return 0 }
    $before = Get-CleanableBytes $Path 0
    $cutoff = (Get-Date).AddHours(-$MinAgeHours)
    $items = @(Get-TreeItems $Path)

    # Files that are in use by a running program are skipped automatically.
    $items | Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $cutoff } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    # Then remove folders that are now empty, deepest first.
    $items | Where-Object { $_.PSIsContainer } |
        Sort-Object -Property { $_.FullName.Length } -Descending |
        ForEach-Object {
            if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }

    $after = Get-CleanableBytes $Path 0
    return [math]::Max(0, $before - $after)
}

function Get-CleanupTargets {
    # MinAgeHours protects files a running installer or app may still need.
    return @(
        [pscustomobject]@{ Name = 'Your temp folder';               Path = $env:TEMP;                                                      MinAgeHours = 24; Services = @() }
        [pscustomobject]@{ Name = 'Windows temp folder';            Path = (Join-Path $env:windir 'Temp');                                 MinAgeHours = 24; Services = @() }
        [pscustomobject]@{ Name = 'Windows Update download cache';  Path = (Join-Path $env:windir 'SoftwareDistribution\Download');        MinAgeHours = 0;  Services = @('wuauserv', 'bits') }
        [pscustomobject]@{ Name = 'Old crash / error reports';      Path = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'); MinAgeHours = 0; Services = @() }
        [pscustomobject]@{ Name = 'Queued crash / error reports';   Path = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue');   MinAgeHours = 0; Services = @() }
    )
}

function Invoke-JunkCleanup([switch]$NoPrompt) {
    Write-Section 'Clean junk files'
    $targets = Get-CleanupTargets

    Write-Info 'Scanning...'
    $total = 0
    foreach ($t in $targets) {
        $bytes = Get-CleanableBytes $t.Path $t.MinAgeHours
        $total += $bytes
        Write-Host ('    {0,-32} {1,10}' -f $t.Name, (Format-Size $bytes))
    }
    Write-Host ('    {0,-32} {1,10}' -f 'Total (approx.)', (Format-Size $total)) -ForegroundColor White
    Write-Host '    (plus the Delivery Optimization cache, which Windows sizes itself)'

    if (-not $NoPrompt -and -not (Confirm-Choice 'Delete these files?')) { return }

    $freed = 0
    foreach ($t in $targets) {
        # Stop services that hold files in the folder, then put them back
        # exactly as they were.
        $restart = @()
        foreach ($svcName in $t.Services) {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
                $restart += $svcName
            }
        }
        try {
            $bytes = Clear-FolderContents $t.Path $t.MinAgeHours
            $freed += $bytes
            Write-Ok ('{0}: freed {1}' -f $t.Name, (Format-Size $bytes))
        } finally {
            foreach ($svcName in $restart) { Start-Service -Name $svcName -ErrorAction SilentlyContinue }
        }
    }

    if (Get-Command -Name Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        try {
            Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
            Write-Ok 'Delivery Optimization cache cleared'
        } catch {
            Write-Warn ('Delivery Optimization cache: {0}' -f $_.Exception.Message)
        }
    }

    if (-not $NoPrompt) {
        if (Confirm-Choice 'Also empty the Recycle Bin? (deleted files there will be gone for good)') {
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue
            Write-Ok 'Recycle Bin emptied'
        }
    }

    Write-Host ''
    Write-Ok ('Done - about {0} freed. Files in use were skipped; that is normal.' -f (Format-Size $freed))
    Write-Info 'For even more space: Maintenance -> "Clean up old Windows component files".'
}

# ---------------------------------------------------------------------------
# 3. Power plans
# ---------------------------------------------------------------------------

# Activates a built-in scheme. If Windows hides it (common on laptops), a copy
# is created once and named "WinOptimizer <label>" so it is reused next time.
function Enable-PowerScheme([string]$BaseGuid, [string]$Label) {
    $list = (powercfg /list) -join "`n"
    if ($list -match [regex]::Escape($BaseGuid)) {
        powercfg /setactive $BaseGuid | Out-Null
        return ($LASTEXITCODE -eq 0)
    }

    $customName = 'WinOptimizer {0}' -f $Label
    $existing = [regex]::Match($list, ('({0})\s+\({1}\)' -f $GuidPattern, [regex]::Escape($customName)))
    if ($existing.Success) {
        powercfg /setactive $existing.Groups[1].Value | Out-Null
        return ($LASTEXITCODE -eq 0)
    }

    $output = (powercfg /duplicatescheme $BaseGuid 2>&1) -join ' '
    $newGuid = [regex]::Match($output, $GuidPattern).Value
    if (-not $newGuid) { return $false }
    powercfg /changename $newGuid $customName | Out-Null
    powercfg /setactive $newGuid | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }

    # Could not activate it, so do not leave an unused plan behind.
    powercfg /delete $newGuid | Out-Null
    return $false
}

function Show-PowerFallback {
    Write-Warn 'Windows would not switch plans. Many modern laptops (Modern Standby) only allow "Balanced".'
    Write-Info 'Use the Power mode setting instead: choose "Best performance" while plugged in.'
    Start-Process 'ms-settings:powersleep'
}

function Invoke-PowerMenu {
    Write-Section 'Power plan'
    Write-Info ('Current: {0}' -f ((powercfg /getactivescheme) -replace '^.*?:\s*', ''))
    Write-Host ''
    Write-Host '  1. Balanced              - best for battery life (Windows default)'
    Write-Host '  2. High performance      - for gaming while plugged in'
    Write-Host '  3. Ultimate performance  - made for desktops; more heat and battery drain,'
    Write-Host '                             usually little extra FPS over High performance'
    Write-Host '  4. Open Windows power mode settings'
    Write-Host '  B. Back'
    switch ((Read-Host 'Choose').Trim().ToUpper()) {
        '1' {
            powercfg /setactive SCHEME_BALANCED | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Ok 'Balanced plan active' } else { Write-Fail 'Could not switch plan' }
        }
        '2' {
            if (Enable-PowerScheme $PowerSchemeHighPerformance 'High performance') {
                Write-Ok 'High performance plan active. Switch back to Balanced when on battery.'
            } else { Show-PowerFallback }
        }
        '3' {
            if (Enable-PowerScheme $PowerSchemeUltimate 'Ultimate performance') {
                Write-Ok 'Ultimate performance plan active. Switch back to Balanced when on battery.'
            } else { Show-PowerFallback }
        }
        '4' { Start-Process 'ms-settings:powersleep' }
    }
}

# ---------------------------------------------------------------------------
# 4. Gaming tweaks
# ---------------------------------------------------------------------------

function Enable-GameMode {
    Set-RegistryTweak -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -Value 1
    Write-Ok 'Game Mode on (stops Windows Update installing drivers or asking to restart while you play)'
}

function Disable-BackgroundRecording {
    Set-RegistryTweak -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 0
    Set-RegistryTweak -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value 0
    Set-RegistryTweak -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'HistoricalCaptureEnabled' -Value 0
    Write-Ok 'Xbox Game Bar background recording off (you can still use other recorders, e.g. ShadowPlay / OBS)'
}

function Enable-GpuScheduling {
    Set-RegistryTweak -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -Value 2
    Write-Ok 'Hardware-accelerated GPU scheduling requested - restart to apply.'
    Write-Info 'It needs a recent GPU and driver (e.g. NVIDIA GTX 10-series or newer); Windows ignores it otherwise.'
}

function Find-WarThunder {
    $found = New-Object System.Collections.Generic.List[string]

    # Gaijin's standalone launcher installs here by default.
    $found.Add((Join-Path $env:LOCALAPPDATA 'WarThunder\win64\aces.exe'))

    # Steam: read every library folder from libraryfolders.vdf.
    $steamPath = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name 'SteamPath' -ErrorAction SilentlyContinue).SteamPath
    if ($steamPath) {
        $libraries = @($steamPath -replace '/', '\')
        $vdf = Join-Path $libraries[0] 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libraries += ($m.Groups[1].Value -replace '\\\\', '\')
            }
        }
        foreach ($lib in @($libraries | Sort-Object -Unique)) {
            $found.Add((Join-Path $lib 'steamapps\common\War Thunder\win64\aces.exe'))
        }
    }

    # Sort-Object -Unique is case-insensitive; Steam mixes path casing.
    return @($found | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object -Unique)
}

function Set-HighPerformanceGpu {
    Write-Section 'Use the dedicated GPU for a game'
    Write-Info 'On laptops with integrated + dedicated graphics, Windows sometimes runs games on the weaker'
    Write-Info 'integrated GPU. This sets the same option as Settings > Display > Graphics.'
    Write-Host ''

    $candidates = @(Find-WarThunder)
    $i = 1
    foreach ($exe in $candidates) {
        Write-Host ('  {0}. {1}' -f $i, $exe)
        $i++
    }
    Write-Host '  P. Enter a path to a game .exe yourself'
    Write-Host '  B. Back'
    if ($candidates.Count -gt 0) { Write-Info 'Found War Thunder above (aces.exe is the actual game, launcher.exe only updates it).' }

    $choice = (Read-Host 'Choose').Trim().ToUpper()
    $exePath = $null
    if ($choice -eq 'P') {
        $exePath = (Read-Host 'Full path to the .exe').Trim().Trim('"')
    } elseif ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $candidates.Count) {
        $exePath = $candidates[[int]$choice - 1]
    } else {
        return
    }

    if (-not ($exePath -like '*.exe') -or -not (Test-Path -LiteralPath $exePath)) {
        Write-Fail 'That file does not exist or is not an .exe'
        return
    }
    Set-RegistryTweak -Path 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Name $exePath -Value 'GpuPreference=2;' -Type String
    Write-Ok ('{0} will use the high-performance GPU next time it starts' -f (Split-Path -Leaf $exePath))
}

function Invoke-GamingMenu {
    Write-Section 'Gaming tweaks'
    Write-Host '  1. Turn on Game Mode'
    Write-Host '  2. Turn off Xbox Game Bar background recording'
    Write-Host '  3. Turn on hardware-accelerated GPU scheduling (restart needed)'
    Write-Host '  4. Make a game (e.g. War Thunder) use the dedicated GPU'
    Write-Host '  5. Apply 1 + 2'
    Write-Host '  B. Back'
    Write-Info 'All of these can be reverted with "Undo all tweaks" on the main menu.'
    switch ((Read-Host 'Choose').Trim().ToUpper()) {
        '1' { Enable-GameMode }
        '2' { Disable-BackgroundRecording }
        '3' { Enable-GpuScheduling }
        '4' { Set-HighPerformanceGpu }
        '5' { Enable-GameMode; Disable-BackgroundRecording }
    }
}

# ---------------------------------------------------------------------------
# 5. Visual effects
# ---------------------------------------------------------------------------

function Invoke-VisualsMenu {
    Write-Section 'Lighter visual effects'
    Write-Info 'Helps most on laptops with integrated graphics. Expect a smoother desktop, not more game FPS.'
    Write-Host '  1. Turn off transparency effects'
    Write-Host '  2. Open "Performance Options" (choose "Adjust for best performance" there)'
    Write-Host '  B. Back'
    switch ((Read-Host 'Choose').Trim().ToUpper()) {
        '1' {
            Set-RegistryTweak -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'EnableTransparency' -Value 0
            Write-Ok 'Transparency off'
        }
        '2' { Start-Process 'SystemPropertiesPerformance.exe' }
    }
}

# ---------------------------------------------------------------------------
# 6. Startup apps
# ---------------------------------------------------------------------------

function Show-StartupApps {
    Write-Section 'Startup apps'
    $items = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction SilentlyContinue | Sort-Object -Property Caption)
    if ($items.Count -eq 0) {
        Write-Info 'No startup entries found.'
    } else {
        foreach ($item in $items) {
            Write-Host ('  - {0}' -f $item.Caption) -ForegroundColor White
            Write-Host ('      {0}' -f $item.Command) -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Info 'This list includes entries you may already have disabled.'
    }
    Write-Info 'Safe to disable: chat apps, game launchers, updaters you do not need at boot.'
    Write-Info 'Keep: audio, touchpad, GPU control panel and antivirus entries.'
    if (Confirm-Choice 'Open the Startup apps page in Settings to switch them off?') {
        Start-Process 'ms-settings:startupapps'
    }
}

# ---------------------------------------------------------------------------
# 7. Maintenance & repair
# ---------------------------------------------------------------------------

function Optimize-SystemDrive {
    $letter = $env:SystemDrive.TrimEnd(':')
    Write-Info ('Optimising drive {0}: (TRIM on an SSD, defragment on a hard drive)...' -f $letter)
    try {
        Optimize-Volume -DriveLetter $letter -ErrorAction Stop
        Write-Ok 'Drive optimised'
    } catch {
        Write-Fail $_.Exception.Message
    }
}

function Invoke-MaintenanceMenu {
    Write-Section 'Maintenance & repair'
    Write-Host '  1. Optimise system drive (TRIM / defrag - picks the right one automatically)'
    Write-Host '  2. Check system files for corruption (sfc /scannow, ~10-20 min)'
    Write-Host '  3. Repair the Windows image (DISM RestoreHealth, needs internet, ~15-30 min)'
    Write-Host '  4. Clean up old Windows component files (DISM StartComponentCleanup, frees space)'
    Write-Host '  5. Flush DNS cache (fixes some "cannot reach site/server" problems)'
    Write-Host '  6. Create a battery health report'
    Write-Host '  7. Open Windows Update (keep Windows and GPU drivers up to date)'
    Write-Host '  B. Back'
    switch ((Read-Host 'Choose').Trim().ToUpper()) {
        '1' { Optimize-SystemDrive }
        '2' { sfc /scannow }
        '3' { DISM /Online /Cleanup-Image /RestoreHealth }
        '4' {
            Write-Info 'Deletes old versions of updated Windows components now, instead of after the usual 30 days.'
            if (Confirm-Choice 'Continue?') { DISM /Online /Cleanup-Image /StartComponentCleanup }
        }
        '5' {
            ipconfig /flushdns | Out-Null
            Write-Ok 'DNS cache flushed'
        }
        '6' {
            $report = Join-Path $StateDir 'battery-report.html'
            powercfg /batteryreport /output "$report" | Out-Null
            if (Test-Path -LiteralPath $report) {
                Write-Ok ('Saved to {0}' -f $report)
                Start-Process $report
            } else {
                Write-Fail 'Windows could not create a battery report (no battery found?)'
            }
        }
        '7' { Start-Process 'ms-settings:windowsupdate' }
    }
}

# ---------------------------------------------------------------------------
# 8. Restore point and quick tune-up
# ---------------------------------------------------------------------------

function New-RestorePoint {
    Write-Info 'Creating a System Restore point...'
    try {
        $warnings = $null
        Checkpoint-Computer -Description 'WinOptimizer' -RestorePointType 'MODIFY_SETTINGS' `
            -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable warnings
        if ($warnings) {
            # Windows allows one automatic restore point per 24 hours by default.
            Write-Warn ('Windows skipped it: {0}' -f ($warnings -join ' '))
        } else {
            Write-Ok 'Restore point created'
        }
        return $true
    } catch {
        Write-Warn ('No restore point: {0}' -f $_.Exception.Message)
        Write-Info 'System Protection may be off. Turn it on via: Start > "Create a restore point" > Configure.'
        return $false
    }
}

function Invoke-QuickTuneUp {
    Write-Section 'Quick tune-up'
    Write-Host '  This will:'
    Write-Host '    - create a restore point'
    Write-Host '    - delete temp files, the update download cache and old error reports'
    Write-Host '    - turn on Game Mode and turn off Game Bar background recording'
    Write-Host '    - optimise the system drive and flush the DNS cache'
    Write-Host '  It will NOT empty the Recycle Bin or change your power plan.'
    if (-not (Confirm-Choice 'Run it now?')) { return }

    if (-not (New-RestorePoint)) {
        if (-not (Confirm-Choice 'Continue without a restore point? (registry tweaks can still be undone from the menu)')) { return }
    }
    Invoke-JunkCleanup -NoPrompt
    Write-Section 'Gaming tweaks'
    Enable-GameMode
    Disable-BackgroundRecording
    Write-Section 'Maintenance'
    Optimize-SystemDrive
    ipconfig /flushdns | Out-Null
    Write-Ok 'DNS cache flushed'

    Write-Section 'Finished'
    Write-Ok 'Tune-up complete. Restart your laptop to finish.'
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------

function Show-MainMenu {
    Clear-Host
    Write-Host ''
    Write-Host '  WinOptimizer - safe tune-up for Windows 10/11' -ForegroundColor Cyan
    Write-Host '  ---------------------------------------------'
    Write-Host '  1. System health report'
    Write-Host '  2. Clean junk files'
    Write-Host '  3. Power plan'
    Write-Host '  4. Gaming tweaks'
    Write-Host '  5. Lighter visual effects'
    Write-Host '  6. Startup apps'
    Write-Host '  7. Maintenance & repair'
    Write-Host '  8. Quick tune-up (recommended safe set)'
    Write-Host '  9. Create a restore point'
    Write-Host '  U. Undo all tweaks'
    Write-Host '  Q. Quit'
    Write-Host ''
    Write-Host ('  Log: {0}' -f $LogFile) -ForegroundColor DarkGray
    Write-Host ''
}

while ($true) {
    Show-MainMenu
    $choice = (Read-Host 'Choose an option').Trim().ToUpper()
    if ($choice -eq 'Q') { break }
    if ($choice -notmatch '^[1-9U]$') { continue }
    try {
        switch ($choice) {
            '1' { Show-SystemReport }
            '2' { Invoke-JunkCleanup }
            '3' { Invoke-PowerMenu }
            '4' { Invoke-GamingMenu }
            '5' { Invoke-VisualsMenu }
            '6' { Show-StartupApps }
            '7' { Invoke-MaintenanceMenu }
            '8' { Invoke-QuickTuneUp }
            '9' { New-RestorePoint | Out-Null }
            'U' { Undo-RegistryTweaks }
        }
    } catch {
        Write-Fail ('Something went wrong: {0}' -f $_.Exception.Message)
    }
    Write-Host ''
    Read-Host 'Press Enter to return to the menu' | Out-Null
}

try { Stop-Transcript | Out-Null } catch { }
