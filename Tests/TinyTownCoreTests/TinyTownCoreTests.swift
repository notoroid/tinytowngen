import Foundation
import Testing
@testable import TinyTownCore

let atlas = try! Atlas.loadEmbedded()
private let grid = GridSize(width: 13, height: 7)

private func plan(_ layout: String, grid: GridSize = grid, seed: Int = 1) throws -> Plan {
    try Planner.plan(LayoutParser.parse(layout), grid: grid, seed: seed, atlas: atlas)
}

@Suite struct AtlasTests {
    @Test func candidateCountsMatchHelp() {
        #expect(atlas.commercial.count == 63)
        #expect(atlas.halves[.left]?.count == 12)
        #expect(atlas.halves[.right]?.count == 12)
        #expect(atlas.halves[.top]?.count == 20)
        #expect(atlas.halves[.bottom]?.count == 20)
        #expect(atlas.buildings.count == 2)
        #expect(CLI.helpText.contains("C=63, CL=12, CR=12, CT=20, CB=20, B=2"))
        #expect(Set(atlas.parks.keys.map(\.description)) == ["U1", "U2", "U3", "U1x2"])
        #expect(atlas.parkSizes.map(\.description) == ["U1", "U1x2", "U2x1", "U2", "U3"])
        #expect(CLI.helpText.contains("Sizes: U1, U2, U3, U1x2, U2x1"))
    }
}

@Suite struct ParserTests {
    @Test func parsesTokens() throws {
        let p = try LayoutParser.parse("C{1,2}; CL{0-2,3}#4  U1x2{5,0} F{3,2-8} W{4} C*")
        #expect(p.count == 6)
        #expect(p[0].kind == .commercial && p[0].a == Span(1, 1) && p[0].b == Span(2, 2))
        #expect(p[1].kind == .half(.left) && p[1].a == Span(0, 2) && p[1].variant == 4)
        #expect(p[2].kind == .park(ParkSize(w: 1, h: 2)))
        #expect(p[3].kind == .firebreak && p[3].a == Span(3, 3) && p[3].b == Span(2, 8))
        #expect(p[4].kind == .waterway && p[4].b == nil)
        #expect(p[5].fill)
    }

    @Test(arguments: ["Z{0,0}", "C{0}", "C{a,1}", "C{3-1,0}", "U{0,0}", "U2{0-1,0}", "F{1-2}", "U2*", "C{0,0}#x", "U2{0,0}#1"])
    func rejectsMalformed(_ token: String) {
        #expect(throws: TownError.self) { try LayoutParser.parse(token) }
    }

    @Test func gridSize() throws {
        #expect(try GridSize(parsing: "13x7") == GridSize(width: 13, height: 7))
        #expect(throws: TownError.self) { try GridSize(parsing: "13*7") }
        #expect(throws: TownError.self) { try GridSize(parsing: "0x7") }
    }
}

@Suite struct LayoutTextTests {
    @Test func multiLineWithComments() throws {
        let text = """
        # parks
        U3{0,0}   # big one
        F{3}; C{5,5}#2
        #C{6,6}
        C*
        """
        let p = try LayoutParser.parse(text)
        #expect(p.map(\.token) == ["U3{0,0}", "F{3}", "C{5,5}#2", "C*"])
        #expect(p[2].variant == 2)
    }

    @Test func spacedHashIsCommentNotVariant() throws {
        let p = try LayoutParser.parse("C{1,2} #3 C{0,0}")
        #expect(p.count == 1 && p[0].variant == nil)
    }

