import Foundation

/// Pure-Swift PNG reader for 8-bit, non-interlaced RGBA or RGB images — what the
/// embedded atlas and `PNGEncoder` produce. Returns a premultiplied `Bitmap`.
/// Colour-management chunks (gAMA, cHRM, iCCP, ...) are ignored: pixel values are used as stored.
enum PNGDecoder {
    static func decode(_ data: Data) throws -> Bitmap {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else {
            throw fail("not a PNG file")
        }
        var pos = 8
        var width = 0, height = 0, channels = 0
        var idat: [UInt8] = []
        var sawEnd = false
        while pos + 12 <= bytes.count {
            let len = Int(be32(bytes, pos))
            let typeStart = pos + 4, bodyStart = pos + 8, bodyEnd = bodyStart + len
            guard bodyEnd + 4 <= bytes.count else { throw fail("truncated chunk") }
            let type = String(decoding: bytes[typeStart..<typeStart + 4], as: UTF8.self)
            guard PNGEncoder.crc32(bytes[typeStart..<bodyEnd]) == be32(bytes, bodyEnd) else {
                throw fail("CRC mismatch in \(type) chunk")
            }
            switch type {
            case "IHDR":
                guard len == 13 else { throw fail("bad IHDR") }
                width = Int(be32(bytes, bodyStart))
                height = Int(be32(bytes, bodyStart + 4))
                let depth = bytes[bodyStart + 8], color = bytes[bodyStart + 9], interlace = bytes[bodyStart + 12]
                guard depth == 8, color == 6 || color == 2, interlace == 0, width > 0, height > 0 else {
                    throw fail("unsupported format (need 8-bit RGBA/RGB, non-interlaced)")
                }
                channels = color == 6 ? 4 : 3
            case "IDAT":
                idat.append(contentsOf: bytes[bodyStart..<bodyEnd])
            case "IEND":
                sawEnd = true
            default:
                break  // ancillary chunks are not needed
            }
            pos = bodyEnd + 4
            if sawEnd { break }
        }
        guard channels > 0, sawEnd else { throw fail("missing IHDR or IEND") }

        let stride = width * channels
        let raw = try Inflate.zlib(idat, expectedSize: (stride + 1) * height)
        guard raw.count == (stride + 1) * height else { throw fail("image data has wrong size") }

        var out = Bitmap(width: width, height: height)
        var prev = [UInt8](repeating: 0, count: stride)
        var cur = [UInt8](repeating: 0, count: stride)
        for y in 0..<height {
            let row = y * (stride + 1)
            let filter = raw[row]
            for x in 0..<stride {
                let a = x >= channels ? Int(cur[x - channels]) : 0
                let b = Int(prev[x])
                let c = x >= channels ? Int(prev[x - channels]) : 0
                let p: Int
                switch filter {
                case 0: p = 0
                case 1: p = a
                case 2: p = b
                case 3: p = (a + b) / 2
                case 4:
                    let e = a + b - c, pa = abs(e - a), pb = abs(e - b), pc = abs(e - c)
                    p = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
                default: throw fail("unknown filter type \(filter)")
                }
                cur[x] = UInt8(truncatingIfNeeded: Int(raw[row + 1 + x]) + p)
            }
            for x in 0..<width {
                let s = x * channels, d = (y * width + x) * 4
                let alpha = channels == 4 ? Int(cur[s + 3]) : 255
                for k in 0..<3 {
                    // Premultiply, rounding to nearest like CoreGraphics.
                    out.pixels[d + k] = UInt8((Int(cur[s + k]) * alpha + 127) / 255)
                }
                out.pixels[d + 3] = UInt8(alpha)
            }
            swap(&prev, &cur)
        }
        return out
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func fail(_ m: String) -> TownError { .resource("PNG decode: \(m)") }
}

/// RFC 1950/1951 decompressor (stored, fixed and dynamic Huffman blocks).
enum Inflate {
    static func zlib(_ data: [UInt8], expectedSize: Int = 0) throws -> [UInt8] {
        guard data.count >= 6, (Int(data[0]) << 8 | Int(data[1])) % 31 == 0, data[0] & 0x0F == 8,
              data[1] & 0x20 == 0 else {
            throw TownError.resource("PNG decode: bad zlib header")
        }
        let out = try inflate(Array(data[2...]), expectedSize: expectedSize)
        let n = data.count
        let stored = UInt32(data[n - 4]) << 24 | UInt32(data[n - 3]) << 16 | UInt32(data[n - 2]) << 8 | UInt32(data[n - 1])
        guard PNGEncoder.adler32(out) == stored else { throw TownError.resource("PNG decode: Adler-32 mismatch") }
        return out
    }

    private struct BitReader {
        let bytes: [UInt8]
        var pos = 0, bit = 0

