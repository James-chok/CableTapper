import Foundation

@MainActor
public final class ToolRouter {
    public let session: PhoneSession

    public init(session: PhoneSession) {
        self.session = session
    }

    public static let toolNames: [String] = [
        "status", "screenshot", "wait", "find_text",
        "tap", "tap_text", "double_tap", "long_press", "drag", "flick",
        "type_text", "press_key",
        "home", "back", "dismiss", "open_app",
    ]

    public func call(_ call: ToolCall) async -> ToolResult {
        switch call.name {
        case "status":
            return .ok(session.statusText())
        case "screenshot":
            return await screenshot()
        case "wait":
            return await wait(ms: call.arguments["ms"]?.intValue ?? 1000)
        case "find_text":
            return await findText(
                query: call.arguments["query"]?.stringValue,
                exact: call.arguments["exact"]?.boolValue ?? false
            )
        case "tap":
            return await tap(x: call.arguments["x"]?.intValue, y: call.arguments["y"]?.intValue, settleMs: call.arguments["settle_ms"]?.intValue)
        case "tap_text":
            return await tapText(
                text: call.arguments["text"]?.stringValue,
                exact: call.arguments["exact"]?.boolValue ?? true,
                index: call.arguments["index"]?.intValue ?? 0,
                settleMs: call.arguments["settle_ms"]?.intValue
            )
        case "double_tap":
            return await doubleTap(x: call.arguments["x"]?.intValue, y: call.arguments["y"]?.intValue, settleMs: call.arguments["settle_ms"]?.intValue)
        case "long_press":
            return await longPress(
                x: call.arguments["x"]?.intValue,
                y: call.arguments["y"]?.intValue,
                durationMs: call.arguments["duration_ms"]?.intValue ?? 800,
                settleMs: call.arguments["settle_ms"]?.intValue
            )
        case "drag":
            return await drag(args: call.arguments)
        case "flick":
            return await flick(args: call.arguments)
        case "type_text":
            return await typeText(call.arguments["text"]?.stringValue, settleMs: call.arguments["settle_ms"]?.intValue)
        case "press_key":
            return await pressKey(args: call.arguments)
        case "home":
            return await session.withSettledScreenshot(settleMs: call.arguments["settle_ms"]?.intValue, actionNote: "home") {
                try await session.gestures.home()
            }
        case "back":
            return await session.withSettledScreenshot(settleMs: call.arguments["settle_ms"]?.intValue, actionNote: "back") {
                try await session.gestures.back()
            }
        case "dismiss":
            return await session.withSettledScreenshot(settleMs: call.arguments["settle_ms"]?.intValue, actionNote: "dismiss") {
                try await session.gestures.dismiss()
            }
        case "open_app":
            guard let name = call.arguments["name"]?.stringValue, !name.isEmpty else {
                return .fail("Missing name")
            }
            return await session.withSettledScreenshot(settleMs: call.arguments["settle_ms"]?.intValue, actionNote: "open_app \(name)") {
                try await session.gestures.openApp(named: name)
            }
        default:
            return .fail("Unknown tool: \(call.name)")
        }
    }

