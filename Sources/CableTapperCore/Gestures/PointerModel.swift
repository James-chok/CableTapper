import Foundation

/// Maps screenshot pixels onto the absolute HID pointer range.
public struct PointerModel: Sendable {
    /// Last pointer position in screenshot pixels.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(
        x: Double = 0,
        y: Double = 0,
        width: Double = 591,
        height: Double = 1280
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public mutating func updateScreenSize(width: Double, height: Double) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        x = min(max(x, 0), self.width - 1)
        y = min(max(y, 0), self.height - 1)
    }

    public func hidPoint(x: Double, y: Double) -> (x: UInt16, y: UInt16) {
        (Self.axis(x, length: width), Self.axis(y, length: height))
    }

    /// Targets pixel centres, so the first and last pixels both land inside the screen.
    private static func axis(_ value: Double, length: Double) -> UInt16 {
        let maximum = Double(MouseReport.maxCoordinate)
        let clamped = min(max(value, 0), length - 1)
        let scaled = (clamped + 0.5) / length * maximum
        return UInt16(min(max(scaled.rounded(), 0), maximum))
    }
}
