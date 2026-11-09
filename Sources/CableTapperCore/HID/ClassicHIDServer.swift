#if os(macOS)
    import BTHIDKit
    import Darwin
    import Foundation
    @preconcurrency import IOBluetooth
    import os

    /// Bluetooth Classic HID device role: publish SDP, listen for incoming HID L2CAP (Zeptap-style).
    /// iPhone pairs with the Mac's **computer Bluetooth name**, not "CableTapper".
    @MainActor
    public final class ClassicHIDServer: NSObject {
        public private(set) var isSDPPublished = false
        public private(set) var isListening = false
        public private(set) var isConnected = false
        public private(set) var peerAddress: String?
        public private(set) var peerName: String?
        public private(set) var lastError: String?
        public private(set) var macBluetoothName: String

        private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CableTapper", category: "ClassicHID")
        private let profile: ComboProfile
        private var serviceRecords: [IOBluetoothSDPServiceRecord] = []
        private var controlNotif: IOBluetoothUserNotification?
        private var interruptNotif: IOBluetoothUserNotification?
        private var controlChannel: IOBluetoothL2CAPChannel?
        private var interruptChannel: IOBluetoothL2CAPChannel?
        private var lastReports: [UInt8: Data]

        public init(profile: ComboProfile) {
            self.profile = profile
            lastReports = profile.identity.seedReports
            macBluetoothName = Host.current().localizedName ?? "Mac"
            super.init()
            if let name = IOBluetoothHostController.default()?.nameAsString(), !name.isEmpty {
                macBluetoothName = name
            }
        }

        public func startPairingWindow(discoverableSeconds: TimeInterval = 120) {
            lastError = nil
            publishSDP()
            becomeKeyboardClass(for: discoverableSeconds)
            makeDiscoverable(true)
            startListening()
            isListening = true
            log.info("Classic HID pairing window open; Mac name=\(self.macBluetoothName, privacy: .public)")
        }

        public func stop() {
            makeDiscoverable(false)
            stopListening()
            disconnectChannels()
            unpublishSDP()
            isListening = false
        }

        public func send(reportID: UInt8, payload: Data) {
            lastReports[reportID] = payload
            guard let interruptChannel, isConnected else { return }
            var buffer = Data(capacity: 2 + payload.count)
            buffer.append(0xA1) // HIDP DATA (Input)
            buffer.append(reportID)
            buffer.append(payload)
            var bytes = [UInt8](buffer)
            let result = interruptChannel.writeSync(&bytes, length: UInt16(bytes.count))
            if result != kIOReturnSuccess {
                lastError = "Classic HID write failed (\(result))"
            }
        }

        private func publishSDP() {
            guard serviceRecords.isEmpty else { return }
            let dicts = [SDPRecord.buildHID(profile.identity)]
            for dict in dicts {
                guard let record = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else {
                    lastError = "Failed to publish HID SDP record"
                    log.error("publishedServiceRecord returned nil")
                    return
                }
                serviceRecords.append(record)
            }
            isSDPPublished = true
        }

        private func unpublishSDP() {
            serviceRecords.forEach { $0.remove() }
            serviceRecords.removeAll()
            isSDPPublished = false
        }

        private func becomeKeyboardClass(for seconds: TimeInterval) {
            guard let host = IOBluetoothHostController.default() else { return }
            // Peripheral / Keyboard, limited discoverable
            host.setClassOfDevice(0x002540, forTimeInterval: seconds)
        }

        private func makeDiscoverable(_ on: Bool) {
            // Try preference symbol dynamically (removed/hidden on some SDKs).
            if let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY) {
                defer { dlclose(handle) }
                typealias Fn = @convention(c) (Int32) -> Void
                if let sym = dlsym(handle, "IOBluetoothPreferenceSetDiscoverableState") {
                    let fn = unsafeBitCast(sym, to: Fn.self)
                    fn(on ? 1 : 0)
                }
            }

            // Private SPI used by Zeptap-like tools on newer macOS.
            if let manager = classicManager() {
                let sel = NSSelectorFromString("setBTDiscoverable:")
                if manager.responds(to: sel) {
                    _ = manager.perform(sel, with: NSNumber(value: on))
                    log.info("CBClassicManager setBTDiscoverable:\(on)")
                }
            }
        }

        private func classicManager() -> NSObject? {
            guard let cls = NSClassFromString("CBClassicManager") as? NSObject.Type else { return nil }
            let sharedSel = NSSelectorFromString("sharedInstance")
            if cls.responds(to: sharedSel), let obj = cls.perform(sharedSel)?.takeUnretainedValue() as? NSObject {
                return obj
            }
            let defaultSel = NSSelectorFromString("defaultManager")
            if cls.responds(to: defaultSel), let obj = cls.perform(defaultSel)?.takeUnretainedValue() as? NSObject {
                return obj
            }
            return nil
        }

        private func startListening() {
            stopListening()
            controlNotif = IOBluetoothL2CAPChannel.register(
                forChannelOpenNotifications: self,
                selector: #selector(channelOpened(_:channel:)),
                withPSM: BluetoothL2CAPPSM(kBluetoothL2CAPPSMHIDControl),
                direction: kIOBluetoothUserNotificationChannelDirectionIncoming
            )
            interruptNotif = IOBluetoothL2CAPChannel.register(
                forChannelOpenNotifications: self,
                selector: #selector(channelOpened(_:channel:)),
                withPSM: BluetoothL2CAPPSM(kBluetoothL2CAPPSMHIDInterrupt),
                direction: kIOBluetoothUserNotificationChannelDirectionIncoming
            )
            if controlNotif == nil || interruptNotif == nil {
                lastError = "Failed to register incoming HID L2CAP listeners"
            }
        }

        private func stopListening() {
            controlNotif?.unregister()
            interruptNotif?.unregister()
            controlNotif = nil
            interruptNotif = nil
        }

        private func disconnectChannels() {
            controlChannel?.close()
            interruptChannel?.close()
            controlChannel = nil
            interruptChannel = nil
            isConnected = false
            peerAddress = nil
            peerName = nil
            profile.disconnect()
        }

        @objc private func channelOpened(_ notification: IOBluetoothUserNotification, channel: IOBluetoothL2CAPChannel) {
            channel.setDelegate(self)
            let psm = channel.psm
            let device = channel.device
            let addr = device?.addressString ?? "?"
            let name = device?.name ?? addr
            log.info("Incoming L2CAP PSM=\(psm) from \(name, privacy: .public)")

            if psm == BluetoothL2CAPPSM(kBluetoothL2CAPPSMHIDControl) {
                controlChannel = channel
            } else if psm == BluetoothL2CAPPSM(kBluetoothL2CAPPSMHIDInterrupt) {
                interruptChannel = channel
            }

            if controlChannel != nil, interruptChannel != nil {
                isConnected = true
                peerAddress = addr
                peerName = name
                makeDiscoverable(false)
                profile.connect(host: addr) { [weak self] id, data in
                    self?.send(reportID: id, payload: data)
                }
                // Seed empty reports so the host has a baseline.
                for (id, data) in lastReports {
                    send(reportID: id, payload: data)
                }
                log.info("Classic HID connected to \(name, privacy: .public)")
            }
        }
    }

    extension ClassicHIDServer: IOBluetoothL2CAPChannelDelegate {
        public nonisolated func l2capChannelData(_ channel: IOBluetoothL2CAPChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
            // Host→device HIDP messages (SET_REPORT / SET_PROTOCOL). Ignore for MVP.
        }

        public nonisolated func l2capChannelClosed(_ channel: IOBluetoothL2CAPChannel!) {
            Task { @MainActor in
                self.log.info("Classic HID channel closed")
                self.disconnectChannels()
            }
        }

        public nonisolated func l2capChannelOpenComplete(_ channel: IOBluetoothL2CAPChannel!, status error: IOReturn) {}
        public nonisolated func l2capChannelReconfigured(_ channel: IOBluetoothL2CAPChannel!) {}
        public nonisolated func l2capChannelWriteComplete(_ channel: IOBluetoothL2CAPChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {}
        public nonisolated func l2capChannelQueueSpaceAvailable(_ channel: IOBluetoothL2CAPChannel!) {}
    }
#endif
