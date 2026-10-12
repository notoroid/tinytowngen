import Foundation
import Testing
@testable import TinyTownCore

/// The pure-Swift encoder is checked against ImageIO as an independent decoder (macOS only).
#if canImport(ImageIO)
@Suite struct PNGEncoderTests {
    private func roundTrip(_ b: Bitmap) throws -> Bitmap {
        try ImageIOReference.decode(PNGEncoder.encode(b))
    }

    /// Deterministic pseudo-random opaque image (defeats LZ77, exercises literals).
    private func noise(_ w: Int, _ h: Int, seed: UInt64 = 1) -> Bitmap {
        var b = Bitmap(width: w, height: h)
        var s = seed
        for i in Swift.stride(from: 0, to: b.pixels.count, by: 4) {
            for c in 0..<3 {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                b.pixels[i + c] = UInt8(s >> 56)
            }
            b.pixels[i + 3] = 255
        }
        return b
    }

    @Test func checksumsMatchKnownVectors() {
        #expect(PNGEncoder.crc32(Array("IEND".utf8)) == 0xAE42_6082)
        #expect(PNGEncoder.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(PNGEncoder.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(PNGEncoder.adler32([UInt8](repeating: 0xFF, count: 100_000)) == 0x149A_302C)  // zlib.adler32(b"\xff" * 100000)
    }

    @Test func headerIsRGBA8() {
        let d = [UInt8](PNGEncoder.encode(Bitmap(width: 3, height: 2)))
        #expect(Array(d[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(Array(d[12..<16]) == Array("IHDR".utf8))
        #expect(Array(d[16..<24]) == [0, 0, 0, 3, 0, 0, 0, 2])
        #expect(Array(d[24..<29]) == [8, 6, 0, 0, 0])
        #expect(Array(d.suffix(8)) == Array("IEND".utf8) + [0xAE, 0x42, 0x60, 0x82])
    }

    @Test func renderedTownRoundTrips() throws {
        let p = try Planner.plan(LayoutParser.parse("U3{0,0} U2{9,4} B{5,2} CL{6,2} CR{6,2}#3 F{3} W{4,4-6} C*"),
                                 grid: GridSize(width: 13, height: 7), seed: 5, atlas: atlas)
        let img = Renderer.render(p, atlas: atlas, border: true)
        #expect(try roundTrip(img).pixels == img.pixels)
        let big = img.scaled(by: 3)  // long runs: max-length matches and far distances
        #expect(try roundTrip(big).pixels == big.pixels)
    }

    @Test(arguments: [(1, 1), (2, 3), (7, 5), (300, 1), (1, 300), (129, 67)])
    func noiseRoundTrips(_ size: (Int, Int)) throws {
        let img = noise(size.0, size.1)
        #expect(try roundTrip(img).pixels == img.pixels)
    }

    @Test func uniformImageCompressesWell() throws {
        let img = Bitmap(width: 512, height: 512, fill: Metrics.roadColor)
        let data = PNGEncoder.encode(img)
        // 1 MiB of raw pixels. Fixed Huffman needs ~13 bits per 258-byte match, so ~7.7 KB is the floor.
        #expect(data.count < 10_000)
        #expect(try roundTrip(img).pixels == img.pixels)
    }

    @Test func transparencyRoundTrips() throws {
        // The atlas has fully transparent gaps; opaque and clear pixels must survive exactly.
        let back = try roundTrip(atlas.image)
        #expect(back.pixels == atlas.image.pixels)
        // Partial alpha is stored unpremultiplied, so allow 1 step of rounding.
        var b = Bitmap(width: 2, height: 1)
        b.fillRect(x: 0, y: 0, w: 1, h: 1, color: RGBA(60, 30, 10, 128))
        b.fillRect(x: 1, y: 0, w: 1, h: 1, color: RGBA(1, 2, 3, 7))
        let r = try roundTrip(b)
        for (x, y) in zip(b.pixels, r.pixels) { #expect(abs(Int(x) - Int(y)) <= 1) }
    }

    @Test func writePNGReportsUnwritablePath() {
        #expect(throws: TownError.self) {
            try Bitmap(width: 1, height: 1).writePNG(to: URL(fileURLWithPath: "/nonexistent/dir/out.png"))
        }
    }
}
#endif
