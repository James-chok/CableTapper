import ArgumentParser
import CableTapperCore
import Foundation

@main
struct CableTapperCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cabletapper",
        abstract: "Headless Mac→iPhone bridge (USB screen + Bluetooth HID + MCP).",
        subcommands: [
            Status.self,
            Screenshot.self,
            Tap.self,
            TypeText.self,
            Move.self,
            Click.self,
            FindText.self,
            Home.self,
            Back.self,
            Dismiss.self,
            OpenApp.self,
            MCP.self,
            Pair.self,
            Smoke.self,
        ]
    )
}

@MainActor
enum Shared {
    static let session = PhoneSession()
    static let router = ToolRouter(session: session)

    /// `./screenshots` under the process working directory.
    static var screenshotsDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("screenshots", isDirectory: true)
    }

    static func ensureHID() {
        session.startHID()
    }

    static func ensureScreenshotsDirectory() throws -> URL {
        let dir = screenshotsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writeScreenshot(_ data: Data, name: String) throws -> URL {
        let dir = try ensureScreenshotsDirectory()
        let url = dir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func printResult(_ result: ToolResult) throws {
        if let jpeg = result.jpegData {
            FileHandle.standardError.write(Data("jpeg_bytes=\(jpeg.count)\n".utf8))
        }
        print(result.text)
        if result.isError {
            throw ExitCode(1)
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show Bluetooth/USB status")

    @MainActor
    func run() async throws {
        Shared.ensureHID()
        try? await Shared.session.startScreen()
        try Shared.printResult(await Shared.router.call(ToolCall(name: "status")))
    }
}

struct Pair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Classic HID pair: iPhone taps this Mac's Bluetooth name"
    )

    @Option(name: .long, help: "Seconds to keep pairing window open (0 = forever)")
    var seconds: Int = 0

    @MainActor
    func run() async throws {
        let bundleOK = Bundle.main.bundleIdentifier == "local.cabletapper"
        if !bundleOK {
            FileHandle.standardError.write(Data("""
            WARNING: Not running from CableTapper.app.
            Prefer: ./scripts/package-app.sh && dist/CableTapper.app/Contents/MacOS/cabletapper pair

            """.utf8))
        }
        Shared.ensureHID()
        let macName = Shared.session.hid.classic.macBluetoothName
        FileHandle.standardError.write(Data("""
        Classic HID pairing window open.
        Mac Bluetooth name: \(macName)

        On iPhone:
          1. AssistiveTouch ON
          2. Settings › Bluetooth
          3. Tap "\(macName)" under Other Devices / My Devices

        Also open Mac System Settings › Bluetooth (helps discoverability).
        Waiting for HID channels…

        """.utf8))

        let deadline: Date? = seconds > 0 ? Date().addingTimeInterval(TimeInterval(seconds)) : nil
        while deadline.map({ Date() < $0 }) ?? true {
            try await Task.sleep(nanoseconds: 500_000_000)
            if Shared.session.hid.isConnected {
                let peer = Shared.session.hid.classic.peerName ?? "?"
                print("Classic HID connected to \(peer)")
                print("Leave this process running. Try: cabletapper smoke (same process) or mcp")
                if seconds == 0 {
                    try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
                }
                return
            }
            if let err = Shared.session.hid.classic.lastError {
                FileHandle.standardError.write(Data("classic: \(err)\n".utf8))
            }
        }
        throw CableTapperError.internalError("Pairing window timed out with no Classic HID connection")
    }
}

struct Smoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "One-process Classic HID+USB smoke test (watch AssistiveTouch on the phone)"
    )

    @Option(name: .long, help: "Seconds to wait for Bluetooth HID host")
    var wait: Int = 45

    @MainActor
    func run() async throws {
        Shared.ensureHID()
        let macName = Shared.session.hid.classic.macBluetoothName
        FileHandle.standardError.write(Data("""
        Smoke test: Classic HID.
        If not already linked, on iPhone open Bluetooth and tap "\(macName)".
        Waiting up to \(wait)s for HID…

        """.utf8))

        let deadline = Date().addingTimeInterval(TimeInterval(wait))
        while Date() < deadline, !Shared.session.hid.isConnected {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard Shared.session.hid.isConnected else {
            throw CableTapperError.bluetoothNotConnected
        }
        let s = Shared.session.hid.status
        print("HID up. peer=\(s.classicPeer ?? "?")")

        print("1) relative move right…")
        for _ in 0 ..< 8 {
            Shared.session.hid.moveBy(dx: 40, dy: 0)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try await Task.sleep(nanoseconds: 400_000_000)

        print("2) click…")
        await Shared.session.hid.click()
        try await Task.sleep(nanoseconds: 500_000_000)

        print("3) type 'hi'…")
        try await Shared.session.hid.typeASCII("hi")
        try await Task.sleep(nanoseconds: 500_000_000)

        print("4) USB screenshot…")
        try? await Shared.session.startScreen()
        let shot = try await Shared.session.screen.waitForSettle(timeoutMs: 2000)
        let url = try Shared.writeScreenshot(shot.jpegData, name: "smoke.jpg")
        print("Wrote \(url.path) (\(shot.jpegData.count) bytes) \(shot.width)x\(shot.height)")
        print("Smoke done. Did the AssistiveTouch pointer move / click on the phone?")
    }
}

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Capture a settled USB screenshot")

    @Option(name: .shortAndLong, help: "Write JPEG to path (default: ./screenshots/screenshot-<timestamp>.jpg)")
    var output: String?

    @MainActor
    func run() async throws {
        Shared.ensureHID()
        let result = await Shared.router.call(ToolCall(name: "screenshot"))
        guard let jpeg = result.jpegData else {
            try Shared.printResult(result)
            return
        }
        let url: URL
        if let output {
            let pathURL = URL(fileURLWithPath: output)
            if pathURL.pathExtension.isEmpty {
                try FileManager.default.createDirectory(at: pathURL, withIntermediateDirectories: true)
                url = pathURL.appendingPathComponent(Self.defaultFileName())
            } else {
                try FileManager.default.createDirectory(
                    at: pathURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                url = pathURL
            }
            try jpeg.write(to: url, options: .atomic)
        } else {
            url = try Shared.writeScreenshot(jpeg, name: Self.defaultFileName())
        }
        print("Wrote \(url.path) (\(jpeg.count) bytes)")
        print(result.text)
        if result.isError { throw ExitCode(1) }
    }

    private static func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "screenshot-\(formatter.string(from: Date())).jpg"
    }
}

