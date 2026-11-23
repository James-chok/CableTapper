import AVFoundation
@preconcurrency import Combine
import CoreGraphics
import CoreImage
import CoreMediaIO
import Foundation
import ImageIO

public struct Screenshot: Sendable {
    public var jpegData: Data
    /// Pixel size of the JPEG handed to the agent, after downscaling.
    public var width: Int
    public var height: Int
    public var settled: Bool
}

public enum CapturePhase: Equatable, Sendable {
    case searching
    case waitingForFrame
    case live(width: Int, height: Int)
    case failed(String)
}

@MainActor
public final class ScreenCapture: NSObject, ObservableObject {
    /// Manual publisher so this main-actor class can conform to `ObservableObject`.
    nonisolated(unsafe) public let objectWillChange = ObservableObjectPublisher()

    public private(set) var phase: CapturePhase = .searching {
        willSet {
            guard newValue != phase else { return }
            objectWillChange.send()
        }
    }

    public var captureSession: AVCaptureSession { session }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "cabletapper.screen")

    private var latestImage: CGImage?
    private var latestSize: (Int, Int) = (0, 0)
    private var started = false
    private var activeStart: Task<Void, Error>?
    nonisolated(unsafe) private var disconnectObserver: NSObjectProtocol?

    public override init() {
        super.init()
        Self.allowScreenCaptureDevices()
        observeDisconnects()
    }

    deinit {
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
        }
    }

    public var hasFrame: Bool { latestImage != nil }

    public var frameSize: (width: Int, height: Int) { latestSize }

    /// Retries until a frame arrives or this task is cancelled. A later `start` joins the in-flight attempt.
    public func maintain() async {
        while !Task.isCancelled {
            if hasFrame {
                do {
                    try await Task.sleep(nanoseconds: 400_000_000)
                } catch {
                    break
                }
                continue
            }
            do {
                try await start()
            } catch {
                if Task.isCancelled { break }
                do {
                    try await Task.sleep(nanoseconds: 400_000_000)
                } catch {
                    break
                }
            }
        }
    }

    public func start(timeoutSeconds: TimeInterval = 12) async throws {
        if started, latestImage != nil { return }
        if let activeStart {
            try await activeStart.value
            return
        }
        let task = Task { @MainActor in
            defer { self.activeStart = nil }
            try await self.startOnce(timeoutSeconds: timeoutSeconds)
        }
        activeStart = task
        try await task.value
    }

    public func stop() {
        resetCapture(phase: .searching)
    }

    /// Longest side of a screenshot returned to an agent.
    public nonisolated static let agentMaxLongEdge = 1000
    public nonisolated static let agentJPEGQuality: CGFloat = 0.5
    /// Spacing of the optional coordinate grid, in returned-screenshot pixels.
    public nonisolated static let coordinateGridSpacing = CoordinateGrid.spacing

    /// Returned-screenshot size for a raw USB frame. Frames already within the cap stay unchanged.
    public nonisolated static func agentPixelSize(rawWidth: Int, rawHeight: Int) -> (width: Int, height: Int) {
        guard rawWidth > 0, rawHeight > 0 else { return (1, 1) }
        let longEdge = max(rawWidth, rawHeight)
        guard longEdge > agentMaxLongEdge else { return (rawWidth, rawHeight) }
        let scale = Double(agentMaxLongEdge) / Double(longEdge)
        return (
            max(Int((Double(rawWidth) * scale).rounded()), 1),
            max(Int((Double(rawHeight) * scale).rounded()), 1)
        )
    }

    public func agentPixelSize() -> (width: Int, height: Int) {
        if let image = latestImage {
            return Self.agentPixelSize(rawWidth: image.width, rawHeight: image.height)
        }
        return Self.agentPixelSize(rawWidth: frameSize.width, rawHeight: frameSize.height)
    }

    /// Maps a point in returned-screenshot pixels onto the raw USB frame.
    /// Each axis uses its own length so rounding the two edges cannot skew the point.
    public func rawPoint(agentX: Double, agentY: Double) throws -> (x: Double, y: Double) {
        guard let image = latestImage else {
            throw CableTapperError.screenUnavailable("is the iPhone connected by USB and unlocked?")
        }
        let agent = Self.agentPixelSize(rawWidth: image.width, rawHeight: image.height)
        let rawX = agentX / Double(agent.width) * Double(image.width)
        let rawY = agentY / Double(agent.height) * Double(image.height)
        return (rawX, rawY)
    }

    public func currentThumbnail() -> Data? {
        guard let image = latestImage else { return nil }
        return FrameSettle.thumbnailData(image)
    }

    /// Waits until consecutive frames stop changing. Returns whether the wait finished on a stable frame.
    public func waitUntilSettled(timeoutMs: Int = 3000) async throws -> Bool {
        let timeout = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var previous: CGImage?
        var settled = false

        while Date() < timeout {
            guard let current = latestImage else {
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            if FrameSettle.isSettled(previous: previous, current: current) {
                settled = true
                break
            }
            previous = current
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        guard latestImage != nil else {
            throw CableTapperError.screenUnavailable("is the iPhone connected by USB and unlocked?")
        }
        return settled
    }

    public func captureAgentJPEG(settled: Bool, coordinates: Bool = false) throws -> Screenshot {
        guard let image = latestImage else {
            throw CableTapperError.screenUnavailable("is the iPhone connected by USB and unlocked?")
        }
        var scaled = Self.downscaledForAgent(image)
        if coordinates {
            scaled = CoordinateGrid.draw(on: scaled)
        }
        let data = try Self.encodeJPEG(scaled, quality: Self.agentJPEGQuality)
        return Screenshot(jpegData: data, width: scaled.width, height: scaled.height, settled: settled)
    }

    public func currentCGImage() -> CGImage? { latestImage }

    private func startOnce(timeoutSeconds: TimeInterval) async throws {
        if started, latestImage != nil { return }
        try await ensureCameraAuthorized()
        phase = .searching

        // Warm discovery so connection notifications fire.
        _ = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        ).devices

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let device = findIPhoneDevice() {
                try configure(device: device)
                started = true
                phase = .waitingForFrame
                let frameDeadline = Date().addingTimeInterval(5)
                while latestImage == nil, Date() < frameDeadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if latestImage == nil {
                    throw CableTapperError.screenUnavailable("capture started but no frames yet")
                }
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw CableTapperError.screenUnavailable("no USB iPhone video device found")
    }

    private func ensureCameraAuthorized() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                try denyCamera()
            }
        case .denied, .restricted:
            try denyCamera()
        @unknown default:
            return
        }
    }

    private func denyCamera() throws -> Never {
        let message = "Allow Camera in System Settings to see the iPhone screen."
        phase = .failed(message)
        throw CableTapperError.screenUnavailable("camera permission denied")
    }

    private func findIPhoneDevice() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        ).devices
        return devices.first
    }

    private func configure(device: AVCaptureDevice) throws {
        try installInput(device)
        if !session.isRunning {
            session.startRunning()
        }
    }

    private func installInput(_ device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CableTapperError.screenUnavailable("cannot add capture input")
        }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw CableTapperError.screenUnavailable("cannot add capture output")
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    private func observeDisconnects() {
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let uniqueID = (note.object as? AVCaptureDevice)?.uniqueID
            Task { @MainActor in
                self?.handleDisconnect(uniqueID: uniqueID)
            }
        }
    }

    private func handleDisconnect(uniqueID: String?) {
        guard let uniqueID else { return }
        guard started || latestImage != nil || session.isRunning else { return }
        let currentID = (session.inputs.first as? AVCaptureDeviceInput)?.device.uniqueID
        if let currentID, currentID != uniqueID { return }
        resetCapture(phase: .searching)
    }

    private func resetCapture(phase next: CapturePhase) {
        latestImage = nil
        latestSize = (0, 0)
        started = false
        phase = next
        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
    }

    private static func allowScreenCaptureDevices() {
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &prop,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
    }

    nonisolated static func downscaledForAgent(_ image: CGImage) -> CGImage {
        let size = agentPixelSize(rawWidth: image.width, rawHeight: image.height)
        if size.width == image.width, size.height == image.height { return image }
        guard let ctx = CGContext(
            data: nil,
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return ctx.makeImage() ?? image
    }

    nonisolated static func encodeJPEG(_ image: CGImage, quality: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw CableTapperError.internalError("JPEG encoder unavailable")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CableTapperError.internalError("JPEG encode failed")
        }
        return data as Data
    }
}

extension ScreenCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    public nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent) else { return }
        let width = cgImage.width
        let height = cgImage.height
        Task { @MainActor in
            guard self.started else { return }
            self.latestImage = cgImage
            self.latestSize = (width, height)
            self.phase = .live(width: width, height: height)
        }
    }
}
