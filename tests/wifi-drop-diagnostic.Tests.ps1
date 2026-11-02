# Pester 5+ tests for wifi-drop-diagnostic.ps1.
# They use hand-written sample text in the English layout of
# `netsh wlan show interfaces`, a sample event XML in the layout of
# WLAN-AutoConfig event 8003, mocks, and Pester's TestDrive:. They run on any
# OS and never call netsh, the event log or a real network adapter, so they
# do NOT prove how a real Windows PC behaves.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Get-WinEvent does not exist on Linux, so the test defines a stub for Mock to replace.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters exist only so Mock can match them.')]
param()

BeforeAll {
    . (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'wifi-drop-diagnostic.ps1')

    $script:sample = @'

There is 1 interface on the system:

    Name                   : Wi-Fi
    Description            : Example Wireless Adapter
    GUID                   : 00000000-0000-0000-0000-000000000001
    Physical address       : 00:11:22:33:44:55
    Interface type         : Primary
    State                  : connected
    SSID                   : HomeNet
    AP BSSID               : aa:bb:cc:dd:ee:01
    Band                   : 5 GHz
    Channel                : 36
    Network type           : Infrastructure
    Radio type             : 802.11ax
    Authentication         : WPA2-Personal
    Cipher                 : CCMP
    Connection mode        : Auto Connect
    Receive rate (Mbps)    : 1201
    Transmit rate (Mbps)   : 864.5
    Signal                 : 92%
    Profile                : HomeNet
    QoS MSCS Configured         : 0

    Hosted network status  : Not available
'@

    $script:eventXml = @'
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event">
  <System><EventID>8003</EventID></System>
  <EventData>
    <Data Name="InterfaceGuid">{00000000-0000-0000-0000-000000000001}</Data>
    <Data Name="InterfaceDescription">Example Wireless Adapter</Data>
    <Data Name="ConnectionMode">Automatic connection with a profile</Data>
    <Data Name="ProfileName">HomeNet</Data>
    <Data Name="SSID">HomeNet</Data>
    <Data Name="BSSType">Infrastructure</Data>
    <Data Name="Reason">The network is disconnected because the driver of this adapter reported that it disconnected.</Data>
    <Data Name="ConnectionId">0x1</Data>
    <Data Name="ReasonCode">229377</Data>
  </EventData>
</Event>
'@

    function Write-TestLog {
        param([object[]] $Rows)
        $p = Join-Path $TestDrive ("log-{0}.csv" -f [guid]::NewGuid())
        $Rows | ForEach-Object { [pscustomobject]$_ } | Export-Csv -LiteralPath $p -NoTypeInformation
        $p
    }
}

Describe 'ConvertFrom-WlanInterfaceText' {
    It 'parses one connected interface' {
        $r = @(ConvertFrom-WlanInterfaceText -Text $sample)
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'Wi-Fi'
        $r[0].State | Should -Be 'connected'
        $r[0].SSID | Should -Be 'HomeNet'
        $r[0].BSSID | Should -Be 'aa:bb:cc:dd:ee:01'
        $r[0].SignalPercent | Should -Be 92
        $r[0].Channel | Should -Be 36
        $r[0].TransmitMbps | Should -Be 864.5
        $r[0].Band | Should -Be '5 GHz'
    }

    It 'returns two objects for two interfaces' {
        $two = $sample + "`n" + ($sample -replace 'Name                   : Wi-Fi', 'Name                   : Wi-Fi 2')
        $r = @(ConvertFrom-WlanInterfaceText -Text $two)
        $r.Count | Should -Be 2
        $r[1].Name | Should -Be 'Wi-Fi 2'
    }

    It 'accepts the plain "BSSID" label' {
        $old = $sample -replace 'AP BSSID   ', 'BSSID      '
        (ConvertFrom-WlanInterfaceText -Text $old).BSSID | Should -Be 'aa:bb:cc:dd:ee:01'
    }

    It 'returns nothing for text with no interface' {
        @(ConvertFrom-WlanInterfaceText -Text 'There is no wireless interface on the system.').Count | Should -Be 0
    }
}

Describe 'ConvertFrom-WlanEventXml' {
    It 'reads SSID, adapter, reason and reason code' {
        $t = [datetime]'2026-11-01T08:15:00'
        $r = ConvertFrom-WlanEventXml -Xml $eventXml -TimeCreated $t -Id 8003
        $r.SSID | Should -Be 'HomeNet'
        $r.Adapter | Should -Be 'Example Wireless Adapter'
        $r.Reason | Should -BeLike '*driver*disconnected*'
        $r.ReasonCode | Should -Be '229377'
        $r.TimeCreated | Should -Be $t
    }
}

