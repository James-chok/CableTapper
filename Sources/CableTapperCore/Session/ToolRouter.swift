import Foundation

@MainActor
public final class ToolRouter {
    public let session: PhoneSession

    public init(session: PhoneSession) {
        self.session = session
    }

    public static let toolNames: [String] = [
        "status", "screenshot", "wait",
        "tap", "double_tap", "long_press", "drag", "flick",
        "type_text", "press_key",
        "home", "back",
    ]

    public func call(_ call: ToolCall) async -> ToolResult {
        switch call.name {
        case "status":
            return .ok(self.session.statusText())
        case "screenshot":
            return await screenshot()
        case "wait":
            return await wait(ms: call.arguments["ms"]?.intValue ?? 1000)
        case "tap":
            return await tap(x: call.arguments["x"]?.intValue, y: call.arguments["y"]?.intValue, settleMs: call.arguments["settle_ms"]?.intValue)
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
            return await self.session.withSettledScreenshot(settleMs: call.arguments["settle_ms"]?.intValue, actionNote: "home") {
                try await self.session.gestures.home()
            }
        case "back":
            return await self.session.withSettledScreenshot(settleMs: call.arguments["settle_ms"]?.intValue, actionNote: "back") {
                try await self.session.gestures.back()
            }
        default:
            return .fail("Unknown tool: \(call.name)")
        }
    }

    private func screenshot() async -> ToolResult {
        do {
            try await self.session.startScreen()
            let shot = try await self.session.screen.waitForSettle(timeoutMs: self.session.defaultSettleMs)
            self.session.gestures.updateScreenSize(width: shot.width, height: shot.height)
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

    private func tap(x: Int?, y: Int?, settleMs: Int?) async -> ToolResult {
        guard let x, let y else { return .fail("tap requires x and y") }
        return await self.session.withSettledScreenshot(settleMs: settleMs, actionNote: "tap (\(x),\(y))") {
            try await self.session.startScreen()
            try await self.session.gestures.tap(x: Double(x), y: Double(y))
        }
    }

    private func doubleTap(x: Int?, y: Int?, settleMs: Int?) async -> ToolResult {
        guard let x, let y else { return .fail("double_tap requires x and y") }
        return await self.session.withSettledScreenshot(settleMs: settleMs, actionNote: "double_tap (\(x),\(y))") {
            try await self.session.gestures.doubleTap(x: Double(x), y: Double(y))
        }
    }

    private func longPress(x: Int?, y: Int?, durationMs: Int, settleMs: Int?) async -> ToolResult {
        guard let x, let y else { return .fail("long_press requires x and y") }
        return await self.session.withSettledScreenshot(settleMs: settleMs, actionNote: "long_press (\(x),\(y)) \(durationMs)ms") {
            try await self.session.gestures.longPress(x: Double(x), y: Double(y), durationMs: durationMs)
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
        return await self.session.withSettledScreenshot(settleMs: args["settle_ms"]?.intValue, actionNote: "drag (\(fromX),\(fromY))->(\(toX),\(toY))") {
            try await self.session.gestures.drag(
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
        return await self.session.withSettledScreenshot(settleMs: args["settle_ms"]?.intValue, actionNote: "flick \(dirRaw) from (\(x),\(y))") {
            try await self.session.gestures.flick(x: Double(x), y: Double(y), direction: direction)
        }
    }

    private func typeText(_ text: String?, settleMs: Int?) async -> ToolResult {
        guard let text else { return .fail("type_text requires text") }
        return await self.session.withSettledScreenshot(settleMs: settleMs, actionNote: "type_text") {
            try self.session.gestures.requireBluetooth()
            try await self.session.hid.typeASCII(text)
        }
    }

    private func pressKey(args: [String: ToolValue]) async -> ToolResult {
        guard let keyName = args["key"]?.stringValue else { return .fail("press_key requires key") }
        let repeatCount = max(args["repeat"]?.intValue ?? 1, 1)
        let modifiers = parseModifiers(args["modifiers"]?.stringValue)
        guard let key = mapKeyName(keyName) else {
            return .fail("Unsupported key: \(keyName)")
        }
        return await self.session.withSettledScreenshot(settleMs: args["settle_ms"]?.intValue, actionNote: "press_key \(keyName)") {
            try self.session.gestures.requireBluetooth()
            for _ in 0 ..< repeatCount {
                await self.session.hid.tapKey(key, modifiers: modifiers)
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
