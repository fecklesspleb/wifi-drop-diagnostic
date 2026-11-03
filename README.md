# wifi-drop-diagnostic

A small, read-only PowerShell file for Windows 10/11 Wi-Fi that keeps dropping. It answers three questions before you start resetting things: **what does the adapter say right now, what did Windows log when it dropped, and is the drop between your PC and your router, or past the router?**

> **Test status, honestly:** the script parses cleanly, PSScriptAnalyzer reports 0 findings, and the Pester tests in `tests/` pass. All of that was done with **PowerShell 7 on Linux, using sample text and mocks**. **It has not yet been run on Windows 10/11 or on Windows PowerShell 5.1**, so the `netsh`, event-log and adapter functions have never seen real Windows output. It changes no settings, so the worst case is a wrong or empty report.

## What it does

Dot-sourcing `wifi-drop-diagnostic.ps1` loads five functions. Nothing runs until you call one, and none of them changes a setting.

| Function | Admin? | What it does |
|---|---|---|
| `Get-WifiStatus` | No | Runs `netsh wlan show interfaces` and returns the state, SSID, access point (BSSID), band, channel, radio type, receive/transmit rate and signal % as objects. |
| `Get-WifiDisconnectEvent [-Days 7]` | No | Reads disconnect events (ID 8003) from **Applications and Services Logs > Microsoft > Windows > WLAN-AutoConfig > Operational** and returns the time, SSID, adapter, reason text and reason code. |
| `Get-WifiAdapterPowerSetting` | **Yes** | For each physical Wi-Fi adapter, shows `AllowComputerToTurnOffDevice` from `Get-NetAdapterPowerManagement`, the setting behind Device Manager's "Allow the computer to turn off this device to save power". |
| `Watch-WifiConnection -Path <csv>` | No | Every few seconds (default 5, for 30 minutes) records the Wi-Fi state, SSID, BSSID, signal, whether your router (default gateway) answered a ping and, if you pass `-InternetHost`, whether that address answered too. Appends to a CSV. |
| `Measure-WifiLog -Path <csv>` | No | Summarises the CSV: samples, router failures, "router fine but internet failed" samples, lowest signal, access-point changes, and a one-line verdict. |

The only file it writes is the CSV you name. The only network traffic is one ping per sample to your router, plus one to `-InternetHost` if you give it one.

What it does **not** do: fix anything. No resets, no driver changes, no DNS changes, no power-setting changes. The verdict tells you where to look; Microsoft's [Fix Wi-Fi connection issues in Windows](https://support.microsoft.com/en-us/windows/experience/connectivity-networking/fix-wi-fi-connection-issues-in-windows) lists the fixes, in order.

## How to run it

1. Download `wifi-drop-diagnostic.ps1` and read it (about 240 lines of plain text).
2. Open PowerShell. A normal window is enough for everything except `Get-WifiAdapterPowerSetting`, which needs **Run as administrator**.
3. If PowerShell refuses to run scripts, allow them for this window only, and unblock the file you have read:

   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
   Unblock-File -Path .\wifi-drop-diagnostic.ps1
   ```

4. Load the functions (note the leading dot and space) and look at the link and recent drops:

   ```powershell
   . .\wifi-drop-diagnostic.ps1
   Get-WifiStatus
   Get-WifiDisconnectEvent -Days 7 | Format-Table TimeCreated, SSID, Reason -AutoSize
   ```

5. Log while the problem happens, then read the summary:

   ```powershell
   Watch-WifiConnection -Minutes 30 -InternetHost 1.1.1.1 -Path .\wifi-log.csv
   Measure-WifiLog -Path .\wifi-log.csv
   ```

   `1.1.1.1` is just an example of a public address that answers pings; use any you trust. Leave `-InternetHost` out to ping only your router. Stop early with Ctrl+C; the rows logged so far stay in the CSV.

## Reading the verdict

- **Router failures above zero:** your PC lost contact with your own router. That points at the Wi-Fi link: weak signal (check `LowestSignal`), adapter power saving, the driver, or the router itself.
- **Router always answered, internet address didn't:** the Wi-Fi link was fine; look at the router's internet side or your provider.
- **No failures:** the log didn't catch a drop. Run it for longer, or while the problem is happening.
- **Access-point changes:** the BSSID changed, which is normal with mesh systems or two-band routers, but worth comparing with the drop times.

## Limits

- `Get-WifiStatus` parses the **English** layout of `netsh wlan show interfaces`. On another display language the labels may not match; if so, it warns and returns nothing, and you can read the `netsh` output directly.
- Sleep and resume may not log event 8003, so an empty event list doesn't prove there were no drops.
- One ping every few seconds can miss very short drops, and some routers ignore pings. If the router never answers even when everything works, this logger can't help on that network.
- If you have more than one Wi-Fi adapter, the logger records the first one `netsh` lists.

## Tests

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error,Warning,Information
Invoke-Pester -Path .\tests
```

The tests use hand-written sample text in the English `netsh wlan show interfaces` layout, a sample event XML in the layout of event 8003, mocks for `Get-WinEvent`, ping and `Start-Sleep`, and Pester's `TestDrive:`. They never call `netsh`, the event log or a real adapter. They check: the parser reads one or two interfaces and both the `AP BSSID` and `BSSID` labels; the event reader asks only for event 8003 in the right log and pulls SSID, reason and reason code; the logger writes one row per sample and pings the right targets; the summary blames the Wi-Fi link, the internet side or nothing, correctly; and the file contains no command that changes network settings.

Last run (Nov 2, 2026, ET): PowerShell 7.4.6 on Linux, PSScriptAnalyzer 1.25.0: 0 findings in the script and in `tests/`, and 0 findings from the Windows PowerShell 5.1 syntax-compatibility rule; Pester 6.2.0: 12 passed, 0 failed. Not run on Windows yet. If you run it on Windows 10/11, an issue saying what happened is welcome.

## Sources (Microsoft)

- Fix Wi-Fi connection issues in Windows: https://support.microsoft.com/en-us/windows/experience/connectivity-networking/fix-wi-fi-connection-issues-in-windows
- Wireless network connectivity issues troubleshooting (`netsh wlan` commands, the WLAN-AutoConfig Operational log, `netsh wlan show wlanreport`): https://learn.microsoft.com/en-us/troubleshoot/windows-client/networking/wireless-network-connectivity-issues-troubleshooting
- Get-NetAdapterPowerManagement (needs an elevated session): https://learn.microsoft.com/en-us/powershell/module/netadapter/get-netadapterpowermanagement
- Event IDs 8001 (connected) and 8003 (disconnected) in that log, as described on Microsoft Q&A: https://learn.microsoft.com/en-us/answers/questions/5552995/can-event-viewer-log-which-network-i-was-connected

## License and disclaimers

MIT (see `LICENSE`). Provided as-is, without warranty. This script changes nothing, but the fixes you try afterwards might; back up first.

This code and README were written with AI assistance.

Not affiliated with or endorsed by Microsoft. Windows and PowerShell are trademarks of the Microsoft group of companies.
