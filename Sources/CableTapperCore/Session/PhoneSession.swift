import Foundation

@MainActor
public final class PhoneSession {
    public let hid: HIDController
    public let screen: ScreenCapture
    public let gestures: GestureEngine

    public var defaultSettleMs: Int = 3000

    private var gestureJobs: [() async -> Void] = []
    private var drainingGestures = false
    private var dragAim: DragAim?
    private var dragGeneration = 0
    private var dragLoop: Task<Void, Never>?
    private var dragWait: CheckedContinuation<Void, Never>?
    private var dragFinish: CheckedContinuation<Void, Never>?
    private var dragDone = true

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

    /// Tap a screenshot pixel. Waits behind any in-flight gesture or settled tool call.
    public func mirrorTap(x: Double, y: Double) async {
        await serialized {
            self.syncPointerScreenSize()
            try? await self.gestures.tap(x: x, y: y)
        }
    }

    /// Follow the pointer while a mirror drag is in progress. The button goes down once, then tracks.
    public func mirrorDragChanged(startX: Double, startY: Double, x: Double, y: Double, updatesTarget: Bool = true) {
        if var aim = dragAim {
            guard updatesTarget, !aim.ended else { return }
            aim.x = x
            aim.y = y
            dragAim = aim
            dragGeneration += 1
            wakeDragWait()
            return
        }
        guard dragLoop == nil else { return }
        dragAim = DragAim(startX: startX, startY: startY, x: x, y: y, ended: false)
        dragDone = false
        dragGeneration += 1
        dragLoop = Task { @MainActor in
            await self.serialized {
                await self.runLiveDrag()
            }
        }
    }

    /// Finish the in-flight mirror drag at `x`/`y`. A nil endpoint releases at the last point inside the video.
    public func mirrorDragEnded(startX: Double?, startY: Double?, x: Double?, y: Double?) async {
        if dragAim == nil {
            guard dragLoop == nil, let startX, let startY, let x, let y else { return }
            mirrorDragChanged(startX: startX, startY: startY, x: x, y: y)
        } else if let x, let y, dragAim?.ended != true {
            dragAim?.x = x
            dragAim?.y = y
            dragGeneration += 1
        }
        guard dragAim != nil else { return }
        dragAim?.ended = true
        dragGeneration += 1
        wakeDragWait()
        await waitUntilDragFinished()
    }

    @discardableResult
    public func withSettledScreenshot(
        settleMs: Int? = nil,
        actionNote: String,
        body: @escaping () async throws -> Void
    ) async -> ToolResult {
        await serialized {
            await self.settledScreenshot(settleMs: settleMs, actionNote: actionNote, body: body)
        }
    }

    private func settledScreenshot(
        settleMs: Int?,
        actionNote: String,
        body: @escaping () async throws -> Void
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

    private struct DragAim {
        var startX: Double
        var startY: Double
        var x: Double
        var y: Double
        var ended: Bool
    }

    private func runLiveDrag() async {
        var pressed = false
        defer {
            if pressed {
                gestures.releasePointer()
            }
            dragAim = nil
            dragLoop = nil
            dragDone = true
            wakeDragWait()
            let finish = dragFinish
            dragFinish = nil
            finish?.resume()
        }
        guard let aim = dragAim else { return }
        syncPointerScreenSize()
        do {
            try await gestures.moveTo(x: aim.startX, y: aim.startY)
            gestures.pressPointer()
            pressed = true
            while let aim = dragAim {
                let generation = dragGeneration
                if !gestures.isPointerNear(x: aim.x, y: aim.y) {
                    try await gestures.moveWhilePressed(toX: aim.x, toY: aim.y) {
                        self.dragGeneration != generation
                    }
                    continue
                }
                if aim.ended { break }
                await waitForDragChange(since: generation)
            }
        } catch {
            return
        }
    }

    private func waitForDragChange(since generation: Int) async {
        if dragGeneration != generation || dragAim?.ended == true { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if dragGeneration != generation || dragAim?.ended == true {
                continuation.resume()
                return
            }
            dragWait = continuation
        }
    }

    private func wakeDragWait() {
        let waiter = dragWait
        dragWait = nil
        waiter?.resume()
    }

    private func waitUntilDragFinished() async {
        if dragDone { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if dragDone {
                continuation.resume()
                return
            }
            dragFinish = continuation
        }
    }

    private func syncPointerScreenSize() {
        let size = screen.frameSize
        if size.width > 0, size.height > 0 {
            gestures.updateScreenSize(width: size.width, height: size.height)
        }
    }

    /// Runs gesture work one at a time so pointer position and HID reports stay in order.
    private func serialized<T>(_ body: @MainActor @escaping () async -> T) async -> T {
        await withCheckedContinuation { continuation in
            gestureJobs.append {
                let value = await body()
                continuation.resume(returning: value)
            }
            drainGestures()
        }
    }

    private func drainGestures() {
        guard !drainingGestures else { return }
        drainingGestures = true
        Task { @MainActor in
            while !self.gestureJobs.isEmpty {
                let job = self.gestureJobs.removeFirst()
                await job()
            }
            self.drainingGestures = false
            if !self.gestureJobs.isEmpty {
                self.drainGestures()
            }
        }
    }
}
