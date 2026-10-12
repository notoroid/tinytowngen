import Foundation
@testable import TinyTownCore

/// Pixel comparison of an expected and an actual golden image.
struct GoldenDiff {
    static let changedColor = RGBA(255, 0, 0)

    /// Changed pixels in `changedColor`; unchanged ones as a dimmed grey copy of `actual`.
    /// Covers the larger of the two sizes; pixels only one image has count as changed.
    let image: Bitmap
    let changed: Int
    /// Inclusive bounding box (x0, y0, x1, y1) of changed pixels, nil when none changed.
    let bounds: (Int, Int, Int, Int)?

    init(expected: Bitmap, actual: Bitmap) {
        let w = max(expected.width, actual.width), h = max(expected.height, actual.height)
        var out = Bitmap(width: w, height: h)
        var count = 0
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        for y in 0..<h {
            for x in 0..<w {
                let inE = x < expected.width && y < expected.height
                let inA = x < actual.width && y < actual.height
                let same = inE && inA && expected.pixel(x, y) == actual.pixel(x, y)
                if same {
                    let p = actual.pixel(x, y)
                    let grey = UInt8((Int(p.r) * 30 + Int(p.g) * 59 + Int(p.b) * 11) / 100 * 35 / 100)
                    out.fillRect(x: x, y: y, w: 1, h: 1, color: RGBA(grey, grey, grey))
                } else {
                    out.fillRect(x: x, y: y, w: 1, h: 1, color: GoldenDiff.changedColor)
                    count += 1
                    x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
                }
            }
        }
        image = out
        changed = count
        bounds = count > 0 ? (x0, y0, x1, y1) : nil
    }

    var summary: String {
        guard let (x0, y0, x1, y1) = bounds else { return "no pixel differs (hash change only)" }
        let total = image.width * image.height
        return "\(changed) of \(total) pixels differ, within x \(x0)-\(x1), y \(y0)-\(y1) (1x coordinates)"
    }
}
