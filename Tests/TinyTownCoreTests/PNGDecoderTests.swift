import Foundation
import Testing
@testable import TinyTownCore

@Suite struct PNGDecoderTests {
    private var atlasPNG: Data { Data(base64Encoded: EmbeddedResources.patternsPNG)! }

    private func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = [], i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    // MARK: Inflate

    @Test func inflatesStoredBlock() throws {
        // zlib.compress(b"hello hello hello hello", 0)
        let z: [UInt8] = [120, 1, 1, 23, 0, 232, 255] + Array("hello hello hello hello".utf8) + [104, 3, 8, 177]
        #expect(try Inflate.zlib(z) == Array("hello hello hello hello".utf8))
    }

    @Test func inflatesDynamicHuffmanBlock() throws {
        // zlib.compress(text, 9) -> one dynamic-Huffman (BTYPE=2) block
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 3)
            + "Pack my box with five dozen liquor jugs! 0123456789"
        let z = hex("78dab5cbd91540301445d156ae062cf3d0850f0d04414c8f9020d57b4df83efbd4a3c461543ba3d1746fe8e9c164d6fd0459a971715e847bd1d1e0a3fe0d5782ddfaa26174ab6b44aface4e4e486451d8634bfc3e92108a33849b3bc283f7470412d")
        #expect((z[2] >> 1) & 3 == 2)
        #expect(try Inflate.zlib(z) == Array(text.utf8))
    }

    @Test func inflatesOwnFixedHuffmanOutput() throws {
        var data: [UInt8] = []
        for i in 0..<70_000 { data.append(UInt8(truncatingIfNeeded: i * 7 / 3)) }  // repeats + far matches
        #expect(try Inflate.zlib(Array(PNGEncoder.zlib(data))) == data)
    }

    @Test func rejectsCorruptStreams() {
        let good = [UInt8](PNGEncoder.zlib(Array("abcabcabc".utf8)))
        var badAdler = good; badAdler[badAdler.count - 1] ^= 1
        #expect(throws: TownError.self) { try Inflate.zlib(badAdler) }
        #expect(throws: TownError.self) { try Inflate.zlib([0x78, 0x02] + good.dropFirst(2)) }  // bad header check
        #expect(throws: TownError.self) { try Inflate.zlib(Array(good.prefix(5))) }               // truncated
    }

    // MARK: PNG

    @Test func atlasDecodes() throws {
        let b = try PNGDecoder.decode(atlasPNG)
        #expect(b.width == 253 && b.height == 253)
        #expect(b.pixel(10, 10) == RGBA(85, 85, 85))      // raw value, checked with Python zlib
        #expect(b.pixel(252, 0) == RGBA(0, 0, 0, 0))      // transparent gap
    }

    #if canImport(ImageIO)
    @Test func atlasMatchesImageIO() throws {
        #expect(try PNGDecoder.decode(atlasPNG).pixels == ImageIOReference.decode(atlasPNG).pixels)
    }
    #endif

    @Test func roundTripsThroughEncoder() throws {
        let p = try Planner.plan(LayoutParser.parse("U3{0,0} F{3} W{4} C*"), grid: GridSize(width: 13, height: 7),
                                 seed: 2, atlas: atlas)
        let img = Renderer.render(p, atlas: atlas, border: true).scaled(by: 2)
        #expect(try PNGDecoder.decode(PNGEncoder.encode(img)).pixels == img.pixels)
    }

    @Test func premultipliesPartialAlpha() throws {
        var b = Bitmap(width: 1, height: 1)
        b.fillRect(x: 0, y: 0, w: 1, h: 1, color: RGBA(100, 50, 0, 128))  // premultiplied input
        let back = try PNGDecoder.decode(PNGEncoder.encode(b))
        for (x, y) in zip(b.pixels, back.pixels) { #expect(abs(Int(x) - Int(y)) <= 1) }
    }

    @Test func rejectsBadFiles() {
        let good = [UInt8](PNGEncoder.encode(Bitmap(width: 2, height: 2)))
        #expect(throws: TownError.self) { try PNGDecoder.decode(Data("not a png".utf8)) }
        var badCRC = good; badCRC[29] ^= 0xFF                       // IHDR CRC byte
        #expect(throws: TownError.self) { try PNGDecoder.decode(Data(badCRC)) }
        #expect(throws: TownError.self) { try PNGDecoder.decode(Data(good.prefix(40))) }  // truncated
        // 16-bit depth is not supported: patch IHDR and fix its CRC.
        var deep = good
        deep[24] = 16
        let crc = PNGEncoder.crc32(deep[12..<29])
        deep[29...32] = [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
        #expect(throws: TownError.self) { try PNGDecoder.decode(Data(deep)) }
    }
}
