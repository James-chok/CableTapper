import BTHIDKit
import Foundation

public struct HIDStatus: Sendable {
    public var bluetoothState: String
    public var isAdvertising: Bool
    public var isServiceReady: Bool
    public var connectedHosts: Int
    public var centralLinks: Int
    public var classicConnected: Bool
    public var classicPeer: String?
    public var macBluetoothName: String
    public var lastError: String?
    public var advertisedName: String
}

public struct NearbyDevice: Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var rssi: Int
    public var isNamed: Bool
}

@MainActor
public final class HIDController {
    public let profile: ComboProfile
    public let peripheral: HIDPeripheral
    public let central: HIDCentral
    public let classic: ClassicHIDServer

    public init(advertisedName: String = "CableTapper") {
        let profile = ComboProfile(advertisedName: advertisedName)
        self.profile = profile
        peripheral = HIDPeripheral(profile: profile)
        peripheral.advertisedName = advertisedName
        central = HIDCentral()
        classic = ClassicHIDServer(profile: profile)
    }

    public func start() {
        peripheral.start()
        central.start()
    }

    public func startClassicPairing() {
        classic.startPairingWindow()
    }

    public func stop() {
        peripheral.stop()
        central.stopScan()
        classic.stop()
    }

    public var isConnected: Bool {
        if classic.isConnected { return true }
        let hostSubscribed = peripheral.connectedCentrals.contains { !peripheral.inactiveCentrals.contains($0) }
        return hostSubscribed || !central.connected.isEmpty
    }

    public var status: HIDStatus {
        HIDStatus(
            bluetoothState: String(describing: peripheral.state),
            isAdvertising: peripheral.isAdvertising,
            isServiceReady: peripheral.isHIDServiceAdded,
            connectedHosts: peripheral.connectedCentrals.filter { !peripheral.inactiveCentrals.contains($0) }.count,
            centralLinks: central.connected.count,
            classicConnected: classic.isConnected,
            classicPeer: classic.peerName ?? classic.peerAddress,
            macBluetoothName: classic.macBluetoothName,
            lastError: classic.lastError ?? peripheral.lastError ?? central.lastError,
            advertisedName: peripheral.localName
        )
    }

    public func startScan() {
        central.start()
        central.startScan()
    }

    public func stopScan() {
        central.stopScan()
    }

    public var nearbyDevices: [NearbyDevice] {
        central.discovered.map {
            NearbyDevice(id: $0.id, name: $0.name, rssi: $0.rssi, isNamed: $0.isNamed)
        }
    }

    public func connect(to id: UUID) {
        central.connect(id)
    }

    public func connect(matching query: String) throws -> NearbyDevice {
        let q = query.lowercased()
        let matches = nearbyDevices.filter {
            $0.name.lowercased().contains(q) || $0.id.uuidString.lowercased().hasPrefix(q)
        }
        guard let first = matches.first else {
            throw CableTapperError.internalError(
                "No nearby BLE device matching \"\(query)\". For iPhone, use `cabletapper pair` and tap your Mac name (\(classic.macBluetoothName)) in Settings › Bluetooth."
            )
        }
        central.connect(first.id)
        return first
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
        if classic.isConnected {
            classic.send(reportID: id, payload: data)
        } else {
            peripheral.send(id, data)
        }
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
