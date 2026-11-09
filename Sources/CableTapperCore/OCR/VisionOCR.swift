import CoreGraphics
import Foundation
import Vision

public struct OCRLine: Sendable {
    public var text: String
    public var centerX: Int
    public var centerY: Int
    public var boxX: Int
    public var boxY: Int
    public var boxW: Int
    public var boxH: Int
}

public enum VisionOCR {
    public static func recognize(in image: CGImage, query: String? = nil, exact: Bool = false) async throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let width = image.width
        let height = image.height
        let observations = request.results ?? []

        var lines: [OCRLine] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let box = observation.boundingBox
            // Vision is bottom-left normalized; convert to top-left pixels.
            let boxX = Int(box.origin.x * CGFloat(width))
            let boxH = Int(box.size.height * CGFloat(height))
            let boxW = Int(box.size.width * CGFloat(width))
            let boxY = Int((1 - box.origin.y - box.size.height) * CGFloat(height))
            let centerX = boxX + boxW / 2
            let centerY = boxY + boxH / 2
            lines.append(
                OCRLine(
                    text: candidate.string,
                    centerX: centerX,
                    centerY: centerY,
                    boxX: boxX,
                    boxY: boxY,
                    boxW: boxW,
                    boxH: boxH
                )
            )
        }

        lines.sort { $0.centerY < $1.centerY || ($0.centerY == $1.centerY && $0.centerX < $1.centerX) }

        guard let query, !query.isEmpty else { return lines }
        return lines.filter { line in
            if exact {
                return line.text.caseInsensitiveCompare(query) == .orderedSame
            }
            return line.text.range(of: query, options: .caseInsensitive) != nil
        }
    }
}
