import BTHIDKit
import CableTapperCore
import CableTapperMCP
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var peripheral: HIDPeripheral
    @ObservedObject var central: HIDCentral

    var body: some View {
        NavigationStack {
            Form {
                advertiseSection
                mcpSection
            }
            .formStyle(.grouped)
            .navigationTitle("CableTapper")
        }
        .onAppear { startNameScan() }
        .onChange(of: central.state) { _, _ in startNameScan() }
    }

    private var advertiseSection: some View {
        Section {
            LabeledContent("Name", value: peripheral.localName)
            LabeledContent("Bluetooth", value: peripheral.state.description)
            LabeledContent("Advertising", value: peripheral.isAdvertising ? "Yes" : "No")
            LabeledContent("HID service", value: peripheral.isHIDServiceAdded ? "Ready" : "Not ready")
            LabeledContent("Hosts", value: String(connectedHosts))
            LabeledContent("Connected Devices") {
                Text(connectedDeviceNames)
                    .multilineTextAlignment(.trailing)
            }
            if let lastError = peripheral.lastError {
                Text(lastError)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            if peripheral.isAdvertising {
                Button("Stop Advertising", role: .destructive) {
                    peripheral.stop()
                }
            } else {
                Button("Start Advertising") {
                    peripheral.start()
                }
            }
        } header: {
            Text("Advertise")
        } footer: {
            Text("On the iPhone, turn on AssistiveTouch, then tap \(peripheral.localName) in Settings › Bluetooth.")
        }
    }

    private var mcpSection: some View {
        Section {
            LabeledContent("URL", value: MCPServerRuntime.endpointURL)
            LabeledContent("Listener", value: listenerLabel)
            if let mcpError = model.mcpError {
                Text(mcpError)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        } header: {
            Text("MCP")
        }
    }

    private var connectedHosts: Int {
        peripheral.connectedCentrals.filter { !peripheral.inactiveCentrals.contains($0) }.count
    }

    private var connectedDeviceNames: String {
        let ids = peripheral.connectedCentrals.sorted { $0.uuidString < $1.uuidString }
        if ids.isEmpty { return "None" }
        return ids.map(deviceName).joined(separator: "\n")
    }

    private func deviceName(_ id: UUID) -> String {
        if let match = central.discovered.first(where: { $0.id == id && $0.isNamed }) {
            return match.name
        }
        return "Unknown"
    }

    private func startNameScan() {
        guard central.state == .poweredOn, !central.isScanning else { return }
        central.startScan()
    }

    private var listenerLabel: String {
        if model.mcpReady { return "Listening" }
        if model.mcpError != nil { return "Failed" }
        return "Starting"
    }
}