    private func screenshot() async -> ToolResult {
        do {
            try await session.startScreen()
            let shot = try await session.screen.waitForSettle(timeoutMs: session.defaultSettleMs)
            session.gestures.updateScreenSize(width: shot.width, height: shot.height)
            let settleNote = shot.settled ? "screen settled" : "screen still moving"
            return .ok("Screenshot \(shot.width)x\(shot.height) px. \(settleNote).", jpeg: shot.jpegData)
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    private func wait(ms: Int) async -> ToolResult {
        let clamped = min(max(ms, 0), 120_000)
        try? await Task.sleep(nanoseconds: UInt64(clamped) * 1_000_000)
        return await screenshot()
    }

    private func findText(query: String?, exact: Bool) async -> ToolResult {
        do {
            try await session.startScreen()
            guard let image = session.screen.currentCGImage() else {
                throw CableTapperError.screenUnavailable("no frame")
            }
            let lines = try await VisionOCR.recognize(in: image, query: query, exact: exact)
            let size = session.screen.frameSize
            var out = "screenshot \(size.width)x\(size.height), \(lines.count) lines:\n"
            for line in lines {
                out += "\"\(line.text)\" center=(\(line.centerX),\(line.centerY)) box=(\(line.boxX),\(line.boxY),\(line.boxW),\(line.boxH))\n"
            }
            return .ok(out)
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    private func tap(x: Int?, y: Int?, settleMs: Int?) async -> ToolResult {
        guard let x, let y else { return .fail("tap requires x and y") }
        return await session.withSettledScreenshot(settleMs: settleMs, actionNote: "tap (\(x),\(y))") {
            try await session.startScreen()
            try await session.gestures.tap(x: Double(x), y: Double(y))
        }
    }

    private func tapText(text: String?, exact: Bool, index: Int, settleMs: Int?) async -> ToolResult {
        guard let text, !text.isEmpty else { return .fail("tap_text requires text") }
        do {
            try await session.startScreen()
            guard let image = session.screen.currentCGImage() else {
                throw CableTapperError.screenUnavailable("no frame")
            }
            let lines = try await VisionOCR.recognize(in: image, query: text, exact: exact)
            guard index >= 0, index < lines.count else {
                throw CableTapperError.textNotFound(text)
            }
            let line = lines[index]
            return await session.withSettledScreenshot(settleMs: settleMs, actionNote: "tap_text \"\(line.text)\"") {
                try await session.gestures.tap(x: Double(line.centerX), y: Double(line.centerY))
            }
        } catch {
            let jpeg = try? session.screen.captureJPEG().jpegData
            return .fail(error.localizedDescription, jpeg: jpeg)
        }
    }

    private func doubleTap(x: Int?, y: Int?, settleMs: Int?) async -> ToolResult {
        guard let x, let y else { return .fail("double_tap requires x and y") }
        return await session.withSettledScreenshot(settleMs: settleMs, actionNote: "double_tap (\(x),\(y))") {
            try await session.gestures.doubleTap(x: Double(x), y: Double(y))
        }
    }

    private func longPress(x: Int?, y: Int?, durationMs: Int, settleMs: Int?) async -> ToolResult {
        guard let x, let y else { return .fail("long_press requires x and y") }
        return await session.withSettledScreenshot(settleMs: settleMs, actionNote: "long_press (\(x),\(y)) \(durationMs)ms") {
            try await session.gestures.longPress(x: Double(x), y: Double(y), durationMs: durationMs)
        }
    }

    private func drag(args: [String: ToolValue]) async -> ToolResult {
        guard
            let fromX = args["from_x"]?.intValue,
            let fromY = args["from_y"]?.intValue,
            let toX = args["to_x"]?.intValue,
            let toY = args["to_y"]?.intValue
        else {
            return .fail("drag requires from_x, from_y, to_x, to_y")
        }
        let duration = args["duration_ms"]?.intValue ?? 800
        return await session.withSettledScreenshot(settleMs: args["settle_ms"]?.intValue, actionNote: "drag (\(fromX),\(fromY))->(\(toX),\(toY))") {
            try await session.gestures.drag(
                fromX: Double(fromX),
                fromY: Double(fromY),
                toX: Double(toX),
                toY: Double(toY),
                durationMs: duration
            )
        }
    }

    private func flick(args: [String: ToolValue]) async -> ToolResult {
        guard let x = args["x"]?.intValue, let y = args["y"]?.intValue else {
            return .fail("flick requires x and y")
        }
        guard let dirRaw = args["direction"]?.stringValue, let direction = FlickDirection(rawValue: dirRaw) else {
            return .fail("flick requires direction up|down|left|right")
        }
        return await session.withSettledScreenshot(settleMs: args["settle_ms"]?.intValue, actionNote: "flick \(dirRaw) from (\(x),\(y))") {
            try await session.gestures.flick(x: Double(x), y: Double(y), direction: direction)
        }
    }

    private func typeText(_ text: String?, settleMs: Int?) async -> ToolResult {
        guard let text else { return .fail("type_text requires text") }
        return await session.withSettledScreenshot(settleMs: settleMs, actionNote: "type_text") {
            try session.gestures.requireBluetooth()
            try await session.hid.typeASCII(text)
        }
    }

    private func pressKey(args: [String: ToolValue]) async -> ToolResult {
        guard let keyName = args["key"]?.stringValue else { return .fail("press_key requires key") }
        let repeatCount = max(args["repeat"]?.intValue ?? 1, 1)
        let modifiers = parseModifiers(args["modifiers"]?.stringValue)
        guard let key = mapKeyName(keyName) else {
            return .fail("Unsupported key: \(keyName)")
        }
        return await session.withSettledScreenshot(settleMs: args["settle_ms"]?.intValue, actionNote: "press_key \(keyName)") {
            try session.gestures.requireBluetooth()
            for _ in 0 ..< repeatCount {
                await session.hid.tapKey(key, modifiers: modifiers)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    private func parseModifiers(_ raw: String?) -> KeyboardModifiers {
        guard let raw else { return [] }
        // Accept JSON-ish list as comma-separated from CLI, or single names.
        var mods: KeyboardModifiers = []
        let parts = raw
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        for part in parts {
            switch part {
            case "command", "gui", "cmd": mods.insert(.leftGUI)
            case "shift": mods.insert(.leftShift)
            case "control", "ctrl": mods.insert(.leftCtrl)
            case "alternate", "alt", "option": mods.insert(.leftAlt)
            default: break
            }
        }
        return mods
    }

    private func mapKeyName(_ name: String) -> Keycode? {
        switch name.lowercased() {
        case "enter", "return": .return
        case "escape", "esc": .escape
        case "backspace", "delete": .backspace
        case "tab": .tab
        case "space": .space
        case "arrow_up", "up": .upArrow
        case "arrow_down", "down": .downArrow
        case "arrow_left", "left": .leftArrow
        case "arrow_right", "right": .rightArrow
        case "a": .a
        case "c": .c
        case "v": .v
        case "x": .x
        case "z": .z
        default: nil
        }
    }
}
