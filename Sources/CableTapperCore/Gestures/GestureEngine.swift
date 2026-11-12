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

    /// Put the pointer on a screenshot pixel in one absolute report.
    public func moveTo(x: Double, y: Double) async throws {
        try requireBluetooth()
        place(x: x, y: y)
        try? await Task.sleep(nanoseconds: moveDelayNs)
    }

    public func isPointerNear(x: Double, y: Double, tolerance: Double = 0.75) -> Bool {
        abs(pointer.x - x) <= tolerance && abs(pointer.y - y) <= tolerance
    }

    public func pressPointer() {
        hid.press()
    }

    public func releasePointer() {
        hid.release()
    }

    /// Glide with the button held. Stops between reports when `shouldAbort` becomes true.
    public func moveWhilePressed(toX: Double, toY: Double, shouldAbort: () -> Bool) async throws {
        try requireBluetooth()
        await glide(toX: toX, toY: toY, steps: stepCount(toX: toX, toY: toY), shouldAbort: shouldAbort)
    }

    public func tap(x: Double, y: Double) async throws {
        try await moveTo(x: x, y: y)
        try? await Task.sleep(nanoseconds: 30_000_000)
        await hid.click()
    }

    public func doubleTap(x: Double, y: Double) async throws {
        try await moveTo(x: x, y: y)
        await hid.click()
        try? await Task.sleep(nanoseconds: 80_000_000)
        await hid.click()
    }

    public func longPress(x: Double, y: Double, durationMs: Int = 800) async throws {
        try await moveTo(x: x, y: y)
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
        try await moveTo(x: fromX, y: fromY)
        hid.press()
        try? await Task.sleep(nanoseconds: 40_000_000)
        let timedSteps = Int(UInt64(max(durationMs, 50)) * 1_000_000 / moveDelayNs)
        await glide(toX: toX, toY: toY, steps: max(timedSteps, 1)) { false }
        // Release right after the last motion report so scroll momentum survives.
        hid.release()
    }

    public func flick(x: Double, y: Double, direction: FlickDirection) async throws {
        try await moveTo(x: x, y: y)
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
        // Start must sit in the home-indicator strip, and iOS ignores a press right after the pointer arrives.
        let x = pointer.width * 0.5
        let fromY = max(pointer.height - 22, 0)
        try await moveTo(x: x, y: fromY)
        try? await Task.sleep(nanoseconds: 200_000_000)
        try await drag(fromX: x, fromY: fromY, toX: x, toY: pointer.height * 0.24, durationMs: 250)
    }

    public func back() async throws {
        try requireBluetooth()
        // Back is a horizontal swipe that starts on the left column of pixels.
        let y = pointer.height * 0.5
        try await moveTo(x: 0, y: y)
        try? await Task.sleep(nanoseconds: 200_000_000)
        try await drag(fromX: 0, fromY: y, toX: pointer.width * 0.7, toY: y, durationMs: 300)
    }

    private func place(x: Double, y: Double) {
        pointer.x = min(max(x, 0), pointer.width - 1)
        pointer.y = min(max(y, 0), pointer.height - 1)
        let point = pointer.hidPoint(x: pointer.x, y: pointer.y)
        hid.pointTo(x: point.x, y: point.y)
    }

    /// Absolute jumps register as one huge step, so long moves are split for gesture recognizers.
    private func stepCount(toX: Double, toY: Double) -> Int {
        let distance = hypot(toX - pointer.x, toY - pointer.y)
        let maxStep = max(max(pointer.width, pointer.height) / 80, 1)
        return max(Int((distance / maxStep).rounded(.up)), 1)
    }

    private func glide(toX: Double, toY: Double, steps: Int, shouldAbort: () -> Bool) async {
        let startX = pointer.x
        let startY = pointer.y
        for step in 1 ... steps {
            if shouldAbort() { return }
            let t = Double(step) / Double(steps)
            place(x: startX + (toX - startX) * t, y: startY + (toY - startY) * t)
            try? await Task.sleep(nanoseconds: moveDelayNs)
        }
    }
}

public enum FlickDirection: String, Sendable {
    case up, down, left, right
}
