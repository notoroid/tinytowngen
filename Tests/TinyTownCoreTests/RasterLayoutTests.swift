import Foundation
import Testing
@testable import TinyTownCore

@Suite struct RasterLayoutTests {
    private func parse(_ text: String, _ w: Int, _ h: Int) throws -> [Placement] {
        try RasterLayout.parse(text, grid: GridSize(width: w, height: h), parkSizes: atlas.parkSizes)
    }

    /// All problems reported for `text`, or [] if it parses.
    private func issues(_ text: String, _ w: Int, _ h: Int) -> [String] {
        do { _ = try parse(text, w, h); return [] } catch TownError.raster(let list) { return list } catch { return ["\(error)"] }
    }

    private func render(_ placements: [Placement], _ w: Int, _ h: Int, seed: Int = 1) throws -> Bitmap {
        Renderer.render(try Planner.plan(placements, grid: GridSize(width: w, height: h), seed: seed, atlas: atlas), atlas: atlas)
    }

    // MARK: Equivalence with the -l layout

    @Test func rasterRendersLikeEquivalentLayout() throws {
        let raster = """
        C1 C2  C2 C2  U0 U0
        C4 C3  C4 C4  U0 U0
        F0F0 F0F0 F0F0
        C1 C3 R0 B0 B0  C1 C2
        C1 C3 R0 B0 B0  C4 C3
        """
        let layout = "C{0,0} CL{1,0} CR{1,0} U1{2,0} CT{0,1} CB{0,1} B{1,1} C{2,1} F{1} W{1,1-1}"
        let a = try render(parse(raster, 3, 2), 3, 2, seed: 7)
        let b = try render(LayoutParser.parse(layout), 3, 2, seed: 7)
        #expect(a.pixels == b.pixels)
    }

    @Test func separatorsAreOptional() throws {
        let spaced = try parse("C1 C2 C4 C3", 1, 1)
        let packed = try parse("C1C2,C4C3 # comment", 1, 1)
        #expect(spaced.map(\.kind) == [.commercial] && packed.map(\.kind) == [.commercial])
    }

    @Test func halvesFromUnitVectors() throws {
        // C1 C3 = horizontal half (top/bottom row); C2 over C4 = vertical half (left/right column).
        #expect(try parse("C1C3 C1C3", 1, 1).map(\.kind) == [.half(.top), .half(.bottom)])
        #expect(try parse("C2C2 C4C4", 1, 1).map(\.kind) == [.half(.left), .half(.right)])
        #expect(try parse("C1C3 C0B0", 1, 1).map(\.kind) == [.buildingPart(.bottomRight), .commercialPart(.bottomLeft), .half(.top)])
    }

