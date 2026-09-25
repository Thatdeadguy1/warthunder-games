# Dashboard for Windows

A native Windows dashboard written in PowerShell + WPF. You don't need to install anything: it runs on the Windows PowerShell 5.1 that comes with Windows 10/11. There's also a [Mac version](../mac-dashboard).

**Theme:** Birch Dark. The background is bark-black, the main colour is birch-bark cream and the second colour is red. The Windows title bar is set to dark to match (Windows 10 20H1+ and Windows 11).

## What it does

- **DEV TOOL START**: opens Opera, Windows Terminal and Wireshark in one click. If an ESP32 USB-serial device is plugged in, it also opens your Ghost ESP control panel.
- **App tiles**: click to launch. A tile is greyed out ("not installed") when none of its paths exist. Clicking it logs every path it checked.
- **Web tiles**: cyber training, tools, vuln intel and hardware docs. They open in Opera, or in your default browser if Opera isn't found.
- **System panel**: CPU %, RAM, uptime. Refreshes every 3 s.
- **Network panel**: IPv4 per adapter, default gateway, DNS servers, a Flush DNS button and a quick ping box.
- **ESP32 / USB serial panel**: rescans every 5 s and lists COM ports whose USB vendor ID matches:
  - `303A` Espressif native USB (ESP32-S3/C3/C6)
  - `10C4` Silicon Labs CP210x
  - `1A86` WCH CH340 / CH910x

  This is a heuristic. Other boards that use CP210x or CH340 chips (plenty of Arduino clones, for example) will show up too.

## Run it

Double-click `Launch-Dashboard.bat`, or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\Dashboard.ps1
```

## Customise

Everything lives in `config.json`:

| key | meaning |
| --- | --- |
| `apps[].paths` | candidate locations, tried in order. `%ENV%` variables are expanded. A bare name like `wt.exe` is looked up on PATH and in the App Paths registry key. |
| `apps[].args` | optional launch arguments |
| `apps[].admin` | `true` launches it elevated (UAC prompt) |
| `sites[]` | `name`, `group`, `url`. Tiles are grouped by `group` |
| `devStartApps` | app names that DEV TOOL START opens |
| `ghostEspPanel` | path to your Ghost ESP HTML panel (default `%USERPROFILE%\Downloads\ghostesp_9.html`) |
| `browser` | name of the app entry that opens links (falls back to the system default) |

The colours are in the `$Theme` block near the top of `Dashboard.ps1`.
