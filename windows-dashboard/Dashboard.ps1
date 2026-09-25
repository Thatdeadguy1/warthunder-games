<#
    Dashboard - Windows launcher dashboard
    Opens apps and websites from config.json, shows live system/network stats,
    and watches for ESP32 USB-serial devices (opens the Ghost ESP panel).

    Run with Launch-Dashboard.bat, or:
        powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\Dashboard.ps1
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Any startup error: show it in a message box and save it next to the script,
# because the launcher hides the console window.
trap {
    $msg = "$($_.Exception.Message)`n`nLine $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    try { Set-Content -Path (Join-Path $PSScriptRoot 'dashboard-error.log') -Value $msg } catch { }
    [void][Windows.MessageBox]::Show($msg, 'Dashboard error')
    exit 1
}

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'config.json'
try {
    $Config = Get-Content -Raw -Path $ConfigPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
} catch {
    [void][Windows.MessageBox]::Show("Could not load config.json:`n$($_.Exception.Message)", 'Dashboard')
    exit 1
}

# USB vendor IDs of the serial chips found on ESP32 dev boards.
$EspVendors = [ordered]@{
    '303A' = 'Espressif USB (S3/C3/C6)'
    '10C4' = 'Silicon Labs CP210x'
    '1A86' = 'WCH CH340/CH910x'
}

# ---------------------------------------------------------------- helpers ---

function Expand-PathString([string]$p) {
    [Environment]::ExpandEnvironmentVariables($p)
}

# Returns the first candidate that exists: a full path on disk, a command on
# PATH (incl. app execution aliases like wt.exe), or an App Paths registry entry.
function Resolve-AppPath($app) {
    foreach ($candidate in $app.paths) {
        $p = Expand-PathString $candidate
        if ($p -match '[\\/]') {
            if (Test-Path -LiteralPath $p) { return $p }
            continue
        }
        $cmd = Get-Command $p -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
        foreach ($hive in 'HKCU:', 'HKLM:') {
            $key = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$p"
            $reg = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
            $default = if ($reg) { $reg.PSObject.Properties['(default)'] } else { $null }
            if ($default -and $default.Value -and (Test-Path -LiteralPath $default.Value)) {
                return $default.Value
            }
        }
        # .msc / .cpl live in System32 and are opened via their file association
        $sys = Join-Path $env:SystemRoot "System32\$p"
        if (Test-Path -LiteralPath $sys) { return $sys }
    }
    return $null
}

function Write-Log([string]$msg, [string]$level = 'info') {
    $stamp = Get-Date -Format 'HH:mm:ss'
    $tag = switch ($level) { 'ok' { '[+]' } 'warn' { '[!]' } 'err' { '[x]' } default { '[*]' } }
    $LogBox.AppendText("$stamp $tag $msg`r`n")
    $LogBox.ScrollToEnd()
}

function Start-App($app) {
    $path = Resolve-AppPath $app
    if (-not $path) {
        $tried = ($app.paths | ForEach-Object { Expand-PathString $_ }) -join '; '
        Write-Log "$($app.name) not found. Looked in: $tried" 'warn'
        return $false
    }
    try {
        $params = @{ FilePath = $path }
        if ($app.PSObject.Properties['args'] -and $app.args) { $params.ArgumentList = $app.args }
        if ($app.PSObject.Properties['admin'] -and $app.admin) { $params.Verb = 'RunAs' }
        Start-Process @params
        Write-Log "Launched $($app.name)" 'ok'
        return $true
    } catch {
        Write-Log "Failed to launch $($app.name): $($_.Exception.Message)" 'err'
        return $false
    }
}

