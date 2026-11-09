import Foundation

public struct HIDStatus: Sendable {
    public var classicConnected: Bool
    public var classicPeer: String?
    public var macBluetoothName: String
    public var isListening: Bool
    public var isSDPPublished: Bool
    public var lastError: String?
}

@MainActor
public final class HIDController {
    public let profile: ComboProfile
    public let classic: ClassicHIDServer

    public init(advertisedName: String = "CableTapper") {
        let profile = ComboProfile(advertisedName: advertisedName)
        self.profile = profile
        classic = ClassicHIDServer(profile: profile)
    }

    /// Start Classic HID pairing window (SDP + discoverable + incoming L2CAP).
    public func start() {
        classic.startPairingWindow()
    }

    public func startClassicPairing() {
        classic.startPairingWindow()
    }

    public func stop() {
        classic.stop()
    }

    public var isConnected: Bool {
        classic.isConnected
    }

    public var status: HIDStatus {
        HIDStatus(
            classicConnected: classic.isConnected,
            classicPeer: classic.peerName ?? classic.peerAddress,
            macBluetoothName: classic.macBluetoothName,
            isListening: classic.isListening,
            isSDPPublished: classic.isSDPPublished,
            lastError: classic.lastError
        )
    }

    public func sendMouse(_ report: MouseReport) {
        send(ReportID.mouse.rawValue, report.data)
    }

    public func sendKeyboard(_ report: KeyboardReport) {
        send(ReportID.keyboard.rawValue, report.data)
    }

    public func sendConsumer(_ report: ConsumerReport) {
        send(ReportID.consumerControl.rawValue, report.data)
    }

    private func send(_ id: UInt8, _ data: Data) {
        classic.send(reportID: id, payload: data)
    }

    public func moveBy(dx: Int8, dy: Int8) {
        sendMouse(MouseReport(dX: dx, dY: dy))
    }

    public func click(button: MouseButtons = .left) async {
        sendMouse(MouseReport(buttons: button))
        try? await Task.sleep(nanoseconds: 40_000_000)
        sendMouse(.zero)
    }

    public func press(button: MouseButtons = .left) {
        sendMouse(MouseReport(buttons: button))
    }

    public func release() {
        sendMouse(.zero)
    }

    public func tapKey(_ key: Keycode, modifiers: KeyboardModifiers = []) async {
        sendKeyboard(KeyboardReport(modifiers: modifiers, keys: [key]))
        try? await Task.sleep(nanoseconds: 20_000_000)
        sendKeyboard(.zero)
    }

    public func typeASCII(_ text: String, perKeyDelayNs: UInt64 = 25_000_000) async throws {
        var unsupported: [Character] = []
        for ch in text {
            if ASCIIKeymap.map(ch) == nil {
                unsupported.append(ch)
            }
        }
        if !unsupported.isEmpty {
            let listed = unsupported.map(String.init).joined()
            throw CableTapperError.unsupportedCharacters(listed)
        }
        for ch in text {
            guard let (key, mods) = ASCIIKeymap.map(ch) else { continue }
            sendKeyboard(KeyboardReport(modifiers: mods, keys: [key]))
            try? await Task.sleep(nanoseconds: perKeyDelayNs)
            sendKeyboard(.zero)
            try? await Task.sleep(nanoseconds: perKeyDelayNs / 2)
        }
    }

    public func consumerTap(_ report: ConsumerReport) async {
        sendConsumer(report)
        try? await Task.sleep(nanoseconds: 30_000_000)
        sendConsumer(.zero)
    }
}
