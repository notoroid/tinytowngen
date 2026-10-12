import Foundation
import Testing
@testable import TinyTownCore

let heian = try! Atlas.loadEmbedded(.heiankyo11c)

@Suite struct MapThemeTests {
    private func render(_ layout: String, _ w: Int, _ h: Int, atlas: Atlas = heian, border: Bool = false) throws -> Bitmap {
        let plan = try Planner.plan(LayoutParser.parse(layout), grid: GridSize(width: w, height: h), seed: 1, atlas: atlas)
        return Renderer.render(plan, atlas: atlas, border: border)
    }

    @Test func heianAtlasHasEveryPiece() {
        #expect(heian.theme == .heiankyo11c)
        #expect(heian.commercial.count == 16)
        for side in HalfSide.allCases { #expect(heian.halves[side]?.count == 4) }
        #expect(heian.buildings.count == 2)
        #expect(heian.parkSizes.map(\.description) == ["U1", "U1x2", "U2x1", "U2", "U3"])
        #expect(CLI.helpText.contains("heiankyo11c C=16, CL=4, CR=4, CT=4, CB=4, B=2"))
        // Halves are drawn at exactly the renderer's half sizes, so nothing is rescaled.
        for side in HalfSide.allCases {
            let r = Metrics.halfRect(side)
            #expect(heian.halves[side]!.allSatisfy { $0.w == r.w && $0.h == r.h })
        }
        // Temples are drawn at the rendered span (1 px roads), so they are not rescaled either.
        for (size, rect) in heian.parks {
            #expect(rect.w == Metrics.span(size.w) && rect.h == Metrics.span(size.h))
        }
    }

    @Test func heianUsesItsOwnColours() throws {
        let img = try render("C{0,0}", 2, 2)
        #expect(MapTheme.heiankyo11c.roadColor == RGBA(hex: 0xBF763A))
        #expect(img.pixel(Metrics.tile, 5) == RGBA(hex: 0xBF763A))                 // road
        #expect(img.pixel(Metrics.pitch + 5, Metrics.pitch + 5) == MapTheme.heiankyo11c.groundColor)  // empty tile
        // Bridges get vermilion railings.
        let g = GridSize(width: 4, height: 4)
        let bridge = try render("F{2} W{2}", 4, 4)
        let f = Metrics.band(of: Plan.Line(kind: .firebreak, index: 2, span: Span(0, 3)), grid: g)
        let w = Metrics.band(of: Plan.Line(kind: .waterway, index: 2, span: Span(0, 3)), grid: g)
        #expect(bridge.pixel(w.x, f.y) == RGBA(hex: 0xB8432F))
    }

    @Test func heianRiverCapsArePiecesOfTheirOwn() throws {
        #expect(heian.canalCapTop != heian.canal && heian.canalCapTop.h == 3)
        #expect(heian.canalCapBottom.h == 4)
        // Sapporo keeps taking its caps from rows of canal_N.
        #expect(atlas.canalCapTop == AtlasRect(x: atlas.canal.x, y: atlas.canal.y, w: atlas.canal.w, h: 3))
        // A partial river ends with the cap piece.
        let img = try render("W{1,1-1} W{2,0-1}", 3, 3)
        let wb = Metrics.band(of: Plan.Line(kind: .waterway, index: 2, span: Span(0, 1)), grid: GridSize(width: 3, height: 3))
        var want = Bitmap(width: img.width, height: img.height)
        let end = wb.y + wb.h, capH = heian.canalCapBottom.h
        want.blitFit(heian.image, heian.canalCapBottom, dx: wb.x, dy: end - capH, dw: wb.w, dh: capH)
        for y in end - capH..<end { for x in wb.x..<wb.x + wb.w { #expect(img.pixel(x, y) == want.pixel(x, y)) } }
    }

    @Test func sameLayoutDiffersOnlyInArt() throws {
        let layout = "U2{0,0} C{2,0-2} C{0-1,2} F{2} W{2}"  // F/W run along the forest's edges
        let a = try render(layout, 3, 3, atlas: atlas)
        let b = try render(layout, 3, 3)
        #expect(a.width == b.width && a.height == b.height && a.pixels != b.pixels)
    }

    @Test func mapOptionAndDirective() throws {
        #expect(try CLIOptions.parse(["-l", "C*", "-o", "a.png", "-m", "heiankyo11c"]).map == .heiankyo11c)
        #expect(try CLIOptions.parse(["-l", "C*", "-o", "a.png", "--map=sapporo"]).map == .sapporo)
        #expect(throws: TownError.usage("unknown map 'kyoto' (use sapporo, heiankyo11c)")) {
            try CLIOptions.parse(["-l", "C*", "-o", "a.png", "-m", "kyoto"])
        }
        #expect(try LayoutParser.parseDocument("@map heiankyo11c C*").settings.map == .heiankyo11c)
        #expect(throws: TownError.self) { try LayoutParser.parseDocument("@map kyoto C*") }
        #expect(throws: TownError.self) { try LayoutParser.parseDocument("@map sapporo @map heiankyo11c C*") }
        // Precedence: -m over @map over the default.
        var o = CLIOptions()
        let s = LayoutSettings(map: .heiankyo11c)
        #expect(CLI.resolve(o, LayoutSettings()).map == .sapporo)
        #expect(CLI.resolve(o, s).map == .heiankyo11c)
        o.map = .sapporo
        #expect(CLI.resolve(o, s).map == .sapporo)
        #expect(CLI.run(["-m", "kyoto", "-l", "C*", "-o", "/dev/null"]) == 2)
    }

    @Test func rasterWorksOnHeian() throws {
        let p = try RasterLayout.parse("C1C2 U0U0 C4C3 U0U0 F0F0F0F0 B0B0 R0 C2C2 B0B0 R0 C4C4",
                                       grid: GridSize(width: 2, height: 2), parkSizes: heian.parkSizes)
        let plan = try Planner.plan(p, grid: GridSize(width: 2, height: 2), seed: 1, atlas: heian)
        #expect(plan.tiles.count == 4 && plan.parks.count == 1 && plan.lines.count == 2)
    }

    /// EmbeddedResources must be regenerated whenever Resources/ changes.
    @Test func embeddedResourcesMatchFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pairs: [(String, String)] = [
            ("Resources/patterns.png", EmbeddedResources.patternsPNG), ("Resources/tiles.json", EmbeddedResources.tilesJSON),
            ("Resources/heiankyo11c/patterns.png", EmbeddedResources.heiankyoPNG),
            ("Resources/heiankyo11c/tiles.json", EmbeddedResources.heiankyoJSON),
        ]
        for (path, embedded) in pairs {
            let file = try Data(contentsOf: root.appendingPathComponent(path))
            #expect(file.base64EncodedString() == embedded, "\(path) differs: run Scripts/embed-resources.sh")
        }
    }
}
