#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
@testable import TinyTownCore

/// Independent PNG decoder (ImageIO) used to cross-check `PNGEncoder` / `PNGDecoder` on macOS.
enum ImageIOReference {
    static func decode(_ data: Data) throws -> Bitmap {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw TownError.resource("ImageIO cannot decode PNG")
        }
        var b = Bitmap(width: img.width, height: img.height)
        b.pixels.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                                bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
        return b
    }
}
#endif
