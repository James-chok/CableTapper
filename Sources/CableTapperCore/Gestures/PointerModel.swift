import Foundation

/// Soft AssistiveTouch cursor in screenshot pixel space.
public struct PointerModel: Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Approximate screenshot-pixels moved per HID relative unit.
    public var pixelsPerHIDUnit: Double

    public init(
        x: Double = 0,
        y: Double = 0,
        width: Double = 591,
        height: Double = 1280,
        pixelsPerHIDUnit: Double = 2.5
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.pixelsPerHIDUnit = pixelsPerHIDUnit
    }

    public mutating func updateScreenSize(width: Double, height: Double) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        x = min(max(x, 0), self.width - 1)
        y = min(max(y, 0), self.height - 1)
    }

    public mutating func apply(dx: Int8, dy: Int8) {
        x = min(max(x + Double(dx) * pixelsPerHIDUnit, 0), width - 1)
        y = min(max(y + Double(dy) * pixelsPerHIDUnit, 0), height - 1)
    }

    /// Split a pixel delta into HID Int8 chunks.
    public func hidChunks(toX targetX: Double, toY targetY: Double) -> [(Int8, Int8)] {
        var remainingX = (targetX - x) / pixelsPerHIDUnit
        var remainingY = (targetY - y) / pixelsPerHIDUnit
        var chunks: [(Int8, Int8)] = []
        while abs(remainingX) > 0.5 || abs(remainingY) > 0.5 {
            let stepX = clampInt8(remainingX)
            let stepY = clampInt8(remainingY)
            if stepX == 0 && stepY == 0 { break }
            chunks.append((stepX, stepY))
            remainingX -= Double(stepX)
            remainingY -= Double(stepY)
            if chunks.count > 400 { break }
        }
        return chunks
    }

    private func clampInt8(_ value: Double) -> Int8 {
        Int8(max(-127, min(127, value.rounded())))
    }
}
