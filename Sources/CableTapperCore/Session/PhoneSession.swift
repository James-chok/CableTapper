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
    /// Grayscale sample of the last JPEG actually attached to a tool result.
    private var lastSentThumbnail: Data?

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

    /// Settled screenshot for `screenshot` and `wait`. Always attaches a JPEG.
    public func captureSettledScreenshot(settleMs: Int? = nil) async -> ToolResult {
        await serialized {
            do {
                try await self.startScreen()
            } catch {
                return .fail(error.localizedDescription)
            }
            return await self.finishSettled(settleMs: settleMs, actionNote: nil, policy: .always)
        }
    }

    /// Runs a gesture, waits for the screen to settle, then optionally attaches a JPEG.
    @discardableResult
    public func withSettledScreenshot(
        settleMs: Int? = nil,
        actionNote: String,
        includeScreenshot: Bool = false,
        body: @escaping () async throws -> Void
    ) async -> ToolResult {
        await serialized {
            // home and back measure from the pointer size, which stays in raw frame pixels.
            self.syncPointerScreenSize()
            do {
                try await body()
            } catch {
                return self.failureShot(error, policy: includeScreenshot ? .ifChanged : .omit)
            }
            return await self.finishSettled(
                settleMs: settleMs,
                actionNote: actionNote,
                policy: includeScreenshot ? .ifChanged : .omit
            )
        }
    }

    private enum ShotPolicy {
        /// Text only. The settle wait still runs so the next coordinate is not chosen mid-animation.
        case omit
        /// Attach a JPEG only when the frame differs from the last image sent to the agent.
        case ifChanged
        /// Always attach a JPEG. Used when the agent asked to see the screen.
        case always
    }

    private func finishSettled(
        settleMs: Int?,
        actionNote: String?,
        policy: ShotPolicy
    ) async -> ToolResult {
        let settled: Bool
        do {
            settled = try await screen.waitUntilSettled(timeoutMs: settleMs ?? defaultSettleMs)
        } catch {
            return self.failureShot(error, policy: policy)
        }
        // Gesture mapping stays in raw frame pixels. The JPEG size is a smaller coordinate space.
        syncPointerScreenSize()
        guard policy != .omit else {
            return .ok(actionNote ?? "ok")
        }
        return self.attachScreenshot(actionNote: actionNote, settled: settled, policy: policy, isError: false)
    }

    private func failureShot(_ error: Error, policy: ShotPolicy) -> ToolResult {
        guard policy != .omit else { return .fail(error.localizedDescription) }
        return attachScreenshot(
            actionNote: error.localizedDescription,
            settled: false,
            policy: policy,
            isError: true
        )
    }

    private func attachScreenshot(
        actionNote: String?,
        settled: Bool,
        policy: ShotPolicy,
        isError: Bool
    ) -> ToolResult {
        let thumbnail = screen.currentThumbnail()
        let agent = screen.agentPixelSize()
        if policy == .ifChanged,
           let thumbnail,
           let lastSentThumbnail,
           FrameSettle.isSimilar(lastSentThumbnail, thumbnail) {
            let line = "screen unchanged. coordinates \(agent.width)x\(agent.height)."
            let text = actionNote.map { "\($0)\n\(line)" } ?? line
            return isError ? .fail(text) : .ok(text)
        }
        do {
            let shot = try screen.captureAgentJPEG(settled: settled)
            if let thumbnail {
                lastSentThumbnail = thumbnail
            }
            let settleNote = shot.settled ? "screen settled" : "screen still moving"
            let line = "Screenshot \(shot.width)x\(shot.height) px. \(settleNote)."
            let text = actionNote.map { "\($0)\n\(line)" } ?? line
            return isError ? .fail(text, jpeg: shot.jpegData) : .ok(text, jpeg: shot.jpegData)
        } catch {
            if isError, let actionNote {
                return .fail(actionNote)
            }
            let text = actionNote.map { "\($0)\n\(error.localizedDescription)" } ?? error.localizedDescription
            return .fail(text)
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
