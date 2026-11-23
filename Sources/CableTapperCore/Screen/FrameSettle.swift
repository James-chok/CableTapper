import CoreGraphics
import Foundation

public enum FrameSettle {
    /// Returns true when consecutive frames are similar enough.
    public static func isSettled(
        previous: CGImage?,
        current: CGImage,
        threshold: Double = 2.5
    ) -> Bool {
        guard let previous else { return false }
        let score = meanAbsoluteDifference(previous, current)
        return score < threshold
    }

    /// Grayscale sample used to decide whether the screen changed.
    public static func thumbnailData(_ image: CGImage) -> Data? {
        let width = min(image.width, 80)
        let height = min(image.height, 140)
        guard width > 0, height > 0 else { return nil }
        guard let ctx = grayscaleContext(width: width, height: height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pointer = ctx.data else { return nil }
        return Data(UnsafeRawBufferPointer(start: pointer, count: width * height))
    }

    public static func isSimilar(_ previous: Data, _ current: Data, threshold: Double = 2.5) -> Bool {
        meanAbsoluteDifference(previous, current) < threshold
    }

    public static func meanAbsoluteDifference(_ a: CGImage, _ b: CGImage) -> Double {
        guard let left = thumbnailData(a), let right = thumbnailData(b) else {
            return .greatestFiniteMagnitude
        }
        return meanAbsoluteDifference(left, right)
    }

    public static func meanAbsoluteDifference(_ a: Data, _ b: Data) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var sum = 0
        for index in 0 ..< a.count {
            sum += abs(Int(a[index]) - Int(b[index]))
        }
        return Double(sum) / Double(a.count)
    }

    private static func grayscaleContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
    }
}
