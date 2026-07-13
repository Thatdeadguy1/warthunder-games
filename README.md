# Bruce Command Panel

A single-file browser command panel for controlling [Bruce](https://github.com/pr3y/Bruce)
firmware on an ESP32-S3 over USB, from **Opera** (or any Chromium-based browser).

Uses the [Web Serial API](https://developer.mozilla.org/docs/Web/API/Web_Serial_API)
to talk directly to Bruce's serial CLI — no drivers, no companion app.

## Features

- **One-click quick commands** grouped by category (System, WiFi, Bluetooth, RF/IR/NFC, Utilities)
- **Live terminal** with color-coded input/output
- **Command history** (↑/↓) persisted in `localStorage`
- **Selectable baud rate** (defaults to 115200)
- **RX/TX byte counter** and connection status indicator
- **Ctrl+L** to clear the terminal
- Auto-detects Web Serial support and shows guidance if disabled

## Usage

1. Flash Bruce onto your ESP32-S3 and connect it over USB.
2. Open `index.html` in Opera / Chrome / Edge.
   - Serve it locally (`python3 -m http.server`) or open from `file://` — both work.
3. Click **CONNECT** and pick your ESP32-S3 serial device.
4. Use the sidebar buttons or type commands directly.

### Enabling Web Serial in Opera

If the panel says "Web Serial unsupported", go to:

```
opera://flags/#enable-experimental-web-platform-features
```

Set it to **Enabled** and restart Opera.

## Notes

The sidebar commands are a starting set of common Bruce CLI verbs. Actual
command names / arguments may differ across Bruce versions — edit the
`data-cmd` attributes in `index.html` to match your firmware build.
