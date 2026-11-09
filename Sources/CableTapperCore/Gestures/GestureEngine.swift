import Foundation

@MainActor
public final class GestureEngine {
    public private(set) var pointer: PointerModel
    private let hid: HIDController
    private let moveDelayNs: UInt64

    public init(hid: HIDController, pointer: PointerModel = PointerModel(), moveDelayNs: UInt64 = 8_000_000) {
        self.hid = hid
        self.pointer = pointer
        self.moveDelayNs = moveDelayNs
    }

    public func updateScreenSize(width: Int, height: Int) {
        pointer.updateScreenSize(width: Double(width), height: Double(height))
    }

    public func requireBluetooth() throws {
        guard hid.isConnected else { throw CableTapperError.bluetoothNotConnected }
    }

    /// Recalibrate by ramming into the top-left corner, then move to target.
    public func moveTo(x: Double, y: Double, recalibrate: Bool = false) async throws {
        try requireBluetooth()
        if recalibrate {
            await ramToCorner()
        }
        let chunks = pointer.hidChunks(toX: x, toY: y)
        for (dx, dy) in chunks {
            hid.moveBy(dx: dx, dy: dy)
            pointer.apply(dx: dx, dy: dy)
            try? await Task.sleep(nanoseconds: moveDelayNs)
        }
        pointer.x = x
        pointer.y = y
    }

    public func tap(x: Double, y: Double) async throws {
        try await moveTo(x: x, y: y, recalibrate: true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        await hid.click()
    }

    public func doubleTap(x: Double, y: Double) async throws {
        try await moveTo(x: x, y: y, recalibrate: true)
        await hid.click()
        try? await Task.sleep(nanoseconds: 80_000_000)
        await hid.click()
    }

    public func longPress(x: Double, y: Double, durationMs: Int = 800) async throws {
        try await moveTo(x: x, y: y, recalibrate: true)
        hid.press()
        try? await Task.sleep(nanoseconds: UInt64(max(durationMs, 100)) * 1_000_000)
        hid.release()
    }

    public func drag(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        durationMs: Int = 800
    ) async throws {
        try await moveTo(x: fromX, y: fromY, recalibrate: true)
        hid.press()
        try? await Task.sleep(nanoseconds: 40_000_000)

        let chunks = pointer.hidChunks(toX: toX, toY: toY)
        let stepDelay: UInt64
        if chunks.isEmpty {
            stepDelay = 0
        } else {
            stepDelay = UInt64(max(durationMs, 50)) * 1_000_000 / UInt64(chunks.count)
        }
        for (dx, dy) in chunks {
            hid.sendMouse(MouseReport(buttons: .left, dX: dx, dY: dy))
            pointer.apply(dx: dx, dy: dy)
            try? await Task.sleep(nanoseconds: max(stepDelay, 4_000_000))
        }
        pointer.x = toX
        pointer.y = toY
        hid.release()
    }

    public func flick(x: Double, y: Double, direction: FlickDirection) async throws {
        try await moveTo(x: x, y: y, recalibrate: true)
        let distance = min(pointer.width, pointer.height) * 0.30
        let (dx, dy): (Double, Double) = switch direction {
        case .up: (0, -distance)
        case .down: (0, distance)
        case .left: (-distance, 0)
        case .right: (distance, 0)
        }
        try await drag(
            fromX: x,
            fromY: y,
            toX: min(max(x + dx, 0), pointer.width - 1),
            toY: min(max(y + dy, 0), pointer.height - 1),
            durationMs: 180
        )
    }

    public func home() async throws {
        try requireBluetooth()
        // GUI+H is not universal on iOS; use consumer AC Home when available, else Spotlight dismiss + many homes via consumer.
        await hid.consumerTap(.acHome)
    }

    public func back() async throws {
        try requireBluetooth()
        // Edge swipe from left as AssistiveTouch drag.
        let y = pointer.height * 0.5
        try await drag(fromX: 2, fromY: y, toX: pointer.width * 0.45, toY: y, durationMs: 350)
    }

    public func dismiss() async throws {
        try requireBluetooth()
        await hid.tapKey(.escape)
        try? await Task.sleep(nanoseconds: 80_000_000)
        await hid.tapKey(.escape)
    }

    public func openApp(named name: String) async throws {
        try requireBluetooth()
        await hid.consumerTap(.acHome)
        try? await Task.sleep(nanoseconds: 400_000_000)
        // Spotlight: Cmd+Space on hardware keyboard for iOS
        await hid.tapKey(.space, modifiers: .leftGUI)
        try? await Task.sleep(nanoseconds: 450_000_000)
        try await hid.typeASCII(name)
        try? await Task.sleep(nanoseconds: 500_000_000)
        await hid.tapKey(.return)
    }

    private func ramToCorner() async {
        // Overshoot top-left so AssistiveTouch cursor parks at origin.
        for _ in 0 ..< 40 {
            hid.moveBy(dx: -127, dy: -127)
            try? await Task.sleep(nanoseconds: moveDelayNs)
        }
        pointer.x = 0
        pointer.y = 0
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}

public enum FlickDirection: String, Sendable {
    case up, down, left, right
}