    @Test func syntaxErrorsCarryLineNumber() {
        #expect(throws: TownError.atLine(2, .syntax(token: "Z{1,1}",
                "unknown pattern 'Z' (use C, CL, CR, CT, CB, B, Un, UWxH, F, W)"))) {
            try LayoutParser.parse("C{0,0}\nZ{1,1}")
        }
        // Single-line layouts keep the plain error.
        #expect(throws: TownError.syntax(token: "Z{1,1}",
                "unknown pattern 'Z' (use C, CL, CR, CT, CB, B, Un, UWxH, F, W)")) {
            try LayoutParser.parse("C{0,0} Z{1,1}")
        }
    }

    @Test func commentsOnlyIsEmpty() {
        #expect(throws: TownError.usage("layout is empty")) { try LayoutParser.parse("# nothing\n\n") }
    }

    @Test func loadLayoutSources() throws {
        #expect(try CLI.loadLayout("C*") == "C*")
        #expect(try CLI.loadLayout("@-", stdin: { Data("U2{0,0}\nC*".utf8) }) == "U2{0,0}\nC*")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinytowngen-\(UUID()).txt")
        try "B{0,0}\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try CLI.loadLayout("@" + url.path) == "B{0,0}\n")
        #expect(throws: TownError.self) { try CLI.loadLayout("@/nonexistent/layout.txt") }
    }

    @Test func exitCodes() throws {
        #expect(CLI.run(["-l", "@/nonexistent/layout.txt", "-o", "/dev/null"]) == 2)
        #expect(CLI.run(["-l", "# empty", "-o", "/dev/null"]) == 2)
        #expect(CLI.run(["-l", "C{99,0}", "-o", "/dev/null"]) == 1)
    }
}

@Suite struct VariantSheetTests {
    private func tile(_ img: Bitmap, _ ox: Int, _ oy: Int) -> [RGBA] {
        (oy..<oy + 19).flatMap { y in (ox..<ox + 19).map { img.pixel($0, y) } }
    }

    @Test func sheetSize() {
        let c = VariantSheet.render(.commercial, atlas: atlas)    // 63 -> 8 cols x 8 rows
        #expect(c.width == 2 + 8 * 21 && c.height == 2 + 8 * 27)
        let b = VariantSheet.render(.building, atlas: atlas)      // 2 -> 2 cols x 1 row
        #expect(b.width == 2 + 2 * 21 && b.height == 2 + 27)
    }

    @Test(arguments: ["C", "CL", "CR", "CT", "CB", "B"])
    func sheetCellMatchesLayoutVariant(_ name: String) throws {
        // Cell #n on the sheet must look exactly like P{0,0}#n in a town.
        let kind = try VariantSheet.parseKind(name)
        let sheet = VariantSheet.render(kind, atlas: atlas)
        let n = atlas.variantCount(for: kind)! - 1
        let town = Renderer.render(try plan("\(name){0,0}#\(n)", grid: GridSize(width: 1, height: 1)), atlas: atlas)
        let ox = 2 + (n % 8) * 21, oy = 2 + (n / 8) * 27
        #expect(tile(sheet, ox, oy) == tile(town, 0, 0))
    }

    @Test func labelsAreDrawn() {
        let sheet = VariantSheet.render(.building, atlas: atlas)
        // "0" centered under cell 0: glyph x=10..12, y=22..26; its center pixel is unlit.
        #expect(sheet.pixel(10, 22) == VariantSheet.labelColor)
        #expect(sheet.pixel(11, 24) == VariantSheet.background)
        #expect(sheet.pixel(12, 26) == VariantSheet.labelColor)
    }

