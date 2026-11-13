import AppKit
import AVFoundation
import CableTapperCore
import SwiftUI

struct MirrorView: View {
    @ObservedObject private var screen: ScreenCapture
    private let session: PhoneSession
    @State private var isDragging = false

    init(session: PhoneSession) {
        self.session = session
        _screen = ObservedObject(wrappedValue: session.screen)
    }

    var body: some View {
        VStack(spacing: 8) {
            mirrorContent
                .aspectRatio(9.0 / 19.5, contentMode: .fit)
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            statusLine
                .frame(height: 16)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await screen.maintain() }
    }

    /// The preview NSView draws above SwiftUI siblings on macOS, so show it or the placeholder, never both.
    @ViewBuilder
    private var mirrorContent: some View {
        if let overlay = overlayText {
            placeholder(overlay.text, showsSpinner: overlay.showsSpinner, isError: overlay.isError)
        } else {
            GeometryReader { proxy in
                CapturePreview(session: screen.captureSession)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .gesture(pointerGestures(in: proxy.size))
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if case .live(let width, let height) = screen.phase {
            Text("\(width)x\(height)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(" ")
                .font(.caption)
        }
    }

    private var overlayText: (text: String, showsSpinner: Bool, isError: Bool)? {
        switch screen.phase {
        case .searching:
            ("Plug in and unlock iPhone", true, false)
        case .waitingForFrame:
            ("Waiting for the iPhone screen", true, false)
        case .failed(let message):
            (message, false, true)
        case .live:
            nil
        }
    }

    private func pointerGestures(in viewSize: CGSize) -> some Gesture {
        let drag = DragGesture(minimumDistance: VideoPointMap.dragThreshold)
            .onChanged { value in
                guard isDragging || VideoPointMap.isDrag(value.translation) else { return }
                guard let start = pixel(at: value.startLocation, in: viewSize) else { return }
                isDragging = true
                if let current = pixel(at: value.location, in: viewSize) {
                    session.mirrorDragChanged(startX: start.x, startY: start.y, x: current.x, y: current.y)
                } else {
                    session.mirrorDragChanged(
                        startX: start.x,
                        startY: start.y,
                        x: start.x,
                        y: start.y,
                        updatesTarget: false
                    )
                }
            }
            .onEnded { value in
                let wasDragging = isDragging
                isDragging = false
                guard wasDragging || VideoPointMap.isDrag(value.translation) else {
                    // On macOS a plain click can end the drag gesture, which then blocks the tap gesture.
                    tap(at: value.startLocation, in: viewSize)
                    return
                }
                let start = pixel(at: value.startLocation, in: viewSize)
                let end = pixel(at: value.location, in: viewSize)
                Task {
                    await session.mirrorDragEnded(startX: start?.x, startY: start?.y, x: end?.x, y: end?.y)
                }
            }
        let tap = SpatialTapGesture()
            .onEnded { value in
                tap(at: value.location, in: viewSize)
            }
        return drag.exclusively(before: tap)
    }

    private func tap(at location: CGPoint, in viewSize: CGSize) {
        guard let point = pixel(at: location, in: viewSize) else { return }
        Task { await session.mirrorTap(x: point.x, y: point.y) }
    }

    private func pixel(at point: CGPoint, in viewSize: CGSize) -> (x: Double, y: Double)? {
        let size = screen.frameSize
        let videoRect = VideoPointMap.aspectFitRect(
            videoWidth: size.width,
            videoHeight: size.height,
            in: viewSize
        )
        return VideoPointMap.pixel(at: point, in: videoRect, width: size.width, height: size.height)
    }

    private func placeholder(_ text: String, showsSpinner: Bool, isError: Bool) -> some View {
        VStack(spacing: 12) {
            if showsSpinner {
                ProgressView()
                    .controlSize(.small)
            }
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary)
    }
}

enum VideoPointMap {
    static let dragThreshold: CGFloat = 4

    static func isDrag(_ translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) >= dragThreshold
    }

    /// Letterboxed picture rect for `AVLayerVideoGravity.resizeAspect`, origin at the top left.
    static func aspectFitRect(videoWidth: Int, videoHeight: Int, in viewSize: CGSize) -> CGRect {
        guard videoWidth > 0, videoHeight > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / CGFloat(videoWidth), viewSize.height / CGFloat(videoHeight))
        let fitted = CGSize(width: CGFloat(videoWidth) * scale, height: CGFloat(videoHeight) * scale)
        return CGRect(
            x: (viewSize.width - fitted.width) / 2,
            y: (viewSize.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    /// Maps a top-left view point into capture-buffer pixels. Points in the letterbox return nil.
    static func pixel(
        at point: CGPoint,
        in videoRect: CGRect,
        width: Int,
        height: Int
    ) -> (x: Double, y: Double)? {
        guard width > 0, height > 0, videoRect.width > 0, videoRect.height > 0 else { return nil }
        guard videoRect.contains(point) else { return nil }
        let nx = (point.x - videoRect.minX) / videoRect.width
        let ny = (point.y - videoRect.minY) / videoRect.height
        return (Double(nx) * Double(width), Double(ny) * Double(height))
    }
}

private struct CapturePreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CapturePreviewView {
        let view = CapturePreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: CapturePreviewView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
        nsView.updateMirroring()
    }
}

private final class CapturePreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        layer = previewLayer
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        updateMirroring()
    }

    func updateMirroring() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirrored {
            connection.isVideoMirrored = false
        }
    }
}
