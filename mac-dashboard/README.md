# Dashboard for macOS

The Mac version of the [Windows dashboard](../windows-dashboard). It has the same layout and the same Birch Dark theme (bark-black background, birch-bark cream, red second colour).

It's a small Python server that uses only the standard library. It listens on `127.0.0.1` and opens the dashboard page in Opera, or in your default browser if Opera isn't found. The page talks to the server to launch apps with `open -a`.

## Run it

Double-click **`Launch Dashboard.command`** in Finder. The Terminal window that opens is the server: close it or press Ctrl+C to stop.

Or run it from Terminal:

```bash
python3 dashboard.py            # add --no-browser to skip opening the page
```

Needs `python3`. If macOS asks to install the Command Line Tools the first time, accept; that's where Apple's `python3` comes from.

The first time you double-click the `.command` file, macOS may block it because it was downloaded. If so, right-click it, choose **Open**, then confirm.

## What it does

- **DEV TOOL START**: opens Opera, Terminal, Termius and Wireshark. If an ESP32 is plugged in, it also opens your Ghost ESP panel (`~/Downloads/ghostesp_9.html`).
- **App tiles**: looks for `<name>.app` in `/Applications`, `~/Applications`, `/System/Applications` and the Utilities folders. Tiles for apps it can't find are greyed out.
- **Web tiles**: the same cyber, vuln-intel and hardware links as the Windows version.
- **System panel**:
  - CPU is the summed `ps` CPU % divided by the number of cores. It's an approximation.
  - RAM is active + wired + compressed pages from `vm_stat`, which is close to Activity Monitor's "Memory Used".
  - Uptime comes from `kern.boottime`.
- **Network panel**:
  - Shows IPv4 addresses from `ifconfig`, the gateway from `route` and DNS servers from `scutil --dns`, plus a ping box.
  - **Flush DNS** runs `dscacheutil -flushcache; killall -HUP mDNSResponder` through the normal macOS admin password prompt.
- **ESP32 panel**:
  - Checks `ioreg` for USB vendor IDs `303A` (Espressif), `10C4` (CP210x) and `1A86` (CH340/CH910x).
  - Lists `/dev/cu.usbmodem*`, `/dev/cu.usbserial*`, `/dev/cu.wchusbserial*` and `/dev/cu.SLAB_USBtoUART*` ports.
  - It's a heuristic: other CP210x/CH340 boards will show up too.

## Security

- The server only binds to `127.0.0.1`.
- It rejects requests with a foreign `Host` header, which protects against DNS rebinding.
- Every API call needs a random token that's regenerated on each start and embedded in the page. Other websites can't read the page, so they can't trigger launches.
- It only opens websites that are listed in `config.json`.

## Customise

Edit `config.json`:
- **apps:** `name`, `group`, `app` (the `.app` bundle name without `.app`), and optionally `paths` for apps installed somewhere unusual.
- **sites:** your website tiles.
- **devStartApps**, **ghostEspPanel**, **browser**, and **port** (default 8765; it picks a free port if that one is busy).

The colours are the `:root` variables at the top of `index.html`.
