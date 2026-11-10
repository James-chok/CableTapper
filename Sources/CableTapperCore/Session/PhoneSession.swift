import Foundation

@MainActor
public final class PhoneSession {
    public let hid: HIDController
    public let screen: ScreenCapture
    public let gestures: GestureEngine

    public var defaultSettleMs: Int = 3000

    public init(advertisedName: String = "CableTapper") {
        hid = HIDController(advertisedName: advertisedName)
        screen = ScreenCapture()
        gestures = GestureEngine(hid: hid)
    }

    public func startHID() {
        hid.start()
    }

    public func startScreen() async throws {
        try await screen.start()
        let size = screen.frameSize
        if size.width > 0, size.height > 0 {
            gestures.updateScreenSize(width: size.width, height: size.height)
        }
    }

    public func statusText() -> String {
        let s = hid.status
        let screenNote: String
        if screen.hasFrame {
            let size = screen.frameSize
            screenNote = "usb=frames \(size.width)x\(size.height)"
        } else {
            screenNote = "usb=no frame"
        }
        return """
        CableTapper status:
        bluetooth=\(s.bluetoothState) advertising=\(s.isAdvertising) serviceReady=\(s.isServiceReady)
        bleHosts=\(s.connectedHosts) name="\(s.advertisedName)"
        \(screenNote)
        assistiveTouch=manual (enable on iPhone)
        note=Open CableTapper, then on the phone tap "\(s.advertisedName)"
        \(s.lastError.map { "error=\($0)" } ?? "error=none")
        """
    }

    @discardableResult
    public func withSettledScreenshot(
        settleMs: Int? = nil,
        actionNote: String,
        body: () async throws -> Void
    ) async -> ToolResult {
        do {
            try await body()
            let shot = try await screen.waitForSettle(timeoutMs: settleMs ?? defaultSettleMs)
            gestures.updateScreenSize(width: shot.width, height: shot.height)
            let settleNote = shot.settled ? "screen settled" : "screen still moving"
            return .ok(
                "\(actionNote)\nScreenshot \(shot.width)x\(shot.height) px. \(settleNote).",
                jpeg: shot.jpegData
            )
        } catch {
            let jpeg = try? screen.captureJPEG().jpegData
            return .fail(error.localizedDescription, jpeg: jpeg)
        }
    }
}
