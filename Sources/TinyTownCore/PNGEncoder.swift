import Foundation

/// Pure-Swift PNG writer (RGBA 8-bit, non-interlaced), so output does not depend on ImageIO.
///
/// Each row gets the PNG filter with the smallest sum of absolute residuals, and the
/// filtered data is deflated with LZ77 + fixed Huffman codes.
enum PNGEncoder {
    static func encode(_ b: Bitmap) -> Data {
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.appendBE(UInt32(b.width))
        ihdr.appendBE(UInt32(b.height))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])  // 8-bit, RGBA, deflate, adaptive filter, no interlace
        appendChunk("IHDR", ihdr, to: &out)
        appendChunk("IDAT", zlib(filteredRows(b)), to: &out)
        appendChunk("IEND", Data(), to: &out)
        return out
    }

    private static func appendChunk(_ type: String, _ body: Data, to out: inout Data) {
        out.appendBE(UInt32(body.count))
        let typed = Data(type.utf8) + body
        out.append(typed)
        out.appendBE(crc32(typed))
    }

    // MARK: Filtering

    /// Straight (non-premultiplied) RGBA rows, each prefixed with its filter type byte.
    static func filteredRows(_ b: Bitmap) -> [UInt8] {
        let stride = b.width * 4
        var raw = [UInt8](repeating: 0, count: stride * b.height)
        for i in Swift.stride(from: 0, to: raw.count, by: 4) {
            let a = Int(b.pixels[i + 3])
            raw[i + 3] = UInt8(a)
            for c in 0..<3 {
                let v = Int(b.pixels[i + c])
                raw[i + c] = a == 255 || a == 0 ? UInt8(a == 0 ? 0 : v) : UInt8(min(255, (v * 255 + a / 2) / a))
            }
        }

        var out = [UInt8]()
        out.reserveCapacity((stride + 1) * b.height)
        var candidate = [UInt8](repeating: 0, count: stride)
        var best = [UInt8](repeating: 0, count: stride)
        for y in 0..<b.height {
            let row = y * stride, prev = row - stride
            var bestType: UInt8 = 0
            var bestScore = Int.max
            for type: UInt8 in 0...4 {
                var score = 0
                for x in 0..<stride {
                    let a = x >= 4 ? Int(raw[row + x - 4]) : 0
                    let up = y > 0 ? Int(raw[prev + x]) : 0
                    let ul = y > 0 && x >= 4 ? Int(raw[prev + x - 4]) : 0
                    let predictor: Int
                    switch type {
                    case 0: predictor = 0
                    case 1: predictor = a
                    case 2: predictor = up
                    case 3: predictor = (a + up) / 2
                    default: predictor = paeth(a, up, ul)
                    }
                    let r = UInt8(truncatingIfNeeded: Int(raw[row + x]) - predictor)
                    candidate[x] = r
                    score += r < 128 ? Int(r) : 256 - Int(r)
                }
                if score < bestScore {
                    bestScore = score
                    bestType = type
                    swap(&best, &candidate)
                }
            }
            out.append(bestType)
            out.append(contentsOf: best)
        }
        return out
    }

    private static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        return pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
    }

    // MARK: zlib / deflate

    static func zlib(_ data: [UInt8]) -> Data {
        var out = Data([0x78, 0x01])
        out.append(contentsOf: deflate(data))
        out.appendBE(adler32(data))
        return out
    }

    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                            35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                             3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                          257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                          8193, 12289, 16385, 24577]
    private static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                           7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    /// One final fixed-Huffman block with greedy LZ77 matching (32 KiB window, hash chains).
    static func deflate(_ data: [UInt8]) -> [UInt8] {
        var w = BitWriter()
        w.write(1, bits: 1)  // BFINAL
        w.write(1, bits: 2)  // BTYPE = fixed Huffman

        let window = 32768, maxLen = 258, minLen = 3, maxChain = 32
        let hashSize = 1 << 15
        var head = [Int](repeating: -1, count: hashSize)
        var prev = [Int](repeating: -1, count: window)
        let n = data.count

        func hash(_ i: Int) -> Int {
            (Int(data[i]) << 10 ^ Int(data[i + 1]) << 5 ^ Int(data[i + 2])) & (hashSize - 1)
        }
        func insert(_ i: Int) {
            guard i + 2 < n else { return }
            let h = hash(i)
            prev[i & (window - 1)] = head[h]
            head[h] = i
        }

        var i = 0
        while i < n {
            var bestLen = 0, bestDist = 0
            if i + minLen <= n {
                var cand = head[hash(i)]
                var chain = maxChain
                let limit = min(maxLen, n - i)
                while cand >= 0 && i - cand <= window && chain > 0 {
                    if data[cand + bestLen] == data[i + bestLen] || bestLen == 0 {
                        var l = 0
                        while l < limit && data[cand + l] == data[i + l] { l += 1 }
                        if l > bestLen {
                            bestLen = l; bestDist = i - cand
                            if l == limit { break }
                        }
                    }
                    let next = prev[cand & (window - 1)]
                    if next >= cand { break }  // slot was overwritten by a newer position
                    cand = next
                    chain -= 1
                }
            }
            if bestLen >= minLen {
                writeLength(bestLen, &w)
                writeDistance(bestDist, &w)
                for k in 0..<bestLen { insert(i + k) }
                i += bestLen
            } else {
                writeLiteral(Int(data[i]), &w)
                insert(i)
                i += 1
            }
        }
        writeLiteral(256, &w)  // end of block
        return w.finish()
    }

    private static func writeLiteral(_ v: Int, _ w: inout BitWriter) {
        switch v {
        case 0...143: w.writeCode(0x30 + v, length: 8)
        case 144...255: w.writeCode(0x190 + v - 144, length: 9)
        case 256...279: w.writeCode(v - 256, length: 7)
        default: w.writeCode(0xC0 + v - 280, length: 8)
        }
    }

    private static func writeLength(_ len: Int, _ w: inout BitWriter) {
        var code = lengthBase.count - 1
        while lengthBase[code] > len { code -= 1 }
        writeLiteral(257 + code, &w)
        w.write(UInt32(len - lengthBase[code]), bits: lengthExtra[code])
    }

    private static func writeDistance(_ dist: Int, _ w: inout BitWriter) {
        var code = distBase.count - 1
        while distBase[code] > dist { code -= 1 }
        w.writeCode(code, length: 5)
        w.write(UInt32(dist - distBase[code]), bits: distExtra[code])
    }

    // MARK: Checksums

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < bytes.count {
            // 5552 is the largest block that cannot overflow before the modulo.
            let end = min(bytes.count, i + 5552)
            while i < end { a += UInt32(bytes[i]); b += a; i += 1 }
            a %= 65521; b %= 65521
        }
        return b << 16 | a
    }
}

/// LSB-first bit packer used by deflate.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var acc: UInt64 = 0
    private var count = 0

    mutating func write(_ value: UInt32, bits: Int) {
        guard bits > 0 else { return }
        acc |= UInt64(value & (1 << bits - 1)) << count
        count += bits
        while count >= 8 {
            bytes.append(UInt8(acc & 0xFF))
            acc >>= 8
            count -= 8
        }
    }

    /// Huffman codes are defined MSB-first, so they are emitted bit-reversed.
    mutating func writeCode(_ code: Int, length: Int) {
        var rev: UInt32 = 0
        for k in 0..<length { rev |= UInt32((code >> k) & 1) << (length - 1 - k) }
        write(rev, bits: length)
    }

    mutating func finish() -> [UInt8] {
        if count > 0 { bytes.append(UInt8(acc & 0xFF)); acc = 0; count = 0 }
        return bytes
    }
}

extension Data {
    mutating func appendBE(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }
}
