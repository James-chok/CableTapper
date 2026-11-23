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
            return await self.session.captureSettledScreenshot()
        case "wait":
            return await wait(ms: call.arguments["ms"]?.intValue ?? 1000)
        case "tap":
            return await tap(
                x: call.arguments["x"]?.intValue,
                y: call.arguments["y"]?.intValue,
                settleMs: call.arguments["settle_ms"]?.intValue,
                includeScreenshot: includeScreenshot(call.arguments)
            )
        case "double_tap":
            return await doubleTap(
                x: call.arguments["x"]?.intValue,
                y: call.arguments["y"]?.intValue,
                settleMs: call.arguments["settle_ms"]?.intValue,
                includeScreenshot: includeScreenshot(call.arguments)
            )
        case "long_press":
            return await longPress(
                x: call.arguments["x"]?.intValue,
                y: call.arguments["y"]?.intValue,
                durationMs: call.arguments["duration_ms"]?.intValue ?? 800,
                settleMs: call.arguments["settle_ms"]?.intValue,
                includeScreenshot: includeScreenshot(call.arguments)
            )
        case "drag":
            return await drag(args: call.arguments)
        case "flick":
            return await flick(args: call.arguments)
        case "type_text":
            return await typeText(
                call.arguments["text"]?.stringValue,
                settleMs: call.arguments["settle_ms"]?.intValue,
                includeScreenshot: includeScreenshot(call.arguments)
            )
        case "press_key":
            return await pressKey(args: call.arguments)
        case "home":
            return await self.session.withSettledScreenshot(
                settleMs: call.arguments["settle_ms"]?.intValue,
                actionNote: "home",
                includeScreenshot: includeScreenshot(call.arguments)
            ) {
                try await self.session.gestures.home()
            }
        case "back":
            return await self.session.withSettledScreenshot(
                settleMs: call.arguments["settle_ms"]?.intValue,
                actionNote: "back",
                includeScreenshot: includeScreenshot(call.arguments)
            ) {
                try await self.session.gestures.back()
            }
        default:
            return .fail("Unknown tool: \(call.name)")
        }
    }

    private func wait(ms: Int) async -> ToolResult {
        let clamped = min(max(ms, 0), 120_000)
        try? await Task.sleep(nanoseconds: UInt64(clamped) * 1_000_000)
        return await self.session.captureSettledScreenshot()
    }

    private func tap(x: Int?, y: Int?, settleMs: Int?, includeScreenshot: Bool) async -> ToolResult {
        guard let x, let y else { return .fail("tap requires x and y") }
        return await self.session.withSettledScreenshot(
            settleMs: settleMs,
            actionNote: "tap (\(x),\(y))",
            includeScreenshot: includeScreenshot
        ) {
            let point = try await self.preparePoint(x: x, y: y)
            try await self.session.gestures.tap(x: point.x, y: point.y)
        }
    }

    private func doubleTap(x: Int?, y: Int?, settleMs: Int?, includeScreenshot: Bool) async -> ToolResult {
        guard let x, let y else { return .fail("double_tap requires x and y") }
        return await self.session.withSettledScreenshot(
            settleMs: settleMs,
            actionNote: "double_tap (\(x),\(y))",
            includeScreenshot: includeScreenshot
        ) {
            let point = try await self.preparePoint(x: x, y: y)
            try await self.session.gestures.doubleTap(x: point.x, y: point.y)
        }
    }

    private func longPress(x: Int?, y: Int?, durationMs: Int, settleMs: Int?, includeScreenshot: Bool) async -> ToolResult {
        guard let x, let y else { return .fail("long_press requires x and y") }
        return await self.session.withSettledScreenshot(
            settleMs: settleMs,
            actionNote: "long_press (\(x),\(y)) \(durationMs)ms",
            includeScreenshot: includeScreenshot
        ) {
            let point = try await self.preparePoint(x: x, y: y)
            try await self.session.gestures.longPress(x: point.x, y: point.y, durationMs: durationMs)
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
        return await self.session.withSettledScreenshot(
            settleMs: args["settle_ms"]?.intValue,
            actionNote: "drag (\(fromX),\(fromY))->(\(toX),\(toY))",
            includeScreenshot: includeScreenshot(args)
        ) {
            let from = try await self.preparePoint(x: fromX, y: fromY)
            let to = try await self.preparePoint(x: toX, y: toY)
            try await self.session.gestures.drag(
                fromX: from.x,
                fromY: from.y,
                toX: to.x,
                toY: to.y,
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
        return await self.session.withSettledScreenshot(
            settleMs: args["settle_ms"]?.intValue,
            actionNote: "flick \(dirRaw) from (\(x),\(y))",
            includeScreenshot: includeScreenshot(args)
        ) {
            let point = try await self.preparePoint(x: x, y: y)
            try await self.session.gestures.flick(x: point.x, y: point.y, direction: direction)
        }
    }

    private func typeText(_ text: String?, settleMs: Int?, includeScreenshot: Bool) async -> ToolResult {
        guard let text else { return .fail("type_text requires text") }
        return await self.session.withSettledScreenshot(
            settleMs: settleMs,
            actionNote: "type_text",
            includeScreenshot: includeScreenshot
        ) {
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
        return await self.session.withSettledScreenshot(
            settleMs: args["settle_ms"]?.intValue,
            actionNote: "press_key \(keyName)",
            includeScreenshot: includeScreenshot(args)
        ) {
            try self.session.gestures.requireBluetooth()
            for _ in 0 ..< repeatCount {
                await self.session.hid.tapKey(key, modifiers: modifiers)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    private func includeScreenshot(_ args: [String: ToolValue]) -> Bool {
        args["include_screenshot"]?.boolValue ?? false
    }

    /// Starts capture and maps returned-screenshot pixels onto the raw USB frame.
    private func preparePoint(x: Int, y: Int) async throws -> (x: Double, y: Double) {
        try await self.session.startScreen()
        return try self.session.screen.rawPoint(agentX: Double(x), agentY: Double(y))
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