    @Test func buildingsAndSingleParts() throws {
        #expect(try parse("B0B0 B0B0", 1, 1).map(\.kind) == [.building])
        #expect(try parse("B0C0 C0B0", 1, 1).map(\.kind)
            == [.buildingPart(.topLeft), .buildingPart(.bottomRight), .commercialPart(.topRight), .commercialPart(.bottomLeft)])
    }

    @Test func forestsFromTileAlignedRectangles() throws {
        let ok = try parse("U0U0U0U0 U0U0U0U0 U0U0U0U0 U0U0U0U0", 2, 2)
        #expect(ok.map(\.kind) == [.park(ParkSize(w: 2, h: 2))])
        let wide = try parse("U0U0U0U0 U0U0U0U0", 2, 1)
        #expect(wide.map(\.kind) == [.park(ParkSize(w: 2, h: 1))])
    }

    @Test func canalRunsAndBridges() throws {
        // Canal on road column 1 through both tile rows, crossing the firebreak -> bridge.
        let p = try parse("""
        C0C0 R0 C0C0
        C0C0 R0 C0C0
        F0F0F0F0
        C0C0 R0 C0C0
        C0C0 R0 C0C0
        """, 2, 2)
        let lines = p.filter { $0.kind == .firebreak || $0.kind == .waterway }
        #expect(lines.map(\.kind) == [.firebreak, .waterway])
        #expect(lines[1].a == Span(1, 1) && lines[1].b == Span(0, 1))
        let plan = try Planner.plan(p, grid: GridSize(width: 2, height: 2), seed: 1, atlas: atlas)
        #expect(Metrics.bridges(boulevards: plan.lines.filter { $0.kind == .firebreak },
                                waterways: plan.lines.filter { $0.kind == .waterway }, grid: plan.grid).count == 1)
        // Separate runs make separate waterways.
        let runs = try parse("C0C0R0C0C0 C0C0R0C0C0 C0C0C0C0 C0C0C0C0 C0C0R0C0C0 C0C0R0C0C0", 2, 3)
        #expect(runs.filter { $0.kind == .waterway }.map(\.b) == [Span(0, 0), Span(2, 2)])
    }

    @Test func singlePartsAreQuartersOfAWholeTile() throws {
        // Four C0 of variant n look exactly like the whole tile C of variant n.
        let quarters = try render(parse("C0C0 C0C0", 1, 1), 1, 1)
        let whole = Renderer.render(try Planner.plan(LayoutParser.parse("C{0,0}"), grid: GridSize(width: 1, height: 1),
                                                     seed: 1, atlas: atlas), atlas: atlas)
        // Each C0 takes the next variant, so compare the top-left quarter (variant 0) only.
        for y in 0..<10 { for x in 0..<10 { #expect(quarters.pixel(x, y) == whole.pixel(x, y)) } }
    }

    // MARK: Errors, each with a position and a fix

    @Test func partCountMustMatchGrid() {
        let short = issues("C0 C0 C0", 1, 1)
        #expect(short.count == 1 && short[0].contains("expected 4 parts") && short[0].contains("got 3")
                && short[0].contains("part row 1, col 1 (tile {0,0} bottom-right)"))
        let long = issues("C0C0 C0C0 B0 B0", 1, 1)
        #expect(long.count == 1 && long[0].contains("got 6") && long[0].contains("token #5 B0"))
        // F and R are not counted.
        #expect(issues("C0C0 R0 C0C0 C0C0 R0 C0C0", 2, 1).isEmpty)
    }

    @Test func badTokens() {
        #expect(issues("C0 X0 C0 C0 C0", 1, 1).contains { $0.contains("token #2 'X0'") })
        #expect(issues("C5C0 C0C0", 1, 1).contains { $0.contains("token #1 C5") && $0.contains("C1-C4") })
        #expect(issues("U1U0 U0U0", 1, 1).contains { $0.contains("token #1 U1") && $0.contains("use U0") })
        #expect(issues("B2B0 B0B0", 1, 1).contains { $0.contains("use B0") })
    }

    @Test func vectorsMustStayInTheTile() {
        let list = issues("C1C1 C4C3", 1, 1)
        #expect(list.count == 1)
        #expect(list[0].contains("token #2 C1 at part row 0, col 1 (tile {0,0} top-right) points right out of tile {0,0}"))
        #expect(list[0].contains("Use C3 here"))
        #expect(issues("C4C0 C0C0", 1, 1).contains { $0.contains("points up out of tile") })
    }

    @Test func vectorsMustFormABlock() {
        // TL points at TR, but TR pairs with BR.
        #expect(issues("C1C2 C0C4", 1, 1).contains { $0.contains("do not form a block") && $0.contains("C1 C2 / C4 C3") })
        // Pointing at a non-linked part.
        #expect(issues("C1C0 C0C0", 1, 1).contains { $0.contains("points right to token #2 C0") })
        // Counter-clockwise ring is not a valid block.
        #expect(!issues("C2C3 C1C4", 1, 1).isEmpty)
    }

    @Test func firebreaksAreHorizontalRowsOnRoads() {
        #expect(issues("C0F0C0 C0C0", 1, 1).contains { $0.contains("horizontal only") })
        #expect(issues("F0F0 C0C0 C0C0", 1, 1).contains { $0.contains("before the first part row") })
        #expect(issues("C0C0 F0F0 C0C0", 1, 1).contains { $0.contains("inside tile row 0") })
        #expect(issues("C0C0C0C0 C0C0C0C0 F0F0F0 C0C0C0C0 C0C0C0C0", 2, 2).contains { $0.contains("has 3 tokens") && $0.contains("add 1") })
        #expect(issues("C0C0 C0C0 F0F0 F0F0 C0C0 C0C0", 1, 2).contains { $0.contains("has 4 tokens") })
        #expect(issues("C0C0 C0C0 F1F0 C0C0 C0C0", 1, 2).contains { $0.contains("use F0") })
    }

    @Test func canalsAreVerticalOnRoads() {
        #expect(issues("R0C0C0 C0C0", 1, 1).contains { $0.contains("start of part row 0 (grid edge)") && $0.contains("vertical only") })
        #expect(issues("C0R0C0 C0C0", 1, 1).contains { $0.contains("inside tile {0,0}") })
        #expect(issues("C0C0R0C0C0 C0C0C0C0", 2, 1).contains { $0.contains("half a tile of canal") && $0.contains("add R0 to part row 1") })
    }

    @Test func forestsMustNotBeCrossed() {
        let f = issues("U0U0U0U0 U0U0U0U0 F0F0F0F0 U0U0U0U0 U0U0U0U0", 2, 2)
        #expect(f.contains { $0.contains("F row starting at token #9") && $0.contains("crosses the urban forest at tiles {0,0}-{1,1}") })
        let r = issues("U0U0R0U0U0 U0U0R0U0U0 C0C0C0C0 C0C0C0C0", 2, 2)
        #expect(r.contains { $0.contains("R0 between part cols 1 and 2 in part rows 0-1") && $0.contains("crosses the urban forest") })
        // Along the edge is fine.
        #expect(issues("U0U0R0C0C0 U0U0R0C0C0", 2, 1).isEmpty)
    }

    @Test func forestShapeAndSize() {
        #expect(issues("U0U0 U0C0", 1, 1).contains { $0.contains("not a rectangle") && $0.contains("token #4 C0") })
        #expect(issues("U0U0C0C0 C0C0C0C0", 2, 1).contains { $0.contains("does not cover whole tiles") })
        #expect(issues("U0U0U0U0U0U0U0U0 U0U0U0U0U0U0U0U0", 4, 1).contains { $0.contains("4x1 tiles, which has no forest sprite") })
    }

    @Test func reportsAllProblemsTogether() {
        let list = issues("C1C1 C4C3 U1U0 U0U0", 1, 2)
        #expect(list.count == 2)
        let message = TownError.raster(list).description
        #expect(message.hasPrefix("raster layout has 2 problems:"))
    }

    @Test func helpExampleParses() throws {
        let example = "C1C2 C0B0 C4C3 B0C0 F0F0F0F0 U0U0 R0 C2C2 U0U0 R0 C4C4"
        #expect(CLI.helpText.contains(example))
        // Forests first, then tiles in raster order, then firebreaks and canals.
        #expect(try parse(example, 2, 2).map(\.kind) == [
            .park(ParkSize(w: 1, h: 1)),
            .commercial,                                                   // tile {0,0}
            .buildingPart(.topRight), .buildingPart(.bottomLeft),          // tile {1,0}
            .commercialPart(.topLeft), .commercialPart(.bottomRight),
            .half(.left), .half(.right),                                   // tile {1,1}
            .firebreak, .waterway,
        ])
    }

    @Test func cliOptions() throws {
        let o = try CLIOptions.parse(["-r", "C0C0C0C0", "-o", "a.png", "-g", "1x1"])
        #expect(o.raster == "C0C0C0C0")
        #expect(throws: TownError.self) { try CLIOptions.parse(["-r", "C0", "-l", "C*", "-o", "a.png"]) }
        #expect(throws: TownError.self) { try CLIOptions.parse(["-r", "C0", "--list-variants", "C", "-o", "a.png"]) }
        #expect(CLI.run(["-g", "1x1", "-r", "C0 C0 C0", "-o", "/dev/null"]) == 1)
    }
}
