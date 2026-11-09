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

    public static func meanAbsoluteDifference(_ a: CGImage, _ b: CGImage) -> Double {
        let width = min(a.width, b.width, 80)
        let height = min(a.height, b.height, 140)
        guard width > 0, height > 0 else { return .greatestFiniteMagnitude }

        guard
            let ctxA = grayscaleContext(width: width, height: height),
            let ctxB = grayscaleContext(width: width, height: height)
        else {
            return .greatestFiniteMagnitude
        }

        ctxA.draw(a, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctxB.draw(b, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let dataA = ctxA.data, let dataB = ctxB.data else {
            return .greatestFiniteMagnitude
        }

        let ptrA = dataA.bindMemory(to: UInt8.self, capacity: width * height)
        let ptrB = dataB.bindMemory(to: UInt8.self, capacity: width * height)
        var sum = 0
        let count = width * height
        for i in 0 ..< count {
            sum += abs(Int(ptrA[i]) - Int(ptrB[i]))
        }
        return Double(sum) / Double(count)
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
