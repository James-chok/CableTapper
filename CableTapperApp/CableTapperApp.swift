import BTHIDKit
import CableTapperCore
import CableTapperMCP
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let session = PhoneSession()
    let central = HIDCentral()
    @Published private(set) var mcpReady = false
    @Published private(set) var mcpError: String?
    private var didStart = false

    func start() async {
        guard !didStart else { return }
        didStart = true
        session.startHID()
        central.start()
        do {
            try await MCPServerRuntime.run(session: session) {
                self.mcpReady = true
            }
        } catch {
            mcpError = error.localizedDescription
        }
    }
}

@main
struct CableTapperApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HStack(alignment: .top, spacing: 0) {
                ContentView(
                    model: model,
                    peripheral: model.session.hid.peripheral,
                    central: model.central
                )
                .frame(minWidth: 420, idealWidth: 460, maxWidth: 480, maxHeight: .infinity)
                Divider()
                MirrorView(session: model.session)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 760, minHeight: 640)
            .task { await model.start() }
        }
        .defaultSize(width: 960, height: 720)
    }
}
