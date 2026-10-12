import Testing
@testable import TinyTownCore

private let atlas = try! Atlas.loadEmbedded()
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
        #expect(img.width == 61 && img.height == 40)
        #expect(img.pixel(19, 5) == Metrics.roadColor)   // vertical road
        #expect(img.pixel(30, 20) == Metrics.roadColor)  // horizontal road
        #expect(img.pixel(25, 5) == Metrics.groundColor) // empty tile
    }

    /// Canal column for vertical road 1: 6 px wide, centered on the road at x=19..20.
    private func canalColumn(_ img: Bitmap, y: Int) -> [RGBA] { (17..<23).map { img.pixel($0, y) } }

    private func expected(_ src: AtlasRect, dy: Int, dh: Int, tiled: Bool = false) -> Bitmap {
        var b = Bitmap(width: 61, height: 61)
        if tiled {
            b.blitTiled(atlas.image, src, dx: 17, dy: dy, dw: 6, dh: dh, phaseY: dy)
        } else {
            b.blitFit(atlas.image, src, dx: 17, dy: dy, dw: 6, dh: dh)
        }
        return b
    }

    @Test func singleTileWaterwayUsesShortCanal() throws {
        let img = Renderer.render(try plan("W{1,1-1}", grid: GridSize(width: 3, height: 3)), atlas: atlas)
        let want = expected(atlas.canalShort, dy: 21, dh: 19)
        for y in 21..<40 { #expect(canalColumn(img, y: y) == canalColumn(want, y: y)) }
    }

    @Test func partialWaterwayIsCappedOnlyInsideGrid() throws {
        let img = Renderer.render(try plan("W{1,0-1}", grid: GridSize(width: 3, height: 3)), atlas: atlas)
        let s = atlas.canalShort
        let capH = Metrics.canalCapBottom
        let bottomCap = expected(AtlasRect(x: s.x, y: s.y + s.h - capH, w: s.w, h: capH), dy: 40 - capH, dh: capH)
        for y in (40 - capH)..<40 { #expect(canalColumn(img, y: y) == canalColumn(bottomCap, y: y)) }
        // Top end touches the image edge: plain canal body, no cap.
        let body = expected(atlas.canal, dy: 0, dh: 40, tiled: true)
        for y in 0..<Metrics.canalCapTop { #expect(canalColumn(img, y: y) == canalColumn(body, y: y)) }
    }

    private func region(_ img: Bitmap, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> [RGBA] {
        (y..<y + h).flatMap { yy in (x..<x + w).map { img.pixel($0, yy) } }
    }

    @Test func narrowParkIsScaledNotCropped() throws {
        let img = Renderer.render(try plan("U1x2{0,0}", grid: GridSize(width: 1, height: 2)), atlas: atlas)
        let src = atlas.parks[ParkSize(w: 1, h: 2)]!
        #expect(src.w > Metrics.tile)  // park_B is wider than one tile, so it must shrink
        var scaled = Bitmap(width: 19, height: 40), cropped = scaled
        scaled.blitScaled(atlas.image, src, dx: 0, dy: 0, dw: 19, dh: 40)
        cropped.blitFit(atlas.image, src, dx: 0, dy: 0, dw: 19, dh: 40)
        #expect(region(img, 0, 0, 19, 40) == region(scaled, 0, 0, 19, 40))
        #expect(region(img, 0, 0, 19, 40) != region(cropped, 0, 0, 19, 40))
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
                               waterways: p.lines.filter { $0.kind == .waterway }).count
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
        let img = Renderer.render(try plan("F{2} W{2}", grid: GridSize(width: 4, height: 4)), atlas: atlas)
        // Canal band x=38..43; boulevard band y=34..47.
        for x in 38..<44 {
            #expect(img.pixel(x, 34) == Metrics.parapetColor)
            #expect(img.pixel(x, 47) == Metrics.parapetColor)
            #expect(img.pixel(x, 48) == Metrics.bridgeShadowColor)
        }
        // The deck between the parapets is boulevard, not canal.
        var deck = Bitmap(width: 82, height: 82)
        deck.blitTiled(atlas.image, atlas.boulevard, dx: 0, dy: 34, dw: 82, dh: 14, phaseX: 0)
        for y in 35..<47 { #expect(img.pixel(40, y) == deck.pixel(40, y)) }
    }

    @Test func boulevardReplacesRoad() throws {
        let img = Renderer.render(try plan("F{1}", grid: GridSize(width: 3, height: 2)), atlas: atlas)
        #expect(img.pixel(30, 20) != Metrics.roadColor)
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
