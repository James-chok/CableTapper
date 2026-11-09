# CableTapper

Headless Mac → real iPhone bridge for AI agents (Zeptap-like, no UI).

- **Screen** over USB (CoreMediaIO / AVFoundation)
- **Touch & typing** over Bluetooth HID via [BTHIDKit](https://github.com/jqssun/darwin-bt-remote) (AssistiveTouch)
- **MCP** (stdio or loopback HTTP) + thin **CLI**

License: **AGPL-3.0** (required by BTHIDKit). See `LICENSE` and `NOTICE`.

## Requirements

- macOS 14+
- Xcode / Swift 6.1+
- iPhone on a USB cable, unlocked, Trust this computer
- AssistiveTouch enabled on the iPhone (Settings → Accessibility → Touch → AssistiveTouch)
- Bluetooth pairing to this Mac’s CableTapper HID advertisement

## Build

```bash
swift build
# or package a .app so Camera/Bluetooth TCC prompts work reliably:
chmod +x scripts/package-app.sh
./scripts/package-app.sh
```

## Pair once (iPhone — Zeptap-style)

iPhone Settings will **not** show the BLE name `CableTapper` when Mac/iPhone share an Apple ID. Pair with the **Mac Bluetooth name** over Classic HID:

```bash
./scripts/package-app.sh

# keep running
dist/CableTapper.app/Contents/MacOS/cabletapper pair
```

Then on the iPhone:

1. AssistiveTouch **On**
2. Settings → Bluetooth → tap **`James's MacBook Pro`** (your Mac name — printed by `pair`)
3. Also open Mac **System Settings → Bluetooth** while pairing (helps discoverability)

When the terminal prints `Classic HID connected…`, try `cabletapper click` / `type`.

Quit other Mac apps that act as a Bluetooth keyboard for that phone.

## CLI

```bash
cabletapper status
cabletapper screenshot                  # → ./screenshots/screenshot-*.jpg
cabletapper screenshot -o screenshots/phone.jpg
cabletapper tap 120 640
cabletapper type "hello"
cabletapper find-text Settings
cabletapper home
cabletapper open-app Settings
```

## MCP

```bash
# stdio (Claude Code / Cursor)
cabletapper mcp --stdio

# loopback HTTP (Zeptap-shaped URL)
cabletapper mcp --http --port 47801
# → http://127.0.0.1:47801/mcp
```

Example Cursor / Claude MCP config (stdio):

```json
{
  "mcpServers": {
    "cabletapper": {
      "command": "/absolute/path/to/cabletapper",
      "args": ["mcp", "--stdio"]
    }
  }
}
```

## Tools

`status`, `screenshot`, `wait`, `find_text`, `tap`, `tap_text`, `double_tap`, `long_press`, `drag`, `flick`, `type_text`, `press_key`, `home`, `back`, `dismiss`, `open_app`

Coordinates are screenshot pixels (origin top-left). Mutating tools return a settled JPEG when USB capture is available.

## Notes

- Camera + Bluetooth permission prompts are more reliable when running the packaged `.app`.
- Absolute taps use relative HID mouse moves + AssistiveTouch; first tap recalibrates via the top-left corner.
- Auto-enabling AssistiveTouch over USB lockdown is deferred.