<#
.SYNOPSIS
    Read-only diagnostics for Wi-Fi that keeps dropping on Windows 10/11:
    current link details, recent disconnect events with their reasons, the
    adapter's power-saving setting, and a ping logger that tells a Wi-Fi drop
    apart from an internet-provider drop.

.DESCRIPTION
    Dot-source this file to load five functions. None of them changes any
    setting; the only thing written to disk is the CSV log you ask
    Watch-WifiConnection to create.

      Get-WifiStatus              Parses `netsh wlan show interfaces`.
      Get-WifiDisconnectEvent     Disconnect events (ID 8003) from the
                                  WLAN-AutoConfig Operational log, with reasons.
      Get-WifiAdapterPowerSetting Shows whether Windows may turn the Wi-Fi
                                  adapter off to save power.
      Watch-WifiConnection        Pings your router (and optionally an internet
                                  address) every few seconds and logs to CSV.
      Measure-WifiLog             Summarises that CSV and says where the drops are.

    Test status: parsed and checked with PSScriptAnalyzer and Pester tests
    using sample text and mocks, under PowerShell 7 on Linux.
    NOT yet run on Windows 10/11 or on Windows PowerShell 5.1.

    Written with AI assistance. MIT License (see LICENSE).
    Not affiliated with or endorsed by Microsoft.

.EXAMPLE
    . .\wifi-drop-diagnostic.ps1
    Get-WifiStatus

.EXAMPLE
    Get-WifiDisconnectEvent -Days 7 | Format-Table TimeCreated, SSID, Reason -AutoSize

.EXAMPLE
    Watch-WifiConnection -Minutes 30 -InternetHost 1.1.1.1 -Path .\wifi-log.csv
    Measure-WifiLog -Path .\wifi-log.csv
#>

# --- Part 1: what the adapter says right now ------------------------------

function ConvertFrom-WlanInterfaceText {
    <# Turns the English text of `netsh wlan show interfaces` into objects, one per interface. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string[]] $Text)

    $map = [ordered]@{
        'Name' = 'Name'; 'Description' = 'Description'; 'State' = 'State'
        'SSID' = 'SSID'; 'AP BSSID' = 'BSSID'; 'BSSID' = 'BSSID'
        'Radio type' = 'RadioType'; 'Authentication' = 'Authentication'
        'Band' = 'Band'; 'Channel' = 'Channel'
        'Receive rate (Mbps)' = 'ReceiveMbps'; 'Transmit rate (Mbps)' = 'TransmitMbps'
        'Signal' = 'SignalPercent'; 'Profile' = 'Profile'
    }
    $current = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch '^\s+(?<key>[^:]+?)\s+:\s?(?<value>.*)$') { continue }
        $key = $Matches.key.Trim()
        $value = $Matches.value.Trim()
        if ($key -eq 'Name') {
            if ($current) { [pscustomobject]$current }
            $current = [ordered]@{}
            foreach ($p in ($map.Values | Select-Object -Unique)) { $current[$p] = $null }
        }
        if ($null -eq $current -or -not $map.Contains($key)) { continue }
        $prop = $map[$key]
        switch ($prop) {
            'SignalPercent' { $current[$prop] = [int]($value -replace '[^\d]', '') }
            { $_ -in 'Channel', 'ReceiveMbps', 'TransmitMbps' } {
                $n = 0.0
                if ([double]::TryParse($value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { $current[$prop] = $n }
            }
            default { $current[$prop] = $value }
        }
    }
    if ($current) { [pscustomobject]$current }
}

function Get-WifiStatus {
    <# Read-only. Runs `netsh wlan show interfaces` and parses it. #>
    [CmdletBinding()]
    param()
    if (-not (Get-Command -Name netsh.exe -ErrorAction SilentlyContinue)) {
        throw 'netsh.exe was not found. This function needs Windows.'
    }
    $raw = & netsh.exe wlan show interfaces
    $found = 0
    foreach ($interface in (ConvertFrom-WlanInterfaceText -Text $raw)) { $found++; $interface }
    if ($found -eq 0) {
        Write-Warning 'No Wi-Fi interface was found in the netsh output. If your Windows display language is not English, run "netsh wlan show interfaces" and read it directly.'
    }
}

# --- Part 2: what Windows logged when it dropped --------------------------

function ConvertFrom-WlanEventXml {
    <# Pulls SSID, reason text and reason code out of one WLAN-AutoConfig event's XML. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Xml, [datetime] $TimeCreated, [int] $Id)
    $doc = [xml]$Xml
    $data = @{}
    foreach ($d in $doc.Event.EventData.Data) { $data[[string]$d.Name] = [string]$d.'#text' }
    [pscustomobject]@{
        TimeCreated = $TimeCreated
        Id          = $Id
        SSID        = $data['SSID']
        Adapter     = $data['InterfaceDescription']
        Reason      = $data['Reason']
        ReasonCode  = $data['ReasonCode']
    }
}

function Get-WifiDisconnectEvent {
    <# Read-only. Disconnect events (ID 8003) from the last -Days days, newest first. #>
    [CmdletBinding()]
    param([ValidateRange(1, 90)][int] $Days = 7)
    $filter = @{
        LogName   = 'Microsoft-Windows-WLAN-AutoConfig/Operational'
        Id        = 8003
        StartTime = (Get-Date).AddDays(-$Days)
    }
    $events = @(Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue)
    foreach ($e in $events) {
        ConvertFrom-WlanEventXml -Xml $e.ToXml() -TimeCreated $e.TimeCreated -Id $e.Id
    }
}

