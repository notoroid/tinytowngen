import Foundation

/// RGBA8 premultiplied pixel buffer, row 0 at the top.
public struct Bitmap: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, fill: RGBA = RGBA(0, 0, 0, 0)) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        fillRect(x: 0, y: 0, w: width, h: height, color: fill)
    }

    init(pngData: Data) throws {
        self = try PNGDecoder.decode(pngData)
    }

    public func pixel(_ x: Int, _ y: Int) -> RGBA {
        let i = (y * width + x) * 4
        return RGBA(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    public mutating func fillRect(x: Int, y: Int, w: Int, h: Int, color: RGBA) {
        for yy in max(0, y)..<min(height, y + h) {
            for xx in max(0, x)..<min(width, x + w) {
                let i = (yy * width + xx) * 4
                pixels[i] = color.r; pixels[i + 1] = color.g; pixels[i + 2] = color.b; pixels[i + 3] = color.a
            }
        }
    }

    /// Draws `src` into the destination rectangle. Along each axis the source is
    /// center-cropped when larger than the destination and nearest-neighbour
    /// stretched when smaller, so pixel art is never blurred.
    public mutating func blitFit(_ atlas: Bitmap, _ src: AtlasRect, dx: Int, dy: Int, dw: Int, dh: Int) {
        let (sx, sw) = Bitmap.cropAxis(src.x, src.w, dw)
        let (sy, sh) = Bitmap.cropAxis(src.y, src.h, dh)
        for y in 0..<dh {
            let ay = sy + y * sh / dh
            for x in 0..<dw {
                let ax = sx + x * sw / dw
                put(dx + x, dy + y, atlas.pixel(ax, ay))
            }
        }
    }

    /// Draws the whole of `src` into the destination rectangle without cropping.
    /// Axes that grow use nearest-neighbour; axes that shrink average the source
    /// pixels each destination pixel covers, so no detail is simply dropped.
    public mutating func blitScaled(_ atlas: Bitmap, _ src: AtlasRect, dx: Int, dy: Int, dw: Int, dh: Int) {
        for y in 0..<dh {
            let (y0, y1) = Bitmap.sourceRange(y, src.h, dh)
            for x in 0..<dw {
                let (x0, x1) = Bitmap.sourceRange(x, src.w, dw)
                var sum = (0, 0, 0, 0)
                for ay in y0..<y1 {
                    for ax in x0..<x1 {
                        let c = atlas.pixel(src.x + ax, src.y + ay)
                        sum.0 += Int(c.r); sum.1 += Int(c.g); sum.2 += Int(c.b); sum.3 += Int(c.a)
                    }
                }
                let n = (y1 - y0) * (x1 - x0)
                put(dx + x, dy + y, RGBA(UInt8(sum.0 / n), UInt8(sum.1 / n), UInt8(sum.2 / n), UInt8(sum.3 / n)))
            }
        }
    }

    /// Source pixels [lo, hi) covered by destination pixel `i` when mapping `len` source pixels onto `target`.
    private static func sourceRange(_ i: Int, _ len: Int, _ target: Int) -> (Int, Int) {
        let lo = i * len / target
        return (lo, max(lo + 1, (i + 1) * len / target))
    }

    /// Repeats `src` over the destination rectangle. `phaseX/phaseY` offset the
    /// pattern so adjacent segments line up seamlessly.
    public mutating func blitTiled(_ atlas: Bitmap, _ src: AtlasRect, dx: Int, dy: Int, dw: Int, dh: Int,
                                   phaseX: Int = 0, phaseY: Int = 0) {
        for y in 0..<dh {
            let ay = src.y + (y + phaseY) % src.h
            for x in 0..<dw {
                let ax = src.x + (x + phaseX) % src.w
                put(dx + x, dy + y, atlas.pixel(ax, ay))
            }
        }
    }

    private static func cropAxis(_ start: Int, _ len: Int, _ target: Int) -> (Int, Int) {
        len > target ? (start + (len - target) / 2, target) : (start, len)
    }

    /// Source-over composite of a premultiplied pixel.
    private mutating func put(_ x: Int, _ y: Int, _ c: RGBA) {
        guard x >= 0, y >= 0, x < width, y < height, c.a > 0 else { return }
        let i = (y * width + x) * 4
        let inv = 255 - Int(c.a)
        pixels[i] = UInt8(Int(c.r) + Int(pixels[i]) * inv / 255)
        pixels[i + 1] = UInt8(Int(c.g) + Int(pixels[i + 1]) * inv / 255)
        pixels[i + 2] = UInt8(Int(c.b) + Int(pixels[i + 2]) * inv / 255)
        pixels[i + 3] = UInt8(Int(c.a) + Int(pixels[i + 3]) * inv / 255)
    }

    /// The `src` region turned 90° clockwise: a w x h region becomes h x w,
    /// and the region's bottom-left pixel becomes the result's top-left.
    public func rotatedClockwise(_ src: AtlasRect) -> Bitmap {
        var out = Bitmap(width: src.h, height: src.w)
        for y in 0..<out.height {
            for x in 0..<out.width {
                let c = pixel(src.x + y, src.y + src.h - 1 - x)
                let d = (y * out.width + x) * 4
                out.pixels[d] = c.r; out.pixels[d + 1] = c.g; out.pixels[d + 2] = c.b; out.pixels[d + 3] = c.a
            }
        }
        return out
    }

    /// Integer nearest-neighbour upscale.
    public func scaled(by factor: Int) -> Bitmap {
        guard factor > 1 else { return self }
        var out = Bitmap(width: width * factor, height: height * factor)
        for y in 0..<out.height {
            for x in 0..<out.width {
                let s = ((y / factor) * width + x / factor) * 4
                let d = (y * out.width + x) * 4
                out.pixels[d..<d + 4] = pixels[s..<s + 4]
            }
        }
        return out
    }

    public func writePNG(to url: URL) throws {
        do {
            try PNGEncoder.encode(self).write(to: url)
        } catch {
            throw TownError.output("failed to write PNG to \(url.path): \(error.localizedDescription)")
        }
    }
}

public struct RGBA: Equatable, Sendable {
    public var r, g, b, a: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public init(hex: UInt32) {
        self.init(UInt8(hex >> 16 & 0xFF), UInt8(hex >> 8 & 0xFF), UInt8(hex & 0xFF))
    }
}
