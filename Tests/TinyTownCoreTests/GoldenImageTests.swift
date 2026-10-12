import Foundation
import Testing
@testable import TinyTownCore

/// Golden image tests: pin the rendered pixels of representative layouts.
///
/// A failure means rendering changed. The message carries the new hash and the
/// path of the rendered PNG; look at it, and if the change is intended, paste the
/// new hash into `cases` below.
@Suite struct GoldenImageTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let grid: GridSize
        let seed: Int
        let layout: String?               // nil: variant sheet of `sheet` ("all" for every pattern)
        let sheet: String?
        var border = false
        let hash: String
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "town", grid: GridSize(width: 13, height: 7), seed: 5,
             layout: "U3{0,0} U2{9,4} B{5,2} CL{6,2} CR{6,2}#3 F{3} W{4,4-6} C*", sheet: nil,
             hash: "76808a44f260dc5d"),
        Case(name: "halves", grid: GridSize(width: 3, height: 2), seed: 1,
             layout: "CL{0,0} CR{0,0} CT{1,0} CB{1,0} CL{2,1} C*", sheet: nil,
             hash: "892b4779c4392075"),
        Case(name: "waterways", grid: GridSize(width: 5, height: 5), seed: 1,
             layout: "W{1} W{2,1-3} W{3,2-2} W{4,0-1} F{2}", sheet: nil,
             hash: "0f80bb2ce107ec2a"),
        Case(name: "parks", grid: GridSize(width: 7, height: 3), seed: 1,
             layout: "U1{0,0} U1x2{1,0} U2{2,0} U3{4,0}", sheet: nil,
             hash: "70546972a15a5aaa"),
        Case(name: "park-rotated", grid: GridSize(width: 4, height: 2), seed: 1,
             layout: "U2x1{0,0} U1x2{3,0} U2x1{1,1}", sheet: nil,
             hash: "66188b30c39b88c0"),
        Case(name: "buildings", grid: GridSize(width: 2, height: 2), seed: 3,
             layout: "B*", sheet: nil,
             hash: "73c6d8fbdb9529a9"),
        Case(name: "border", grid: GridSize(width: 3, height: 3), seed: 2,
             layout: "F{1} W{1} W{2,2-2} U1{2,0} C*", sheet: nil, border: true,
             hash: "25027b4e4cc5a391"),
        Case(name: "sheet-CT", grid: GridSize(width: 1, height: 1), seed: 1,
             layout: nil, sheet: "CT",
             hash: "3994fba2515c4128"),
        Case(name: "sheet-all", grid: GridSize(width: 1, height: 1), seed: 1,
             layout: nil, sheet: "all",
             hash: "ca7095188b551222"),
    ]

    @Test(arguments: cases)
    func matchesGolden(_ c: Case) throws {
        let atlas = try Atlas.loadEmbedded()
        let image: Bitmap
        if let layout = c.layout {
            let plan = try Planner.plan(LayoutParser.parse(layout), grid: c.grid, seed: c.seed, atlas: atlas)
            image = Renderer.render(plan, atlas: atlas, border: c.border)
        } else {
            image = VariantSheet.render(try VariantSheet.parseTarget(c.sheet!), atlas: atlas)
        }
        let actual = Self.hash(image)
        if actual != c.hash {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("golden-\(c.name).png")
            try? image.scaled(by: 4).writePNG(to: url)
            Issue.record("""
                golden '\(c.name)' changed: expected \(c.hash), got \(actual)
                rendered (x4): \(url.path)
                """)
        }
    }

    /// FNV-1a 64 over size and RGBA pixels, as 16 hex digits.
    static func hash(_ b: Bitmap) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ byte: UInt8) { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        for v in [b.width, b.height] { withUnsafeBytes(of: UInt32(v).littleEndian) { $0.forEach(mix) } }
        b.pixels.forEach(mix)
        return String(format: "%016llx", h)
    }

    @Test func hashIsSensitive() {
        var a = Bitmap(width: 2, height: 1)
        let base = Self.hash(a)
        a.fillRect(x: 1, y: 0, w: 1, h: 1, color: RGBA(0, 0, 1, 0))
        #expect(Self.hash(a) != base)
        #expect(Self.hash(Bitmap(width: 1, height: 2)) != base)  // same bytes, different shape
    }
}