function Open-Url([string]$url, [string]$label) {
    $browser = $Config.apps | Where-Object { $_.name -eq $Config.browser } | Select-Object -First 1
    $browserPath = if ($browser) { Resolve-AppPath $browser } else { $null }
    try {
        if ($browserPath) {
            Start-Process -FilePath $browserPath -ArgumentList "`"$url`""
        } else {
            Start-Process $url   # default browser
        }
        Write-Log "Opened $label" 'ok'
    } catch {
        Write-Log "Failed to open ${label}: $($_.Exception.Message)" 'err'
    }
}

function Get-EspDevices {
    $filter = ($EspVendors.Keys | ForEach-Object { "DeviceID LIKE '%VID_$_%'" }) -join ' OR '
    $devs = Get-CimInstance -ClassName Win32_PnPEntity -Filter $filter -ErrorAction SilentlyContinue
    foreach ($d in $devs) {
        if ($d.PNPDeviceID -notmatch 'VID_([0-9A-F]{4})') { continue }
        $vid = $Matches[1]
        $port = if ($d.Name -match '\((COM\d+)\)') { $Matches[1] } else { $null }
        [pscustomobject]@{
            Name   = $d.Name
            Port   = $port
            Chip   = $EspVendors[$vid]
            Status = $d.Status
        }
    }
}

function Open-GhostEsp {
    $panel = Expand-PathString $Config.ghostEspPanel
    if (-not (Test-Path -LiteralPath $panel)) {
        Write-Log "Ghost ESP panel not found at $panel (edit ghostEspPanel in config.json)" 'warn'
        return
    }
    Open-Url ([Uri]$panel).AbsoluteUri 'Ghost ESP panel'
}

function Format-Uptime([TimeSpan]$t) {
    '{0}d {1:00}h {2:00}m' -f $t.Days, $t.Hours, $t.Minutes
}

# ------------------------------------------------------------------ theme ---

# Birch dark: bark-black background, birch-bark cream primary, red secondary.
$Theme = [ordered]@{
    Bg = '#121110'; Panel = '#1A1816'; TileBg = '#1F1C19'; TileHover = '#29251F'
    Edge = '#332D27'; Text = '#ECE6D8'; Muted = '#8E8578'
    Accent = '#EFE8D8'; Accent2 = '#E5484D'; AccentBg = '#2A1616'
    LogBg = '#0C0B0A'; LogText = '#A89F90'
}

# Dark Windows title bar (Windows 10 20H1+ / 11; ignored elsewhere).
Add-Type -Namespace WinDash -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);
'@

function Set-DarkTitleBar {
    $hwnd = (New-Object Windows.Interop.WindowInteropHelper $Window).Handle
    if ($hwnd -eq [IntPtr]::Zero) { return }
    $v = 1
    [void][WinDash.Dwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)   # DWMWA_USE_IMMERSIVE_DARK_MODE
}

function Set-Theme {
    foreach ($kv in $Theme.GetEnumerator()) {
        $brush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($kv.Value))
        $brush.Freeze()
        $Window.Resources[$kv.Key] = $brush
    }
}

# --------------------------------------------------------------------- UI ---

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Dashboard" Width="1180" Height="780" MinWidth="900" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource Bg}"
        FontFamily="Segoe UI" Foreground="{DynamicResource Text}">
  <Window.Resources>
    <!-- colour brushes are injected from $Theme by Set-Theme -->

    <Style x:Key="Tile" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Background" Value="{DynamicResource TileBg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Edge}"/>
      <Setter Property="Width" Value="190"/>
      <Setter Property="Height" Value="58"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    CornerRadius="6" Padding="12,8">
              <ContentPresenter VerticalAlignment="Center"
                                HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Accent2}"/>
                <Setter TargetName="b" Property="Background" Value="{DynamicResource TileHover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="b" Property="Background" Value="{DynamicResource AccentBg}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Tile}">
      <Setter Property="Width" Value="Auto"/>
      <Setter Property="Height" Value="46"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="Background" Value="{DynamicResource AccentBg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Accent2}"/>
      <Setter Property="Foreground" Value="{DynamicResource Accent2}"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>

    <Style x:Key="Small" TargetType="Button" BasedOn="{StaticResource Tile}">
      <Setter Property="Width" Value="Auto"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>

    <Style x:Key="H" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{DynamicResource Accent2}"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
    </Style>
    <Style x:Key="K" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Width" Value="70"/>
    </Style>
    <Style x:Key="V" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource Panel}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Edge}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="14"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
  </Window.Resources>

  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="130"/>
    </Grid.RowDefinitions>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="300"/>
      <ColumnDefinition Width="16"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- header -->
    <DockPanel Grid.Row="0" Grid.ColumnSpan="3" Margin="0,0,0,14">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock x:Name="Clock" FontFamily="Consolas" FontSize="22" VerticalAlignment="Center"
                   Foreground="{DynamicResource Accent}"/>
      </StackPanel>
      <StackPanel>
        <TextBlock x:Name="Subtitle" FontFamily="Consolas" FontSize="14" Foreground="{DynamicResource Muted}"/>
      </StackPanel>
    </DockPanel>

    <!-- left column -->
    <ScrollViewer Grid.Row="1" Grid.Column="0" VerticalScrollBarVisibility="Auto">
      <StackPanel>
        <Button x:Name="DevStart" Style="{StaticResource Primary}" Content="&gt; DEV TOOL START"/>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Style="{StaticResource H}" Text="// SYSTEM"/>
            <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource K}" Text="CPU"/><TextBlock x:Name="Cpu" Style="{StaticResource V}"/></StackPanel>
            <ProgressBar x:Name="CpuBar" Height="4" Margin="0,4,0,8" Maximum="100" Foreground="{DynamicResource Accent}" Background="{DynamicResource Edge}" BorderThickness="0"/>
            <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource K}" Text="RAM"/><TextBlock x:Name="Ram" Style="{StaticResource V}"/></StackPanel>
            <ProgressBar x:Name="RamBar" Height="4" Margin="0,4,0,8" Maximum="100" Foreground="{DynamicResource Accent2}" Background="{DynamicResource Edge}" BorderThickness="0"/>
            <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource K}" Text="Uptime"/><TextBlock x:Name="Uptime" Style="{StaticResource V}"/></StackPanel>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Style="{StaticResource H}" Text="// NETWORK"/>
            <TextBlock x:Name="Net" Style="{StaticResource V}" Margin="0,0,0,10"/>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="NetRefresh" Style="{StaticResource Small}" Content="Refresh"/>
              <Button x:Name="FlushDns"   Style="{StaticResource Small}" Content="Flush DNS"/>
            </StackPanel>
            <DockPanel Margin="0,10,0,0">
              <Button x:Name="PingBtn" DockPanel.Dock="Right" Style="{StaticResource Small}" Content="Ping" Margin="6,0,0,0"/>
              <TextBox x:Name="PingHost" Text="1.1.1.1" Height="32" Padding="6,6" Background="{DynamicResource Bg}"
                       Foreground="{DynamicResource Text}" BorderBrush="{DynamicResource Edge}" CaretBrush="{DynamicResource Accent}" FontFamily="Consolas"/>
            </DockPanel>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <DockPanel>
              <Ellipse x:Name="EspDot" DockPanel.Dock="Right" Width="10" Height="10" Fill="{DynamicResource Muted}" VerticalAlignment="Top" Margin="0,2,0,0"/>
              <TextBlock Style="{StaticResource H}" Text="// ESP32 / USB SERIAL"/>
            </DockPanel>
            <TextBlock x:Name="Esp" Style="{StaticResource V}" Margin="0,0,0,10"/>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="EspScan"  Style="{StaticResource Small}" Content="Scan"/>
              <Button x:Name="GhostEsp" Style="{StaticResource Small}" Content="Ghost ESP panel"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </StackPanel>
    </ScrollViewer>

    <!-- right column: launch tiles -->
    <ScrollViewer Grid.Row="1" Grid.Column="2" VerticalScrollBarVisibility="Auto">
      <StackPanel x:Name="Tiles"/>
    </ScrollViewer>

    <!-- log -->
    <TextBox x:Name="Log" Grid.Row="2" Grid.ColumnSpan="3" Margin="0,12,0,0" IsReadOnly="True"
             Background="{DynamicResource LogBg}" Foreground="{DynamicResource LogText}" BorderBrush="{DynamicResource Edge}" FontFamily="Consolas"
             FontSize="12" Padding="8" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
  </Grid>
</Window>
'@

$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $n = $_.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1
    $ui[$n.Value] = $Window.FindName($n.Value)
}
$LogBox = $ui.Log
# Errors inside button handlers go to the log instead of closing the window.
$Window.Dispatcher.Add_UnhandledException({
    param($src, $e)
    Write-Log "Error: $($e.Exception.Message)" 'err'
    $e.Handled = $true
})
Set-Theme
$Window.Add_SourceInitialized({ Set-DarkTitleBar })

$ui.Subtitle.Text = "$env:USERNAME@$env:COMPUTERNAME  //  $((Get-CimInstance Win32_OperatingSystem).Caption)"

# ------------------------------------------------------------ build tiles ---

function New-Tile([string]$title, [string]$sub, $tag, [bool]$dim) {
    $btn = New-Object Windows.Controls.Button
    $btn.Style = $Window.FindResource('Tile')
    $stack = New-Object Windows.Controls.StackPanel
    $t1 = New-Object Windows.Controls.TextBlock
    $t1.Text = $title; $t1.FontWeight = [Windows.FontWeights]::SemiBold; $t1.FontSize = 13
    $t1.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    $t2 = New-Object Windows.Controls.TextBlock
    $t2.Text = $sub; $t2.FontSize = 11; $t2.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Muted')
    $t2.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    [void]$stack.Children.Add($t1); [void]$stack.Children.Add($t2)
    $btn.Content = $stack
    $btn.Tag = $tag
    $btn.ToolTip = $sub
    if ($dim) { $btn.Opacity = 0.45 }
    $btn
}

function Add-Section([string]$heading, $tiles) {
    $h = New-Object Windows.Controls.TextBlock
    $h.Text = "// $heading"
    $h.Style = $Window.FindResource('H')
    $h.Margin = New-Object Windows.Thickness 0, 4, 0, 8
    $wrap = New-Object Windows.Controls.WrapPanel
    $wrap.Margin = New-Object Windows.Thickness 0, 0, 0, 10
    foreach ($t in $tiles) { [void]$wrap.Children.Add($t) }
    [void]$ui.Tiles.Children.Add($h)
    [void]$ui.Tiles.Children.Add($wrap)
}

$onAppClick  = { Start-App $this.Tag }
$onSiteClick = { Open-Url $this.Tag.url $this.Tag.name }

foreach ($group in ($Config.apps | Group-Object group)) {
    $tiles = foreach ($app in $group.Group) {
        $path = Resolve-AppPath $app
        $sub  = if ($path) { Split-Path -Leaf $path } else { 'not installed' }
        $tile = New-Tile $app.name $sub $app (-not $path)
        $tile.Add_Click($onAppClick)
        $tile
    }
    Add-Section "APPS : $($group.Name.ToUpper())" $tiles
}

foreach ($group in ($Config.sites | Group-Object group)) {
    $tiles = foreach ($site in $group.Group) {
        $tile = New-Tile $site.name (([Uri]$site.url).Host) $site $false
        $tile.Add_Click($onSiteClick)
        $tile
    }
    Add-Section "WEB : $($group.Name.ToUpper())" $tiles
}

# ----------------------------------------------------------- live panels ---

function Update-Stats {
    try {
        $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        $os  = Get-CimInstance Win32_OperatingSystem
        $totalGb = $os.TotalVisibleMemorySize / 1MB
        $usedGb  = ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB
        $ui.Cpu.Text      = '{0:0}%' -f $cpu
        $ui.CpuBar.Value  = [double]$cpu
        $ui.Ram.Text      = '{0:0.0} / {1:0.0} GB' -f $usedGb, $totalGb
        $ui.RamBar.Value  = 100 * $usedGb / $totalGb
        $ui.Uptime.Text   = Format-Uptime ((Get-Date) - $os.LastBootUpTime)
    } catch {
        $ui.Cpu.Text = 'n/a'
    }
}

function Update-Network {
    $lines = @()
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }
    foreach ($ip in $ips) { $lines += '{0,-14} {1}/{2}' -f $ip.InterfaceAlias, $ip.IPAddress, $ip.PrefixLength }
    $gw = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric | Select-Object -First 1
    if ($gw) { $lines += "gateway        $($gw.NextHop)" }
    $dns = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.ServerAddresses } | Select-Object -ExpandProperty ServerAddresses -Unique
    if ($dns) { $lines += "dns            $($dns -join ', ')" }
    $ui.Net.Text = if ($lines) { $lines -join "`n" } else { 'No IPv4 connection' }
}

$script:EspSeen = $false
function Update-Esp([bool]$announce = $false) {
    $devs = @(Get-EspDevices | Where-Object { $_.Port } | Sort-Object Port -Unique)
    if ($devs.Count) {
        $ui.Esp.Text = ($devs | ForEach-Object { "$($_.Port)  $($_.Chip)" }) -join "`n"
        $ui.EspDot.SetResourceReference([Windows.Shapes.Shape]::FillProperty, 'Accent2')
        if (-not $script:EspSeen -or $announce) {
            Write-Log "ESP32-style serial device on $(($devs.Port) -join ', ')" 'ok'
        }
    } else {
        $ui.Esp.Text = 'No ESP32 USB-serial device detected'
        $ui.EspDot.SetResourceReference([Windows.Shapes.Shape]::FillProperty, 'Muted')
        if ($script:EspSeen) { Write-Log 'ESP32 device disconnected' 'warn' }
    }
    $script:EspSeen = [bool]$devs.Count
    return $devs.Count
}

# ---------------------------------------------------------------- buttons ---

$ui.DevStart.Add_Click({
    Write-Log 'DEV TOOL START'
    foreach ($name in $Config.devStartApps) {
        $app = $Config.apps | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if ($app) { [void](Start-App $app) } else { Write-Log "devStartApps: '$name' is not in apps list" 'warn' }
    }
    if ((Update-Esp $true) -gt 0) {
        if ($Config.autoOpenGhostEspOnDevStart) { Open-GhostEsp }
    } else {
        Write-Log 'No ESP32 detected - skipping Ghost ESP panel'
    }
})

$ui.NetRefresh.Add_Click({ Update-Network; Write-Log 'Network info refreshed' })
$ui.FlushDns.Add_Click({
    try {
        Clear-DnsClientCache -ErrorAction Stop
        Write-Log 'DNS resolver cache flushed' 'ok'
    } catch {
        Write-Log "Flush DNS failed: $($_.Exception.Message)" 'err'
    }
})
$ui.PingBtn.Add_Click({
    $target = $ui.PingHost.Text.Trim()
    if (-not $target) { return }
    Write-Log "Pinging $target ..."
    $Window.Dispatcher.Invoke([action]{}, 'Render')   # repaint before blocking
    # PS 5.1 only returns successful replies; PS 7 also returns failed ones with a Status
    $replies = @(Test-Connection -ComputerName $target -Count 4 -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSObject.Properties['Status'] -or "$($_.Status)" -eq 'Success' })
    if ($replies.Count) {
        $ms = $replies | ForEach-Object {
            if ($_.PSObject.Properties['ResponseTime']) { $_.ResponseTime } else { $_.Latency }
        } | Measure-Object -Average -Minimum -Maximum
        Write-Log ('{0}: {1}/4 replies, min/avg/max {2}/{3:0}/{4} ms' -f $target, $replies.Count, $ms.Minimum, $ms.Average, $ms.Maximum) 'ok'
    } else {
        Write-Log "${target}: no reply" 'warn'
    }
})
$ui.EspScan.Add_Click({ [void](Update-Esp $true) })
$ui.GhostEsp.Add_Click({ Open-GhostEsp })

# ----------------------------------------------------------------- timers ---

$clock = New-Object Windows.Threading.DispatcherTimer
$clock.Interval = [TimeSpan]::FromSeconds(1)
$clock.Add_Tick({ $ui.Clock.Text = Get-Date -Format 'HH:mm:ss' })

$stats = New-Object Windows.Threading.DispatcherTimer
$stats.Interval = [TimeSpan]::FromSeconds(3)
$stats.Add_Tick({ Update-Stats })

$usb = New-Object Windows.Threading.DispatcherTimer
$usb.Interval = [TimeSpan]::FromSeconds(5)
$usb.Add_Tick({ [void](Update-Esp) })

$Window.Add_ContentRendered({
    $ui.Clock.Text = Get-Date -Format 'HH:mm:ss'
    Update-Stats
    Update-Network
    [void](Update-Esp)
    $clock.Start(); $stats.Start(); $usb.Start()
    Write-Log "Loaded $($Config.apps.Count) apps and $($Config.sites.Count) sites from config.json"
})

$Window.Add_Closed({ $clock.Stop(); $stats.Stop(); $usb.Stop() })

[void]$Window.ShowDialog()
