# Bruce Command Panel

A desktop web command panel for [Bruce](https://github.com/pr3y/Bruce)
firmware running on an ESP32-S3. Opens in **Opera** (or any modern browser),
scans your local network for the Bruce device, and drives it over HTTP + WebSocket.

Dark palette: **black background, gray panels, red danger, green primary.**

Sidebar nav for modules, multi-column card grid, persistent bottom log and CLI
with command history (↑/↓) and hotkeys (`Ctrl+K` to focus, `Ctrl+L` to clear).

## Features

- **Auto-scan** the local subnet (WebRTC-derived) for a Bruce device on ports 80 / 8080 / 8888
- **Manual IP entry** (defaults to `192.168.4.1` for Bruce's AP mode)
- **Remembers previously-found devices** in `localStorage`
- **Demo Mode** — full UI with simulated Bruce responses, no hardware required
- **Persistent bottom log** (collapsible) + always-visible CLI with ↑/↓ history
- Six sidebar modules:
  - **📡 Wi-Fi** — scan, sniff, deauth, beacon spam, evil portal
  - **🔵 Bluetooth** — BLE scan, AirTag/Flipper finder, SourApple / Samsung / Microsoft / Google spam, BLE HID
  - **📻 SubGHz** — RF scan, record, replay, jam (CC1101)
  - **🔴 Infrared** — TV-B-Gone, record, send saved files
  - **💳 RFID/NFC** — read/write/emulate for 125 kHz and 13.56 MHz
  - **⚙️ System** — info, battery, brightness, files, Wi-Fi connect, reboot, raw CLI
- **Live serial log** with color-coded input/output/errors
- **Parsed AP list** with RSSI bars, encryption tags, per-row deauth button
- **Toast notifications** and iOS safe-area handling

## Usage

1. Boot Bruce on your ESP32-S3. Either connect Bruce to your Wi-Fi or use its AP.
2. Serve `index.html` from anywhere — GitHub Pages, `python3 -m http.server`, or open the file directly.
3. Open the page in **Opera** (or Chrome/Safari on iOS).
4. Tap **Scan for Bruce** or enter the IP manually. To try the UI first, tap **Launch Demo Mode**.

## Transport

The panel expects Bruce to respond on one of:

- `ws://<ip>:<port>/ws` — WebSocket, preferred (bidirectional streaming)
- `POST http://<ip>:<port>/cmd` with `Content-Type: text/plain` — HTTP fallback

Bruce's stock web interface serves a file browser, not a `/cmd` endpoint —
you'll need to add a small handler to `WebInterface.cpp` (or the equivalent
in your Bruce fork) that forwards the POST body to the serial command
dispatcher. Command strings match the ones printed under each button.

## Notes

- Commands mirror common Bruce CLI verbs but names differ across forks — edit
  `data-cmd` attributes in `index.html` to match your build.
- If auto-scan can't detect your subnet (private-IP WebRTC blocked in some
  browsers), fall back to the manual IP field.
