import Foundation
import Testing
@testable import TinyTownCore

/// Golden image tests: pin the rendered pixels of representative layouts.
///
/// The hash in `cases` is the source of truth. `Golden/<name>.png` stores the expected
/// image (1x) only so a failure can show what changed: the message lists the new hash,
/// the number and bounding box of changed pixels, and actual / expected / diff PNGs (x4;
/// changed pixels red over a dimmed copy of the actual image).
///
/// To accept an intended change: look at the PNGs, run `UPDATE_GOLDEN=1 swift test`
/// to rewrite `Golden/*.png`, then paste the new hash into `cases`.
/// `storedPNGsMatchHashes` fails while the two disagree.
@Suite struct GoldenImageTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let grid: GridSize
        let seed: Int
        let layout: String?               // nil: variant sheet of `sheet` ("all" for every pattern)
        let sheet: String?
        var border = false
        /// Raster layout instead of `layout` (see `RasterLayout`).
        var raster: String? = nil
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
        Case(name: "raster", grid: GridSize(width: 4, height: 3), seed: 3,
             layout: nil, sheet: nil, raster: """
             C1C2 C0C0 C2C2 B0B0
             C4C3 C0C0 C4C4 B0B0
             F0F0 F0F0 F0F0 F0F0
             U0U0U0U0 C1C3 R0 B0C0
             U0U0U0U0 C0B0 R0 C0B0
             U0U0U0U0 C1C2 R0 C2C0
             U0U0U0U0 C4C3 R0 C4C0
             """,
             hash: "7191482bf41b1296"),
        Case(name: "sheet-all", grid: GridSize(width: 1, height: 1), seed: 1,
             layout: nil, sheet: "all",
             hash: "ca7095188b551222"),
    ]

    static let goldenDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden")
    static var updating: Bool { ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1" }

    static func render(_ c: Case) throws -> Bitmap {
        let atlas = try Atlas.loadEmbedded()
        if let raster = c.raster {
            let placements = try RasterLayout.parse(raster, grid: c.grid, parkSizes: atlas.parkSizes)
            return Renderer.render(try Planner.plan(placements, grid: c.grid, seed: c.seed, atlas: atlas), atlas: atlas)
        }
        if let layout = c.layout {
            let plan = try Planner.plan(LayoutParser.parse(layout), grid: c.grid, seed: c.seed, atlas: atlas)
            return Renderer.render(plan, atlas: atlas, border: c.border)
        }
        return VariantSheet.render(try VariantSheet.parseTarget(c.sheet!), atlas: atlas)
    }

    @Test(arguments: cases)
    func matchesGolden(_ c: Case) throws {
        let image = try Self.render(c)
        let stored = Self.goldenDir.appendingPathComponent("\(c.name).png")
        if Self.updating {
            try FileManager.default.createDirectory(at: Self.goldenDir, withIntermediateDirectories: true)
            try image.writePNG(to: stored)
        }
        let actual = Self.hash(image)
        guard actual != c.hash else { return }

        let tmp = FileManager.default.temporaryDirectory
        let actualURL = tmp.appendingPathComponent("golden-\(c.name).png")
        try? image.scaled(by: 4).writePNG(to: actualURL)
        var report = "golden '\(c.name)' changed: expected \(c.hash), got \(actual)\nactual (x4):   \(actualURL.path)"
        if !Self.updating, let data = try? Data(contentsOf: stored), let expected = try? PNGDecoder.decode(data) {
            let d = GoldenDiff(expected: expected, actual: image)
            let expectedURL = tmp.appendingPathComponent("golden-\(c.name)-expected.png")
            let diffURL = tmp.appendingPathComponent("golden-\(c.name)-diff.png")
            try? expected.scaled(by: 4).writePNG(to: expectedURL)
            try? d.image.scaled(by: 4).writePNG(to: diffURL)
            report += "\nexpected (x4): \(expectedURL.path)\ndiff (x4):     \(diffURL.path)\n\(d.summary)"
        } else if !Self.updating {
            report += "\n(no stored \(stored.lastPathComponent); run UPDATE_GOLDEN=1 swift test to create it)"
        }
        Issue.record(Comment(rawValue: report))
    }

    /// The stored PNGs must show exactly what the hashes pin, so diffs are never against a stale image.
    @Test(.disabled(if: updating, "rewriting Golden/*.png"), arguments: cases)
    func storedPNGsMatchHashes(_ c: Case) throws {
        let url = Self.goldenDir.appendingPathComponent("\(c.name).png")
        let data = try #require(try? Data(contentsOf: url), "missing \(url.path); run UPDATE_GOLDEN=1 swift test")
        let stored = try PNGDecoder.decode(data)
        #expect(Self.hash(stored) == c.hash,
                "Golden/\(c.name).png and the hash in cases disagree; update both together")
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

    @Test func diffHighlightsChangedPixels() throws {
        var a = Bitmap(width: 4, height: 3, fill: RGBA(100, 100, 100))
        var b = a
        b.fillRect(x: 2, y: 1, w: 1, h: 1, color: RGBA(0, 200, 0))
        b.fillRect(x: 3, y: 2, w: 1, h: 1, color: RGBA(0, 200, 0))
        let d = GoldenDiff(expected: a, actual: b)
        #expect(d.changed == 2)
        let bounds = try #require(d.bounds)
        #expect(bounds == (2, 1, 3, 2))
        #expect(d.image.pixel(2, 1) == GoldenDiff.changedColor)
        #expect(d.image.pixel(0, 0) != GoldenDiff.changedColor && d.image.pixel(0, 0).a == 255)
        #expect(GoldenDiff(expected: a, actual: a).changed == 0)
        // Size change: the uncovered area counts as changed.
        a = Bitmap(width: 5, height: 3, fill: RGBA(100, 100, 100))
        let grown = GoldenDiff(expected: b, actual: a)
        #expect(grown.image.width == 5 && grown.changed == 3 + 2)
    }
}