    @Test func allSheetStacksEverySection() throws {
        let kinds = VariantSheet.allKinds.map(\.kind)
        let sheet = VariantSheet.render(kinds, atlas: atlas)
        var y = 0
        for kind in kinds {
            let section = VariantSheet.render(kind, atlas: atlas)
            // Header: first glyph column of the name is lit in the header colour.
            #expect(sheet.pixel(2, y + 2) == VariantSheet.headerColor)
            y += 2 + 5
            for sy in 0..<section.height {
                for sx in 0..<section.width { #expect(sheet.pixel(sx, y + sy) == section.pixel(sx, sy)) }
            }
            y += section.height
        }
        #expect(sheet.height == y && sheet.width == 2 + 8 * 21)
    }

    @Test func singlePatternSheetIsUnchanged() {
        #expect(VariantSheet.render([.half(.top)], atlas: atlas).pixels == VariantSheet.render(.half(.top), atlas: atlas).pixels)
    }

    @Test func everyPatternNameHasGlyphs() {
        for (name, kind) in VariantSheet.allKinds {
            #expect(name == kind.orderKey)
            for ch in name { #expect(VariantSheet.glyphs[ch] != nil, "missing glyph \(ch)") }
        }
    }

    @Test func options() throws {
        let o = try CLIOptions.parse(["--list-variants", "CT", "-o", "s.png"])
        #expect(o.listVariants == [.half(.top)] && o.layout == nil)
        #expect(try CLIOptions.parse(["--list-variants", "all", "-o", "s.png"]).listVariants?.count == 6)
        #expect(throws: TownError.self) { try CLIOptions.parse(["--list-variants", "ALL", "-o", "s.png"]) }
        #expect(throws: TownError.self) { try CLIOptions.parse(["--list-variants", "U2", "-o", "s.png"]) }
        #expect(throws: TownError.self) { try CLIOptions.parse(["--list-variants", "C"]) }
        #expect(throws: TownError.self) { try CLIOptions.parse(["--list-variants", "C", "-l", "C*", "-o", "s.png"]) }
    }
}

@Suite struct BorderTests {
    private let g = GridSize(width: 3, height: 3)
    private func render(_ layout: String, border: Bool) throws -> Bitmap {
        Renderer.render(try plan(layout, grid: g), atlas: atlas, border: border)
    }

    @Test func canvasGrowsByOuterRoad() throws {
        let img = try render("C*", border: true)
        let r = Metrics.road, p = Metrics.pitch
        #expect(img.width == 3 * p + r && img.height == 3 * p + r)
        #expect(Metrics.canvasSize(GridSize(width: 13, height: 7), margin: r) == (13 * p + r, 7 * p + r))
        let last = img.width - 1
        for (x, y) in [(0, 0), (0, 30), (last, last), (30, last), (last, 0)] {
            #expect(img.pixel(x, y) == Metrics.roadColor)
        }
    }

    @Test func tilesShiftByOuterRoad() throws {
        let plain = try render("C{0,0}", border: false), framed = try render("C{0,0}", border: true)
        let r = Metrics.road
        for y in 0..<19 { for x in 0..<19 { #expect(framed.pixel(x + r, y + r) == plain.pixel(x, y)) } }
    }

    /// Rows (F) or columns (W) covered by a line's band with --border.
    private func band(_ kind: PlacementKind, _ index: Int, _ lo: Int, _ hi: Int) -> Range<Int> {
        let b = Metrics.band(of: Plan.Line(kind: kind, index: index, span: Span(lo, hi)), grid: g, margin: Metrics.road)
        return kind == .firebreak ? b.y..<b.y + b.h : b.x..<b.x + b.w
    }

    // A single pixel of sprite may happen to equal the road color, so check whole cross-sections of the band.
    private func isRoad(_ img: Bitmap, xs: Range<Int>, ys: Range<Int>) -> Bool {
        ys.allSatisfy { y in xs.allSatisfy { img.pixel($0, y) == Metrics.roadColor } }
    }

    @Test func linesReachingGridEdgeCrossOuterRoad() throws {
        let img = try render("F{1} W{2,1-2}", border: true)
        let fy = band(.firebreak, 1, 0, 2), wx = band(.waterway, 2, 1, 2)
        #expect(!isRoad(img, xs: 0..<1, ys: fy))                               // F at left edge
        #expect(!isRoad(img, xs: img.width - 1..<img.width, ys: fy))          // F at right edge
        #expect(!isRoad(img, xs: wx, ys: img.height - 1..<img.height))        // W reaches bottom edge
        #expect(isRoad(img, xs: wx, ys: 0..<1))                               // W starts inside: no extension
    }

    @Test func partialLinesAndShortCanalStayInside() throws {
        let img = try render("F{1,1-2} W{1,2-2}", border: true)
        let fy = band(.firebreak, 1, 1, 2), wx = band(.waterway, 1, 2, 2)
        #expect(isRoad(img, xs: 0..<1, ys: fy))                               // F starts at column 1
        #expect(!isRoad(img, xs: img.width - 1..<img.width, ys: fy))          // ...but reaches the right edge
        #expect(isRoad(img, xs: wx, ys: img.height - 1..<img.height))         // single-tile canal not extended
    }

    @Test func option() throws {
        #expect(try CLIOptions.parse(["-l", "C*", "-o", "a.png", "--border"]).border)
        #expect(try !CLIOptions.parse(["-l", "C*", "-o", "a.png"]).border)
    }
}

@Suite struct PlannerTests {
    @Test func outOfBounds() {
        #expect(throws: TownError.self) { try plan("C{13,0}") }
        #expect(throws: TownError.self) { try plan("C{0-13,0}") }
        #expect(throws: TownError.self) { try plan("U3{11,0}") }
        #expect(throws: TownError.self) { try plan("F{0}") }
        #expect(throws: TownError.self) { try plan("F{7}") }
        #expect(throws: TownError.self) { try plan("W{13}") }
        #expect(throws: TownError.self) { try plan("F{3,0-13}") }
    }

    @Test func overlap() throws {
        #expect(throws: TownError.self) { try plan("C{0,0} B{0,0}") }
        #expect(throws: TownError.self) { try plan("U2{0,0} C{1,1}") }
        #expect(throws: TownError.self) { try plan("CL{0,0} CT{0,0}") }
        #expect(try plan("CL{0,0} CR{0,0} CT{1,0} CB{1,0}").tiles.count == 4)
    }

    @Test func parkCannotBeCrossed() throws {
        #expect(throws: TownError.parkCrossesLine(park: "U3{0,0}", line: "F{2,0-12}")) { try plan("U3{0,0} F{2}") }
        #expect(throws: TownError.self) { try plan("U2{4,2} W{5}") }
        #expect(throws: TownError.self) { try plan("U1x2{0,0} F{1,0-0}") }
        // Edges and non-overlapping spans are fine.
        #expect(try plan("U3{0,0} F{3} W{3}").lines.count == 2)
        #expect(try plan("U2{0,0} W{1,3-6}").parks.count == 1)
        #expect(try plan("U1x2{0,0} W{1}").parks.count == 1)
        // U2x1 spans road column 1 but no road row.
        #expect(throws: TownError.parkCrossesLine(park: "U2x1{0,0}", line: "W{1,0-6}")) { try plan("U2x1{0,0} W{1}") }
        #expect(try plan("U2x1{0,1} F{1} F{2} W{2}").parks.count == 1)
        #expect(throws: TownError.self) { try plan("U2x1{12,0}") }
        #expect(throws: TownError.self) { try plan("U2x1{0,0} C{1,0}") }
    }

    @Test func seedFormula() throws {
        // tileCount 91; seed 10 -> base 1; orders 0,1,2.
        let p = try plan("C{0-2,0}", seed: 10)
        #expect(p.tiles.map(\.variant) == [1, 2, 3])
        // Orders are counted per pattern; explicit #n wins.
        let q = try plan("C{0,0} B{1,0} C{2,0} B{3,0}#0 B{4,0}", seed: 1)
        #expect(q.tiles.map(\.variant) == [0, 0, 1, 0, 0])
    }

    @Test func fillCompletesHalves() throws {
        let p = try plan("CL{0,0} CB{1,0} C*", grid: GridSize(width: 2, height: 1))
        #expect(p.tiles.map(\.kind) == [.half(.left), .half(.bottom), .half(.right), .half(.top)])
    }
}

@Suite struct RendererTests {
    @Test func geometry() throws {
        let img = Renderer.render(try plan("C{0,0}", grid: GridSize(width: 3, height: 2)), atlas: atlas)
        let p = Metrics.pitch, r = Metrics.road, t = Metrics.tile
        #expect(img.width == 3 * p - r && img.height == 2 * p - r)
        #expect(Metrics.canvasSize(GridSize(width: 13, height: 7)) == (259, 139))  // 1 px roads
        #expect(img.pixel(t, 5) == Metrics.roadColor)      // vertical road right of tile 0
        #expect(img.pixel(30, t) == Metrics.roadColor)     // horizontal road below tile row 0
        #expect(img.pixel(p + 5, 5) == Metrics.groundColor) // empty tile
    }

    /// x of the canal band for vertical road 1 (6 px wide around the road).
    private let canalX = Metrics.band(of: Plan.Line(kind: .waterway, index: 1, span: Span(0, 0)),
                                      grid: GridSize(width: 3, height: 3)).x
    private func canalColumn(_ img: Bitmap, y: Int) -> [RGBA] { (canalX..<canalX + 6).map { img.pixel($0, y) } }

    private func expected(_ src: AtlasRect, dy: Int, dh: Int, tiled: Bool = false) -> Bitmap {
        var b = Bitmap(width: 3 * Metrics.pitch, height: 3 * Metrics.pitch)
        if tiled {
            b.blitTiled(atlas.image, src, dx: canalX, dy: dy, dw: 6, dh: dh, phaseY: dy)
        } else {
            b.blitFit(atlas.image, src, dx: canalX, dy: dy, dw: 6, dh: dh)
        }
        return b
    }

    @Test func singleTileWaterwayUsesShortCanal() throws {
        let img = Renderer.render(try plan("W{1,1-1}", grid: GridSize(width: 3, height: 3)), atlas: atlas)
        let top = Metrics.pitch, t = Metrics.tile
        let want = expected(atlas.canalShort, dy: top, dh: t)
        for y in top..<top + t { #expect(canalColumn(img, y: y) == canalColumn(want, y: y)) }
    }

    private func capSource(_ rows: Range<Int>) -> AtlasRect {
        AtlasRect(x: atlas.canal.x, y: atlas.canal.y + rows.lowerBound, w: atlas.canal.w, h: rows.count)
    }

    @Test func partialWaterwayIsCappedOnlyInsideGrid() throws {
        let img = Renderer.render(try plan("W{1,0-1}", grid: GridSize(width: 3, height: 3)), atlas: atlas)
        let capH = Metrics.canalCapBottomRows.count
        let end = Metrics.pitch + Metrics.tile  // bottom of tile row 1
        let bottomCap = expected(capSource(Metrics.canalCapBottomRows), dy: end - capH, dh: capH)
        for y in (end - capH)..<end { #expect(canalColumn(img, y: y) == canalColumn(bottomCap, y: y)) }
        // Top end touches the image edge: plain canal body, no cap.
        let body = expected(atlas.canal, dy: 0, dh: end, tiled: true)
        for y in 0..<Metrics.canalCapTopRows.count { #expect(canalColumn(img, y: y) == canalColumn(body, y: y)) }
    }

    @Test func topCapComesFromCanalItself() throws {
        let img = Renderer.render(try plan("W{1,1-2}", grid: GridSize(width: 3, height: 3)), atlas: atlas)
        let capH = Metrics.canalCapTopRows.count
        let top = Metrics.pitch  // top of tile row 1
        let topCap = expected(capSource(Metrics.canalCapTopRows), dy: top, dh: capH)
        for y in top..<top + capH { #expect(canalColumn(img, y: y) == canalColumn(topCap, y: y)) }
    }

    @Test func capsUseCanalPaletteAndHaveNoOpenWater() {
        // Caps must look like canal_N's stone (same colours) and close the green channel.
        let c = atlas.canal
        var palette = Set<UInt32>()
        for y in c.y..<c.y + c.h { for x in c.x..<c.x + c.w { palette.insert(key(atlas.image.pixel(x, y))) } }
        for rows in [Metrics.canalCapTopRows, Metrics.canalCapBottomRows] {
            for y in rows { for x in c.x..<c.x + c.w {
                let p = atlas.image.pixel(x, c.y + y)
                #expect(palette.contains(key(p)))
                #expect(!(Int(p.g) > Int(p.r) + 8 && Int(p.g) > Int(p.b) + 8), "green water at cap row \(y)")
            } }
        }
    }

    private func key(_ p: RGBA) -> UInt32 { UInt32(p.r) << 16 | UInt32(p.g) << 8 | UInt32(p.b) }

    private func region(_ img: Bitmap, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> [RGBA] {
        (y..<y + h).flatMap { yy in (x..<x + w).map { img.pixel($0, yy) } }
    }

    @Test func narrowParkIsScaledNotCropped() throws {
        let img = Renderer.render(try plan("U1x2{0,0}", grid: GridSize(width: 1, height: 2)), atlas: atlas)
        let src = atlas.parks[ParkSize(w: 1, h: 2)]!
        #expect(src.w > Metrics.tile)  // park_B is wider than one tile, so it must shrink
        let w = Metrics.span(1), h = Metrics.span(2)
        var scaled = Bitmap(width: w, height: h), cropped = scaled
        scaled.blitScaled(atlas.image, src, dx: 0, dy: 0, dw: w, dh: h)
        cropped.blitFit(atlas.image, src, dx: 0, dy: 0, dw: w, dh: h)
        #expect(region(img, 0, 0, w, h) == region(scaled, 0, 0, w, h))
        #expect(region(img, 0, 0, w, h) != region(cropped, 0, 0, w, h))
    }

    @Test func rotatedClockwise() {
        // 2 wide x 3 tall, values encode (x, y) in the red channel.
        var b = Bitmap(width: 2, height: 3)
        for y in 0..<3 { for x in 0..<2 { b.fillRect(x: x, y: y, w: 1, h: 1, color: RGBA(UInt8(10 * x + y), 0, 0)) } }
        let r = b.rotatedClockwise(AtlasRect(x: 0, y: 0, w: 2, h: 3))
        #expect(r.width == 3 && r.height == 2)
        // Top row of the result is the source's left column read bottom-up.
        #expect([r.pixel(0, 0).r, r.pixel(1, 0).r, r.pixel(2, 0).r] == [2, 1, 0])
        #expect([r.pixel(0, 1).r, r.pixel(1, 1).r, r.pixel(2, 1).r] == [12, 11, 10])
    }

    @Test func wideParkIsRotatedTallPark() throws {
        let sprite = try #require(atlas.parkSprite(for: ParkSize(w: 2, h: 1)))
        #expect(sprite.rotated && sprite.source == atlas.parks[ParkSize(w: 1, h: 2)])
        #expect(atlas.parkSprite(for: ParkSize(w: 1, h: 2))?.rotated == false)
        #expect(atlas.parkSprite(for: ParkSize(w: 3, h: 1)) == nil)

        let img = Renderer.render(try plan("U2x1{0,0}", grid: GridSize(width: 2, height: 1)), atlas: atlas)
        let turned = atlas.image.rotatedClockwise(sprite.source)
        let w = Metrics.span(2), h = Metrics.span(1)
        var want = Bitmap(width: w, height: h)
        want.blitScaled(turned, AtlasRect(x: 0, y: 0, w: turned.width, h: turned.height), dx: 0, dy: 0, dw: w, dh: h)
        #expect(region(img, 0, 0, w, h) == region(want, 0, 0, w, h))
    }

    @Test(arguments: [1, 2, 3])
    func squareParksRenderAsBefore(_ n: Int) throws {
        // Upscaling parks is pure nearest-neighbour, identical to blitFit.
        let span = Metrics.span(n)
        let img = Renderer.render(try plan("U\(n){0,0}", grid: GridSize(width: n, height: n)), atlas: atlas)
        var want = Bitmap(width: span, height: span)
        want.blitFit(atlas.image, atlas.parks[ParkSize(w: n, h: n)]!, dx: 0, dy: 0, dw: span, dh: span)
        #expect(region(img, 0, 0, span, span) == region(want, 0, 0, span, span))
    }

    @Test func blitScaledAveragesWhenShrinking() {
        var src = Bitmap(width: 2, height: 1)
        src.fillRect(x: 0, y: 0, w: 1, h: 1, color: RGBA(200, 100, 0))
        src.fillRect(x: 1, y: 0, w: 1, h: 1, color: RGBA(100, 50, 0))
        var dst = Bitmap(width: 1, height: 2)
        dst.blitScaled(src, AtlasRect(x: 0, y: 0, w: 2, h: 1), dx: 0, dy: 0, dw: 1, dh: 2)
        #expect(dst.pixel(0, 0) == RGBA(150, 75, 0))  // shrink: averaged
        #expect(dst.pixel(0, 1) == RGBA(150, 75, 0))  // grow: repeated
    }

    private func bridgeCount(_ layout: String) throws -> Int {
        let p = try plan(layout, grid: GridSize(width: 4, height: 4))
        return Metrics.bridges(boulevards: p.lines.filter { $0.kind == .firebreak },
                               waterways: p.lines.filter { $0.kind == .waterway }, grid: p.grid).count
    }

    @Test func bridgesOnlyWhereCanalContinuesAcross() throws {
        #expect(try bridgeCount("F{2} W{2}") == 1)
        #expect(try bridgeCount("F{1} F{2} W{1} W{3}") == 4)
        #expect(try bridgeCount("F{2} W{2,1-2}") == 1)
        #expect(try bridgeCount("F{2} W{2,0-1}") == 0)  // canal ends at the boulevard
        #expect(try bridgeCount("F{2} W{2,2-3}") == 0)  // canal starts at the boulevard
        #expect(try bridgeCount("F{2,0-1} W{3}") == 0)  // boulevard stops before the canal
        #expect(try bridgeCount("F{2,2-3} W{2}") == 0)  // boulevard starts right of the canal
    }

    @Test func bridgeDrawsParapetsOverBoulevard() throws {
        let g = GridSize(width: 4, height: 4)
        let img = Renderer.render(try plan("F{2} W{2}", grid: g), atlas: atlas)
        let f = Metrics.band(of: Plan.Line(kind: .firebreak, index: 2, span: Span(0, 3)), grid: g)
        let w = Metrics.band(of: Plan.Line(kind: .waterway, index: 2, span: Span(0, 3)), grid: g)
        for x in w.x..<w.x + w.w {
            #expect(img.pixel(x, f.y) == Metrics.parapetColor)
            #expect(img.pixel(x, f.y + f.h - 1) == Metrics.parapetColor)
            #expect(img.pixel(x, f.y + f.h) == Metrics.bridgeShadowColor)
        }
        // The deck between the parapets is boulevard, not canal.
        var deck = Bitmap(width: img.width, height: img.height)
        deck.blitTiled(atlas.image, atlas.boulevard, dx: 0, dy: f.y, dw: img.width, dh: f.h, phaseX: 0)
        let cx = w.x + w.w / 2
        for y in f.y + 1..<f.y + f.h - 1 { #expect(img.pixel(cx, y) == deck.pixel(cx, y)) }
    }

    @Test func boulevardReplacesRoad() throws {
        let img = Renderer.render(try plan("F{1}", grid: GridSize(width: 3, height: 2)), atlas: atlas)
        let roadY = Metrics.pitch - Metrics.road  // road row 1
        #expect((0..<img.width).contains { img.pixel($0, roadY) != Metrics.roadColor })
    }
}

@Suite struct CLITests {
    @Test func options() throws {
        let o = try CLIOptions.parse(["-l", "C*", "--output=a.png", "-g", "4x3", "--seed", "7"])
        #expect(o.layout == "C*" && o.output == "a.png" && o.grid == GridSize(width: 4, height: 3) && o.seed == 7)
        #expect(throws: TownError.self) { try CLIOptions.parse(["-o", "a.png"]) }
        #expect(throws: TownError.self) { try CLIOptions.parse(["-l", "C*"]) }
        #expect(throws: TownError.self) { try CLIOptions.parse(["-l", "C*", "-o", "a.png", "-s", "0"]) }
        #expect(try CLIOptions.parse(["--help"]).help)
    }
}

@Suite struct DirectiveTests {
    @Test func parsesDirectivesAnywhere() throws {
        let doc = try LayoutParser.parseDocument("""
        @grid 4x3 @seed 5   # settings
        U2{0,0}; @border
        C*
        """)
        #expect(doc.settings == LayoutSettings(grid: GridSize(width: 4, height: 3), seed: 5, border: true))
        #expect(doc.placements.map(\.token) == ["U2{0,0}", "C*"])
        let inline = try LayoutParser.parseDocument("C* @seed 3")
        #expect(inline.settings.seed == 3 && inline.settings.grid == nil && !inline.settings.border)
    }

    @Test(arguments: ["@grid C*", "@grid 0x3 C*", "@seed C*", "@seed 0 C*", "@size 3x3 C*",
                      "@seed 1 @seed 2 C*", "@border @border C*", "C* @grid"])
    func rejectsBadDirectives(_ layout: String) {
        #expect(throws: TownError.self) { try LayoutParser.parseDocument(layout) }
    }

    @Test func directiveErrorsCarryLineNumber() {
        #expect(throws: TownError.atLine(2, .syntax(token: "@seed", "given more than once"))) {
            try LayoutParser.parseDocument("@seed 1\n@seed 2\nC*")
        }
    }

    @Test func directiveValueStopsAtComment() {
        #expect(throws: TownError.self) { try LayoutParser.parseDocument("@seed #5\nC*") }
    }

    @Test func directivesAloneAreEmpty() {
        #expect(throws: TownError.usage("layout is empty")) { try LayoutParser.parseDocument("@grid 3x3 @border") }
    }

    @Test func commandLineWinsOverDirectives() throws {
        let s = LayoutSettings(grid: GridSize(width: 4, height: 3), seed: 5, border: true)
        var o = CLIOptions()
        #expect(CLI.resolve(o, s) == (GridSize(width: 4, height: 3), 5, true))
        o.grid = GridSize(width: 2, height: 2); o.seed = 9
        #expect(CLI.resolve(o, s) == (GridSize(width: 2, height: 2), 9, true))
        #expect(CLI.resolve(CLIOptions(), LayoutSettings()) == (GridSize(width: 13, height: 7), 1, false))
        o.border = true
        #expect(CLI.resolve(o, LayoutSettings()).border)
    }

    @Test func inlineLayoutStartingWithDirectiveIsNotAFile() throws {
        #expect(try CLI.loadLayout("@grid 4x3 C*") == "@grid 4x3 C*")
        #expect(throws: TownError.self) { try CLI.loadLayout("@/nonexistent/file.txt") }
    }

    @Test func helpShowsEscapedNewlineInExample() {
        // The printf example must stay on one line (a raw \n in the Swift literal would break it).
        #expect(CLI.helpText.contains(#"printf 'U2{0,0}\nC*' | tinytowngen"#))
    }

    @Test func fileWithDirectivesReproducesCommandLineRender() throws {
        let fromFile = try LayoutParser.parseDocument("@grid 5x3 @seed 4 @border\nU2{0,0} F{2} C*")
        let (g, seed, border) = CLI.resolve(CLIOptions(), fromFile.settings)
        let a = Renderer.render(try Planner.plan(fromFile.placements, grid: g, seed: seed, atlas: atlas),
                                atlas: atlas, border: border)
        let b = Renderer.render(try Planner.plan(LayoutParser.parse("U2{0,0} F{2} C*"),
                                                 grid: GridSize(width: 5, height: 3), seed: 4, atlas: atlas),
                                atlas: atlas, border: true)
        #expect(a.pixels == b.pixels)
    }
}