struct Tap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Tap screenshot coordinates")

    @Argument var x: Int
    @Argument var y: Int

    @MainActor
    func run() async throws {
        Shared.ensureHID()
        try? await Shared.session.startScreen()
        try Shared.printResult(
            await Shared.router.call(ToolCall(name: "tap", arguments: ["x": .int(x), "y": .int(y)]))
        )
    }
}

struct TypeText: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "type", abstract: "Type ASCII text")

    @Argument var text: String

    @MainActor
    func run() async throws {
        Shared.ensureHID()
        try Shared.printResult(
            await Shared.router.call(ToolCall(name: "type_text", arguments: ["text": .string(text)]))
        )
    }
}

struct Move: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Relative HID mouse move (for debugging)")

    @Argument var dx: Int
    @Argument var dy: Int

    @MainActor
    func run() async throws {
        Shared.ensureHID()
        for _ in 0 ..< 20 where !Shared.session.hid.isConnected {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard Shared.session.hid.isConnected else {
            throw CableTapperError.bluetoothNotConnected
        }
        let sx = Int8(clamping: dx)
        let sy = Int8(clamping: dy)
        Shared.session.hid.moveBy(dx: sx, dy: sy)
        print("moved dx=\(sx) dy=\(sy)")
    }
}

struct Click: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "HID left click at current AssistiveTouch cursor")

    @MainActor
    func run() async throws {
        Shared.ensureHID()
        for _ in 0 ..< 20 where !Shared.session.hid.isConnected {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard Shared.session.hid.isConnected else {
            throw CableTapperError.bluetoothNotConnected
        }
        await Shared.session.hid.click()
        print("clicked")
    }
}

struct FindText: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "find-text", abstract: "OCR the USB screen")

    @Argument var query: String?
    @Flag var exact: Bool = false

    @MainActor
    func run() async throws {
        Shared.ensureHID()
        var args: [String: ToolValue] = [:]
        if let query { args["query"] = .string(query) }
        args["exact"] = .bool(exact)
        try Shared.printResult(await Shared.router.call(ToolCall(name: "find_text", arguments: args)))
    }
}

struct Home: AsyncParsableCommand {
    @MainActor
    func run() async throws {
        Shared.ensureHID()
        try Shared.printResult(await Shared.router.call(ToolCall(name: "home")))
    }
}

struct Back: AsyncParsableCommand {
    @MainActor
    func run() async throws {
        Shared.ensureHID()
        try Shared.printResult(await Shared.router.call(ToolCall(name: "back")))
    }
}

struct Dismiss: AsyncParsableCommand {
    @MainActor
    func run() async throws {
        Shared.ensureHID()
        try Shared.printResult(await Shared.router.call(ToolCall(name: "dismiss")))
    }
}

struct OpenApp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open-app", abstract: "Open app via Spotlight")

    @Argument var name: String

    @MainActor
    func run() async throws {
        Shared.ensureHID()
        try Shared.printResult(
            await Shared.router.call(ToolCall(name: "open_app", arguments: ["name": .string(name)]))
        )
    }
}

struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the MCP server")

    @Flag(name: .long, help: "Use stdio transport (default if --http is not set)")
    var stdio: Bool = false

    @Flag(name: .long, help: "Use loopback HTTP transport")
    var http: Bool = false

    @Option(name: .long, help: "HTTP bind host")
    var host: String = "127.0.0.1"

    @Option(name: .long, help: "HTTP port")
    var port: Int = 47801

    @MainActor
    func run() async throws {
        let useStdio = stdio || !http
        try await MCPServerRuntime.run(
            session: Shared.session,
            stdio: useStdio,
            host: host,
            port: port
        )
    }
}