Describe 'Get-WifiDisconnectEvent' {
    It 'asks only for event 8003 in the WLAN-AutoConfig Operational log' {
        if (-not (Get-Command -Name Get-WinEvent -ErrorAction SilentlyContinue)) {
            function Get-WinEvent { param($FilterHashtable) }
        }
        Mock Get-WinEvent {
            $e = [pscustomobject]@{ TimeCreated = [datetime]'2026-11-01T08:15:00'; Id = 8003 }
            $e | Add-Member ScriptMethod ToXml { $script:eventXml }
            $e
        }
        $r = @(Get-WifiDisconnectEvent -Days 3)
        $r.Count | Should -Be 1
        $r[0].SSID | Should -Be 'HomeNet'
        Should -Invoke Get-WinEvent -Times 1 -Exactly -ParameterFilter {
            $FilterHashtable.LogName -eq 'Microsoft-Windows-WLAN-AutoConfig/Operational' -and $FilterHashtable.Id -eq 8003
        }
    }
}

Describe 'Watch-WifiConnection' {
    It 'writes one CSV row per sample and pings the given gateway' {
        Mock Test-PingOnce { $true }
        Mock Start-Sleep { }
        $p = Join-Path $TestDrive 'watch.csv'
        $null = Watch-WifiConnection -Path $p -Samples 3 -IntervalSeconds 1 -Gateway '192.0.2.1' -InternetHost '198.51.100.1'
        @(Import-Csv -LiteralPath $p).Count | Should -Be 3
        Should -Invoke Test-PingOnce -Times 3 -Exactly -ParameterFilter { $Target -eq '192.0.2.1' }
        Should -Invoke Test-PingOnce -Times 3 -Exactly -ParameterFilter { $Target -eq '198.51.100.1' }
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'leaves InternetOk empty when no -InternetHost is given' {
        Mock Test-PingOnce { $true }
        Mock Start-Sleep { }
        $p = Join-Path $TestDrive 'watch2.csv'
        $null = Watch-WifiConnection -Path $p -Samples 1 -Gateway '192.0.2.1'
        (Import-Csv -LiteralPath $p).InternetOk | Should -Be ''
    }
}

Describe 'Measure-WifiLog' {
    It 'blames the Wi-Fi link when the router stops answering' {
        $p = Write-TestLog @(
            @{ Time = 't1'; State = 'connected'; SSID = 'HomeNet'; BSSID = 'aa'; Signal = '80'; GatewayOk = 'True'; InternetOk = 'True' }
            @{ Time = 't2'; State = 'connected'; SSID = 'HomeNet'; BSSID = 'aa'; Signal = '35'; GatewayOk = 'False'; InternetOk = 'False' }
            @{ Time = 't3'; State = 'connected'; SSID = 'HomeNet'; BSSID = 'bb'; Signal = '70'; GatewayOk = 'True'; InternetOk = 'True' }
        )
        $m = Measure-WifiLog -Path $p
        $m.Samples | Should -Be 3
        $m.GatewayFailures | Should -Be 1
        $m.LowestSignal | Should -Be 35
        $m.AccessPointChanges | Should -Be 1
        $m.Verdict | Should -BeLike '*own router*'
    }

    It 'blames the internet side when only the internet address fails' {
        $p = Write-TestLog @(
            @{ Time = 't1'; State = ''; SSID = ''; BSSID = ''; Signal = ''; GatewayOk = 'True'; InternetOk = 'False' }
            @{ Time = 't2'; State = ''; SSID = ''; BSSID = ''; Signal = ''; GatewayOk = 'True'; InternetOk = 'True' }
        )
        $m = Measure-WifiLog -Path $p
        $m.InternetOnlyFailures | Should -Be 1
        $m.LowestSignal | Should -BeNullOrEmpty
        $m.Verdict | Should -BeLike '*provider*'
    }

    It 'reports no drops on a clean log' {
        $p = Write-TestLog @(@{ Time = 't1'; State = ''; SSID = ''; BSSID = ''; Signal = ''; GatewayOk = 'True'; InternetOk = 'True' })
        (Measure-WifiLog -Path $p).Verdict | Should -BeLike 'No drops in this log*'
    }
}

Describe 'Read-only by construction' {
    It 'contains no command that changes network or adapter settings' {
        $code = Get-Content -Raw -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'wifi-drop-diagnostic.ps1')
        $code | Should -Not -Match '(?i)\b(Set-NetAdapter\w*|Disable-NetAdapter\w*|Enable-NetAdapter\w*|Restart-NetAdapter|Set-DnsClient\w*|Clear-DnsClientCache|Remove-Item|Set-ItemProperty|New-ItemProperty)\b'
        $code | Should -Not -Match '(?i)netsh(\.exe)?\s+(winsock|int|interface|wlan\s+(delete|set|connect|disconnect))'
        $code | Should -Not -Match '(?i)ipconfig'
    }
}