        mutating func read(_ n: Int) throws -> Int {
            var v = 0
            for k in 0..<n {
                guard pos < bytes.count else { throw TownError.resource("PNG decode: unexpected end of data") }
                v |= Int(bytes[pos] >> bit & 1) << k
                bit += 1
                if bit == 8 { bit = 0; pos += 1 }
            }
            return v
        }

        mutating func alignToByte() { if bit != 0 { bit = 0; pos += 1 } }
    }

    /// Canonical Huffman decoding table: `counts[len]` codes of each length, `symbols` in code order.
    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []

        init(lengths: [Int]) throws {
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var offsets = [Int](repeating: 0, count: 16)
            for l in 1..<16 { offsets[l] = offsets[l - 1] + counts[l - 1] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (s, l) in lengths.enumerated() where l > 0 {
                symbols[offsets[l]] = s
                offsets[l] += 1
            }
        }

        func decode(_ r: inout BitReader) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try r.read(1)
                let count = counts[len]
                if code - first < count { return symbols[index + code - first] }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            throw TownError.resource("PNG decode: invalid Huffman code")
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                     35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                      3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                   257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                   8193, 12289, 16385, 24577]
    private static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    /// Order in which code-length code lengths are stored in a dynamic block header.
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static let fixedLiterals = try! Huffman(lengths:
        [Int](repeating: 8, count: 144) + [Int](repeating: 9, count: 112) +
        [Int](repeating: 7, count: 24) + [Int](repeating: 8, count: 8))
    private static let fixedDistances = try! Huffman(lengths: [Int](repeating: 5, count: 30))

    static func inflate(_ data: [UInt8], expectedSize: Int = 0) throws -> [UInt8] {
        var r = BitReader(bytes: data)
        var out: [UInt8] = []
        out.reserveCapacity(expectedSize)
        var final = 0
        repeat {
            final = try r.read(1)
            switch try r.read(2) {
            case 0:
                r.alignToByte()
                guard r.pos + 4 <= data.count else { throw TownError.resource("PNG decode: truncated stored block") }
                let len = Int(data[r.pos]) | Int(data[r.pos + 1]) << 8
                let nlen = Int(data[r.pos + 2]) | Int(data[r.pos + 3]) << 8
                guard len == ~nlen & 0xFFFF, r.pos + 4 + len <= data.count else {
                    throw TownError.resource("PNG decode: bad stored block")
                }
                out.append(contentsOf: data[r.pos + 4..<r.pos + 4 + len])
                r.pos += 4 + len
            case 1:
                try inflateBlock(&r, &out, fixedLiterals, fixedDistances)
            case 2:
                let (lit, dist) = try readDynamicTables(&r)
                try inflateBlock(&r, &out, lit, dist)
            default:
                throw TownError.resource("PNG decode: invalid deflate block type")
            }
        } while final == 0
        return out
    }

    private static func readDynamicTables(_ r: inout BitReader) throws -> (Huffman, Huffman) {
        let hlit = try r.read(5) + 257, hdist = try r.read(5) + 1, hclen = try r.read(4) + 4
        var clLengths = [Int](repeating: 0, count: 19)
        for i in 0..<hclen { clLengths[codeLengthOrder[i]] = try r.read(3) }
        let cl = try Huffman(lengths: clLengths)

        var lengths: [Int] = []
        while lengths.count < hlit + hdist {
            let sym = try cl.decode(&r)
            switch sym {
            case 0...15: lengths.append(sym)
            case 16:
                guard let last = lengths.last else { throw TownError.resource("PNG decode: repeat with no previous length") }
                lengths += [Int](repeating: last, count: 3 + (try r.read(2)))
            case 17: lengths += [Int](repeating: 0, count: 3 + (try r.read(3)))
            default: lengths += [Int](repeating: 0, count: 11 + (try r.read(7)))
            }
        }
        guard lengths.count == hlit + hdist else { throw TownError.resource("PNG decode: code lengths overflow") }
        return (try Huffman(lengths: Array(lengths[0..<hlit])), try Huffman(lengths: Array(lengths[hlit...])))
    }

    private static func inflateBlock(_ r: inout BitReader, _ out: inout [UInt8], _ lit: Huffman, _ dist: Huffman) throws {
        while true {
            let sym = try lit.decode(&r)
            if sym < 256 {
                out.append(UInt8(sym))
            } else if sym == 256 {
                return
            } else {
                let li = sym - 257
                guard li < lengthBase.count else { throw TownError.resource("PNG decode: bad length code") }
                let len = lengthBase[li] + (try r.read(lengthExtra[li]))
                let di = try dist.decode(&r)
                guard di < distBase.count else { throw TownError.resource("PNG decode: bad distance code") }
                let d = distBase[di] + (try r.read(distExtra[di]))
                guard d <= out.count else { throw TownError.resource("PNG decode: distance too far back") }
                let start = out.count - d
                for k in 0..<len { out.append(out[start + k]) }  // byte by byte: copies may overlap
            }
        }
    }
}
