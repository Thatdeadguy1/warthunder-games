# Bruce Command Panel

A desktop web command panel for [Bruce](https://github.com/pr3y/Bruce)
firmware running on an ESP32-S3. Opens in **Opera** (or any modern
Chromium-based browser) and drives Bruce's real serial CLI over USB via
the Web Serial API — the same commands you'd type in a terminal
attached to `/dev/ttyUSB0`.

Dark palette: **black background, gray panels, red danger, green primary.**

## Commands

Every button is wired to a command Bruce's serial CLI actually exposes
(verified against `src/core/serial_commands/*.cpp` in the upstream repo).

| Tab           | Commands                                                                     |
| ------------- | ---------------------------------------------------------------------------- |
| **Wi-Fi**     | `wifi status on/off/add`, `webui [noAp]`, `arp`, `listen`, `sniffer`         |
| **SubGHz**    | `rf scan`, `rf rx`, `rf tx <freq> <key> <te> <count>`, `rf tx_from_file`     |
| **Infrared**  | `ir rx`, `ir tx <proto> <addr> <cmd>`, `ir tx_raw <freq> <samples>`, `ir tx_from_file` |
| **GPIO**      | `gpio mode <pin> <0/1>`, `gpio set <pin> <0/1>`, `gpio read <pin>`, `i2c`    |
| **BadUSB**    | `badusb run_from_file`, `badusb run_from_buffer`, `bu`                       |
| **Files**     | `ls`, `cat`, `md5`, `crc32`, `mkdir`, `rm`, `rmdir`, `storage list/stat/rename/copy/free` |
| **Display**   | `screen brightness <n>`, `screen color hex <v>`, `screen color rgb r g b`, `clock`, `date` |
| **System**    | `help`, `info`, `device_info`, `uptime`, `free`, `nav <cmd> <dur>`, `settings`, `js`, `run`, `factory_reset`, `sleep`, `reboot`, `poweroff` |

Menu-only features (BLE spam, Evil Portal, RFID/NFC, TV-B-Gone, deauth,
beacon spam) aren't part of Bruce's serial CLI — drive them through
`nav up/down/sel/esc` in the **System** tab.

## Features

- **Web Serial transport** — plug ESP32-S3 into USB, click connect, done. No firmware changes required.
- **Selectable baud rate** (default 115200, matching Bruce's `Serial.begin`)
- **Demo Mode** — simulated responses so the UI is explorable with no hardware
- **Persistent bottom log** (collapsible) with color-coded I/O
- **Always-visible CLI** with ↑/↓ history persisted to `localStorage`
- **Hotkeys**: `Ctrl+K` focus CLI · `Ctrl+L` clear log
- **RX/TX byte counter** in the sidebar footer
- Detects unplug events (`serial.ondisconnect`) and cleans up

## Usage

1. Flash Bruce onto your ESP32-S3 and plug it into your computer over USB.
2. Open `bruce-panel.html` in **Opera**, Chrome, or Edge (Web Serial only works
   on Chromium-based browsers over `https://` or `file://`).
3. Click **CONNECT USB DEVICE**, pick the ESP32-S3 serial port.
4. Use the sidebar tabs or type raw commands in the CLI.

To explore the UI first, click **LAUNCH DEMO MODE** — every command
returns a plausible simulated response.

### Enabling Web Serial in Opera

If the panel says "Web Serial not available", enable:

```
opera://flags/#enable-experimental-web-platform-features
```

Set it to **Enabled** and restart Opera.
