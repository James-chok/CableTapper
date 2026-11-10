# CableTapper

Mac → real iPhone bridge for AI agents (Zeptap-like).

- **Screen** over USB (CoreMediaIO / AVFoundation)
- **Touch & typing** over Bluetooth LE HID / HOGP (AssistiveTouch; via [BTHIDKit](https://github.com/jqssun/darwin-bt-remote))
- **MCP** on loopback HTTP, started by the app
- A small **SwiftUI** window to advertise and show connected hosts

License: **AGPL-3.0** (required by BTHIDKit). See `LICENSE` and `NOTICE`.

## Architecture

Nothing is installed on the iPhone. Open **CableTapper.app**. It advertises as a Bluetooth keyboard/pointer, serves MCP at `http://127.0.0.1:47801/mcp`, and shows a window for BLE advertising and connected hosts. Agents use the same process through MCP.

```mermaid
flowchart LR
  Agent["Cursor / Claude / Codex"] -->|"MCP HTTP"| App["CableTapper.app"]
  App --> Core["CableTapperCore"]
  subgraph core [CableTapperCore]
    Screen["ScreenCapture"]
    Gestures["GestureEngine"]
    HID["HIDController"]
    OCR["VisionOCR"]
  end
  Screen -->|"USB CoreMediaIO"| iPhone["iPhone"]
  Gestures --> HID
  HID -->|"BLE HOGP"| iPhone
  OCR --> Screen
```

| Channel | Transport | Role |
| --- | --- | --- |
| Screen | USB (CoreMediaIO / AVFoundation) | Live frames, JPEG screenshots, settle detection |
| Touch / type | Bluetooth LE HID over GATT (HOGP) | Relative mouse + keyboard reports → AssistiveTouch |
| Agents | Local MCP (`127.0.0.1:47801/mcp`) | Tools in the running app; mutating calls return a settled screenshot when USB is up |

**Layout**

- `CableTapper.xcodeproj` — macOS app (debug and release)
- `Sources/CableTapperApp` — SwiftUI window
- `Sources/CableTapperMCP` — loopback MCP server
- `Sources/CableTapperCore` — session, capture, BLE HID, gestures, OCR, tool router
- `Vendor/BTHIDKit` — vendored [darwin-bt-remote](https://github.com/jqssun/darwin-bt-remote)

Absolute taps are mapped by tracking a soft cursor and sending relative HID moves (with a corner recalibration). Keep this one app running; it owns the Bluetooth session and the MCP listener.

## Requirements

- macOS 14+
- Xcode / Swift 6.1+
- iPhone on a USB cable, unlocked, Trust this computer
- AssistiveTouch enabled on the iPhone (Settings → Accessibility → Touch → AssistiveTouch)

## Run

Open `CableTapper.xcodeproj` and Run. Xcode builds `CableTapper.app`. Archive that same target to release.

The window starts BLE advertising as **CableTapper**, lists connected hosts, and binds MCP.

On the iPhone:

1. AssistiveTouch **On**
2. Settings → Bluetooth → tap **CableTapper**

Quit other Mac apps that act as a Bluetooth keyboard for that phone.

## MCP

The app listens on `http://127.0.0.1:47801/mcp` while it is open.

```json
{
  "mcpServers": {
    "cabletapper": {
      "url": "http://127.0.0.1:47801/mcp"
    }
  }
}
```

## Tools

`status`, `screenshot`, `wait`, `find_text`, `tap`, `tap_text`, `double_tap`, `long_press`, `drag`, `flick`, `type_text`, `press_key`, `home`, `back`, `dismiss`, `open_app`

Coordinates are screenshot pixels (origin top-left). Mutating tools return a settled JPEG when USB capture is available.

## Notes

- Absolute taps use relative HID mouse moves + AssistiveTouch; first tap recalibrates via the top-left corner.
- Auto-enabling AssistiveTouch over USB lockdown is deferred.
