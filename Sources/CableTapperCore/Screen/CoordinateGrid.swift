import CoreGraphics
import CoreText
import Foundation

/// Labeled grid in returned-screenshot pixels. Origin is the top-left, matching tap coordinates.
enum CoordinateGrid {
    static let spacing = 50

    static func draw(on image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > spacing, height > spacing else { return image }
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let vertical = CGColor(red: 1, green: 0.12, blue: 0.18, alpha: 1)
        let horizontal = CGColor(red: 0.1, green: 0.4, blue: 1, alpha: 1)
        ctx.setShouldAntialias(false)
        ctx.setLineWidth(2)
        strokeLines(in: ctx, width: width, height: height, color: vertical, vertical: true)
        strokeLines(in: ctx, width: width, height: height, color: horizontal, vertical: false)

        ctx.setShouldAntialias(true)
        ctx.textMatrix = .identity
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 14, nil)
        let label = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let shadow = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        var x = spacing
        while x < width {
            drawLabel(
                String(x),
                in: ctx,
                font: font,
                color: label,
                shadow: shadow,
                x: CGFloat(x) + 4,
                baseline: CGFloat(height - 18),
                maxX: CGFloat(width - 2)
            )
            x += spacing
        }

        var agentY = spacing
        while agentY < height {
            // Context y grows upward. The label sits just above its horizontal line.
            let baseline = CGFloat(height - agentY) + 4
            drawLabel(
                String(agentY),
                in: ctx,
                font: font,
                color: label,
                shadow: shadow,
                x: 4,
                baseline: baseline,
                maxX: CGFloat(width - 2)
            )
            agentY += spacing
        }

        return ctx.makeImage() ?? image
    }

    private static func strokeLines(
        in ctx: CGContext,
        width: Int,
        height: Int,
        color: CGColor,
        vertical: Bool
    ) {
        ctx.setStrokeColor(color)
        ctx.beginPath()
        var value = spacing
        let limit = vertical ? width : height
        while value < limit {
            if vertical {
                let px = CGFloat(value) + 0.5
                ctx.move(to: CGPoint(x: px, y: 0))
                ctx.addLine(to: CGPoint(x: px, y: CGFloat(height)))
            } else {
                let py = CGFloat(height - value) + 0.5
                ctx.move(to: CGPoint(x: 0, y: py))
                ctx.addLine(to: CGPoint(x: CGFloat(width), y: py))
            }
            value += spacing
        }
        ctx.strokePath()
    }

    private static func drawLabel(
        _ text: String,
        in ctx: CGContext,
        font: CTFont,
        color: CGColor,
        shadow: CGColor,
        x: CGFloat,
        baseline: CGFloat,
        maxX: CGFloat
    ) {
        guard let line = textLine(text, font: font, color: color),
              let halo = textLine(text, font: font, color: shadow) else { return }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        var originX = x
        if originX + textWidth > maxX {
            originX = max(2, maxX - textWidth)
        }
        for offset in [CGPoint(x: 1, y: 0), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: -1)] {
            ctx.textPosition = CGPoint(x: originX + offset.x, y: baseline + offset.y)
            CTLineDraw(halo, ctx)
        }
        ctx.textPosition = CGPoint(x: originX, y: baseline)
        CTLineDraw(line, ctx)
    }

    private static func textLine(_ text: String, font: CTFont, color: CGColor) -> CTLine? {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
            return nil
        }
        return CTLineCreateWithAttributedString(attributed)
    }
}
