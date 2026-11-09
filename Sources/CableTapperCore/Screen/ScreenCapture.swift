import AVFoundation
import CoreImage
import CoreMediaIO
import Foundation
import ImageIO

public struct Screenshot: Sendable {
    public var jpegData: Data
    public var width: Int
    public var height: Int
    public var settled: Bool
}

@MainActor
public final class ScreenCapture: NSObject {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "cabletapper.screen")
    private let ciContext = CIContext(options: nil)

    private var latestImage: CGImage?
    private var latestSize: (Int, Int) = (0, 0)
    private var started = false

    public override init() {
        super.init()
        Self.allowScreenCaptureDevices()
    }

    public var hasFrame: Bool { latestImage != nil }

    public var frameSize: (width: Int, height: Int) { latestSize }

    public func start(timeoutSeconds: TimeInterval = 12) async throws {
        if started, latestImage != nil { return }

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
                // Wait briefly for first frame.
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

    public func stop() {
        if session.isRunning { session.stopRunning() }
        started = false
    }

    public func captureJPEG(quality: CGFloat = 0.7) throws -> Screenshot {
        guard let image = latestImage else {
            throw CableTapperError.screenUnavailable("is the iPhone connected by USB and unlocked?")
        }
        let data = try Self.encodeJPEG(image, quality: quality)
        return Screenshot(jpegData: data, width: image.width, height: image.height, settled: true)
    }

    public func waitForSettle(timeoutMs: Int = 3000) async throws -> Screenshot {
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

        guard let image = latestImage else {
            throw CableTapperError.screenUnavailable("is the iPhone connected by USB and unlocked?")
        }
        let data = try Self.encodeJPEG(image, quality: 0.7)
        return Screenshot(
            jpegData: data,
            width: image.width,
            height: image.height,
            settled: settled
        )
    }

    public func currentCGImage() -> CGImage? { latestImage }

    private func findIPhoneDevice() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        ).devices
        return devices.first
    }

    private func configure(device: AVCaptureDevice) throws {
        session.beginConfiguration()
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
        session.commitConfiguration()

        if !session.isRunning {
            session.startRunning()
        }
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
        Task { @MainActor in
            self.latestImage = cgImage
            self.latestSize = (cgImage.width, cgImage.height)
        }
    }
}