# --- Part 3: the power-saving setting -------------------------------------

function Get-WifiAdapterPowerSetting {
    <# Read-only. Needs an administrator window (Get-NetAdapterPowerManagement requires it). #>
    [CmdletBinding()]
    param()
    $wifi = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.PhysicalMediaType -eq 'Native 802.11' })
    foreach ($a in $wifi) {
        $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue
        $allow = if ($pm) { [string]$pm.AllowComputerToTurnOffDevice } else { 'Not reported' }
        [pscustomobject]@{
            Name                         = $a.Name
            Description                  = $a.InterfaceDescription
            Status                       = [string]$a.Status
            AllowComputerToTurnOffDevice = $allow
        }
    }
}

# --- Part 4: a ping log that separates Wi-Fi drops from internet drops ----

function Get-DefaultGateway {
    [CmdletBinding()]
    param()
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object -Property RouteMetric | Select-Object -First 1
    if ($route) { $route.NextHop }
}

function Test-PingOnce {
    <# One ICMP echo with a timeout. Returns $true or $false, never throws. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string] $Target, [int] $TimeoutMs = 1000)
    $ping = New-Object System.Net.NetworkInformation.Ping
    try { return ($ping.Send($Target, $TimeoutMs).Status -eq 'Success') }
    catch { return $false }
    finally { $ping.Dispose() }
}

function Watch-WifiConnection {
    <#
      Samples every -IntervalSeconds for -Minutes and appends rows to -Path (CSV).
      -InternetHost is optional; without it only your router is pinged.
      Pass -Samples to stop after a fixed number of samples instead.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [ValidateRange(1, 1440)][int] $Minutes = 30,
        [ValidateRange(1, 300)][int] $IntervalSeconds = 5,
        [int] $Samples = 0,
        [string] $Gateway,
        [string] $InternetHost
    )
    if (-not $Gateway) { $Gateway = Get-DefaultGateway }
    if (-not $Gateway) { throw 'No default gateway found. Connect to Wi-Fi first, or pass -Gateway.' }
    if ($Samples -le 0) { $Samples = [math]::Max(1, [int](($Minutes * 60) / $IntervalSeconds)) }
    $haveNetsh = [bool](Get-Command -Name netsh.exe -ErrorAction SilentlyContinue)

    for ($i = 0; $i -lt $Samples; $i++) {
        $wifi = $null
        if ($haveNetsh) { $wifi = Get-WifiStatus -WarningAction SilentlyContinue | Select-Object -First 1 }
        $row = [pscustomobject]@{
            Time       = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
            State      = if ($wifi) { $wifi.State } else { '' }
            SSID       = if ($wifi) { $wifi.SSID } else { '' }
            BSSID      = if ($wifi) { $wifi.BSSID } else { '' }
            Signal     = if ($wifi) { $wifi.SignalPercent } else { '' }
            GatewayOk  = Test-PingOnce -Target $Gateway
            InternetOk = if ($InternetHost) { Test-PingOnce -Target $InternetHost } else { '' }
        }
        $row | Export-Csv -LiteralPath $Path -Append -NoTypeInformation -Encoding UTF8
        $row
        if ($i -lt $Samples - 1) { Start-Sleep -Seconds $IntervalSeconds }
    }
}

function Measure-WifiLog {
    <# Summarises a CSV written by Watch-WifiConnection. Pure: reads the file, changes nothing. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) { throw "No rows in $Path." }

    $gwFail  = @($rows | Where-Object { $_.GatewayOk -eq 'False' })
    $hasNet  = @($rows | Where-Object { $_.InternetOk -in 'True', 'False' })
    $netOnly = @($rows | Where-Object { $_.GatewayOk -eq 'True' -and $_.InternetOk -eq 'False' })
    $signals = @($rows | Where-Object { $_.Signal -match '^\d+$' } | ForEach-Object { [int]$_.Signal })
    $bssids  = @($rows | Where-Object { $_.BSSID } | ForEach-Object { $_.BSSID })
    $roams = 0
    for ($i = 1; $i -lt $bssids.Count; $i++) { if ($bssids[$i] -ne $bssids[$i - 1]) { $roams++ } }

    $verdict = if ($gwFail.Count -gt 0) {
        'Your PC lost contact with your own router. Look at the Wi-Fi link: signal, adapter power saving, driver, or the router itself.'
    } elseif ($netOnly.Count -gt 0) {
        'The router always answered but the internet address did not. Look at the router''s internet side or your provider.'
    } elseif ($hasNet.Count -eq 0) {
        'No drops to your router. Add -InternetHost to also test past the router.'
    } else {
        'No drops in this log. Leave it running for longer, or while the problem is happening.'
    }

    [pscustomobject]@{
        Samples              = $rows.Count
        From                 = $rows[0].Time
        To                   = $rows[-1].Time
        GatewayFailures      = $gwFail.Count
        InternetOnlyFailures = $netOnly.Count
        LowestSignal         = if ($signals.Count) { ($signals | Measure-Object -Minimum).Minimum } else { $null }
        AccessPointChanges   = $roams
        Verdict              = $verdict
    }
}
