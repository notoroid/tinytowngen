import Foundation

/// Raster layout: the city as a stream of parts, 2x2 parts per tile, row by row, left to right.
///
/// A grid of W x H tiles has (2W) x (2H) parts. Each part is a letter plus a digit
/// (separators optional: `C1C3` = `C1 C3`):
///
/// - `C0`: one commercial part on its own. `C1`..`C4` link the part to its neighbour in the
///   same tile by a unit vector: C1 = (1,0) right, C2 = (0,-1) down, C3 = (-1,0) left,
///   C4 = (0,1) up. Valid blocks: `C1 C3` (horizontal half), `C2` over `C4` (vertical half),
///   `C1 C2 / C4 C3` (whole tile).
/// - `B0`: building part; four in one tile make a whole building tile.
/// - `U0`: urban-forest part; a tile-aligned rectangle of U0 is one forest of a supported size.
///
/// Firebreaks and canals replace roads, so they are not parts and are not counted:
/// - `F0` row: between two tile rows (before part row 2, 4, ...), `F0F0` per tile, 2W tokens.
/// - `R0`: inside a part row, between the parts of two neighbouring tiles (on the road);
///   `R0R0` (one in each of a tile's two part rows) is one tile of canal.
///
/// `#` starts a comment to the end of the line. All problems are reported together, each
/// with the token number, part row/column, tile and a suggested fix.
public enum RasterLayout {
    struct Token {
        let letter: Character
        let digit: Int
        let index: Int  // 1-based position in the stream
        /// Position in the part grid, once the token has been placed as a part.
        var part: (x: Int, y: Int)?
        var text: String { "\(letter)\(digit)" }
    }

    public static func parse(_ text: String, grid: GridSize, parkSizes: [ParkSize]) throws -> [Placement] {
        var issues: [String] = []
        let tokens = tokenize(text, &issues)
        let pw = grid.width * 2, ph = grid.height * 2

        // Where roads are in the part grid, for messages.
        func list(_ items: [String]) -> String {
            items.isEmpty ? "(none: the grid has no inner road)" : items.count <= 6 ? items.joined(separator: ", ")
                : (items.prefix(3) + ["...", items.last!]).joined(separator: ", ")
        }
        let roadRows = list((1..<max(1, grid.height)).map { "before part row \($0 * 2)" })
        let roadCols = list((1..<max(1, grid.width)).map { "between part cols \($0 * 2 - 1)|\($0 * 2)" })

        // 1. Walk the stream: parts fill (2W x 2H) in raster order; F rows and R0 sit on roads.
        var parts = [[Token?]](repeating: [Token?](repeating: nil, count: pw), count: ph)
        var boulevards: [Int: Token] = [:]                 // road row -> first F token
        var canalMarks: [Int: [Int: Token]] = [:]          // road column -> part row -> R token
        var extra: [Token] = []
        var pr = 0, pc = 0, i = 0
        while i < tokens.count {
            let t = tokens[i]
            switch t.letter {
            case "F":
                guard pc == 0 else {
                    issues.append("\(describe(t)) is inside part row \(pr) (after col \(pc - 1)): firebreaks are horizontal only. "
                        + "Give a whole row of \(pw) F0 (F0F0 per tile) between two tile rows: \(roadRows)")
                    i += 1
                    continue
                }
                var run: [Token] = []
                while i < tokens.count, tokens[i].letter == "F" { run.append(tokens[i]); i += 1 }
                let span = "F row \(describe(run[0]))\(run.count > 1 ? "-#\(run.last!.index)" : "") before part row \(pr)"
                if pr % 2 != 0 || pr == 0 || pr >= ph {
                    let at = pr >= ph ? "after the last part row" : pr == 0 ? "before the first part row" : "inside tile row \(pr / 2) (between part rows \(pr - 1) and \(pr))"
                    issues.append("\(span) is \(at): a firebreak replaces a road between tile rows, so the F row must come \(roadRows)")
                } else if run.count != pw {
                    issues.append("\(span) has \(run.count) tokens: a firebreak row needs exactly \(pw) (F0F0 per tile x \(grid.width) tiles); \(run.count < pw ? "add \(pw - run.count)" : "remove \(run.count - pw)")")
                } else if boulevards[pr / 2] != nil {
                    issues.append("\(span) repeats the firebreak on road row \(pr / 2); remove one of the two F rows")
                } else {
                    boulevards[pr / 2] = run[0]
                }
                for f in run where f.digit != 0 { issues.append("\(describe(f)): firebreak parts take no direction; use F0") }
            case "R":
                if pr < ph, pc % 2 == 0, pc > 0, pc < pw {
                    if t.digit != 0 { issues.append("\(describe(t)): canal parts take no direction; use R0") }
                    if canalMarks[pc / 2, default: [:]][pr] != nil {
                        issues.append("\(describe(t)) repeats R0 at part row \(pr) between cols \(pc - 1) and \(pc); remove one")
                    }
                    canalMarks[pc / 2, default: [:]][pr] = t
                } else {
                    let at = pr >= ph ? "after the last part" : pc == 0 ? "at the start of part row \(pr) (grid edge)"
                        : pc == pw ? "at the end of part row \(pr) (grid edge)" : "inside tile {\(pc / 2),\(pr / 2)} (between part cols \(pc - 1) and \(pc))"
                    issues.append("\(describe(t)) is \(at): a canal replaces a road between tile columns, so R0 must sit inside a part row \(roadCols) (canals are vertical only)")
                }
                i += 1
            default:
                if pr < ph {
                    var placed = t
                    placed.part = (pc, pr)
                    parts[pr][pc] = placed
                    pc += 1
                    if pc == pw { pc = 0; pr += 1 }
                } else {
                    extra.append(t)
                }
                i += 1
            }
        }

        // 2. Part count (F/R are not counted).
        let expected = pw * ph
        let got = pr * pw + pc + extra.count
        if pr < ph {
            issues.insert("expected \(expected) parts for grid \(grid.width)x\(grid.height) (\(pw) x \(ph); F/R not counted), got \(got): "
                + "missing \(expected - got) part(s) from \(partName(pc, pr)) on", at: 0)
            throw TownError.raster(issues)
        }
        if let first = extra.first {
            issues.insert("expected \(expected) parts for grid \(grid.width)x\(grid.height) (\(pw) x \(ph); F/R not counted), got \(got): "
                + "\(extra.count) extra part(s) from token #\(first.index) \(first.text) on; remove them or enlarge the grid", at: 0)
            throw TownError.raster(issues)
        }
        let grid2 = parts.map { $0.map { $0! } }

        // 3. Urban forests: tile-aligned rectangles of U0.
        var placements: [Placement] = []
        var forests: [(x: Int, y: Int, w: Int, h: Int)] = []
        var seen = [[Bool]](repeating: [Bool](repeating: false, count: pw), count: ph)
        for y in 0..<ph {
            for x in 0..<pw where grid2[y][x].letter == "U" && !seen[y][x] {
                var stack = [(x, y)], cells: [(Int, Int)] = []
                seen[y][x] = true
                while let (cx, cy) = stack.popLast() {
                    cells.append((cx, cy))
                    for (nx, ny) in [(cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)]
                    where nx >= 0 && ny >= 0 && nx < pw && ny < ph && !seen[ny][nx] && grid2[ny][nx].letter == "U" {
                        seen[ny][nx] = true
                        stack.append((nx, ny))
                    }
                }
                let x0 = cells.map(\.0).min()!, x1 = cells.map(\.0).max()!
                let y0 = cells.map(\.1).min()!, y1 = cells.map(\.1).max()!
                let region = "urban forest at part rows \(y0)-\(y1), cols \(x0)-\(x1) (starting with \(describe(grid2[y0][x0])))"
                let w = x1 - x0 + 1, h = y1 - y0 + 1
                if cells.count != w * h {
                    let hole = (y0...y1).lazy.flatMap { yy in (x0...x1).lazy.map { (xx: $0, yy: yy) } }
                        .first { grid2[$0.yy][$0.xx].letter != "U" }!
                    issues.append("\(region) is not a rectangle: \(describe(grid2[hole.yy][hole.xx])) is not U0; make the region a filled rectangle of whole tiles")
                    continue
                }
                if x0 % 2 != 0 || y0 % 2 != 0 || w % 2 != 0 || h % 2 != 0 {
                    issues.append("\(region) does not cover whole tiles: a forest must start at an even part row/col and span an even number of parts (U0U0 / U0U0 per tile)")
                    continue
                }
                let size = ParkSize(w: w / 2, h: h / 2)
                // Crossing is checked for every tile-aligned region, even of an unsupported size.
                forests.append((x0 / 2, y0 / 2, size.w, size.h))
                guard parkSizes.contains(size) else {
                    issues.append("\(region) is \(size.w)x\(size.h) tiles, which has no forest sprite; available: "
                        + parkSizes.map { "\($0.w)x\($0.h)" }.joined(separator: ", ")
                        + " tiles (neighbouring forests merge into one region: separate them with another part)")
                    continue
                }
                placements.append(Placement(token: "raster U\(size.w)x\(size.h) at tile {\(x0 / 2),\(y0 / 2)}", kind: .park(size),
                                            a: Span(x0 / 2, x0 / 2), b: Span(y0 / 2, y0 / 2), fill: false, variant: nil))
            }
        }

        // 4. Tiles: commercial blocks from unit vectors, buildings, and single parts.
        for ty in 0..<grid.height {
            for tx in 0..<grid.width {
                let q = Quadrant.allCases.map { grid2[ty * 2 + $0.rawValue / 2][tx * 2 + $0.rawValue % 2] }
                placements += tilePlacements(tx, ty, q, &issues)
            }
        }

        // 5. Roads: firebreaks and canals, which must not cross a forest.
        for (road, first) in boulevards.sorted(by: { $0.key < $1.key }) {
            for f in forests where f.y < road && road < f.y + f.h {
                // Roads just outside the forest that exist in the grid.
                let free = [f.y, f.y + f.h].filter { $0 >= 1 && $0 <= grid.height - 1 }.map { "before part row \($0 * 2)" }
                issues.append("F row starting at token #\(first.index) (road row \(road), before part row \(road * 2)) crosses the urban forest at tiles {\(f.x),\(f.y)}-{\(f.x + f.w - 1),\(f.y + f.h - 1)}: "
                    + (free.isEmpty ? "remove the F row or make the forest smaller" : "move the F row to \(free.joined(separator: " or ")), or move the forest"))
            }
            placements.append(Placement(token: "raster F row at road row \(road)", kind: .firebreak, a: Span(road, road), b: nil, fill: false, variant: nil))
        }
        for (road, marks) in canalMarks.sorted(by: { $0.key < $1.key }) {
            var rows: [Int] = []
            for ty in 0..<grid.height {
                switch (marks[ty * 2], marks[ty * 2 + 1]) {
                case (.some, .some): rows.append(ty)
                case (.some(let t), nil), (nil, .some(let t)):
                    let missing = marks[ty * 2] == nil ? ty * 2 : ty * 2 + 1
                    issues.append("\(describe(t)) gives only half a tile of canal: R0R0 (one R0 in each of part rows \(ty * 2) and \(ty * 2 + 1), between cols \(road * 2 - 1) and \(road * 2)) is one tile; "
                        + "add R0 to part row \(missing) or remove this one")
                case (nil, nil): break
                }
            }
            // Contiguous tile rows form one waterway.
            var start: Int?
            for (k, row) in rows.enumerated() {
                if start == nil { start = row }
                if k == rows.count - 1 || rows[k + 1] != row + 1 {
                    let span = Span(start!, row)
                    for f in forests where f.x < road && road < f.x + f.w && span.lo < f.y + f.h && span.hi >= f.y {
                        let lo = max(span.lo, f.y), hi = min(span.hi, f.y + f.h - 1)
                        issues.append("R0 between part cols \(road * 2 - 1) and \(road * 2) in part rows \(lo * 2)-\(hi * 2 + 1) (first: \(describe(marks[lo * 2]!))) crosses the urban forest at tiles {\(f.x),\(f.y)}-{\(f.x + f.w - 1),\(f.y + f.h - 1)}: "
                            + "remove R0 from those part rows or move the forest")
                    }
                    placements.append(Placement(token: "raster R0 at road column \(road), tile rows \(span.lo)-\(span.hi)", kind: .waterway,
                                                a: Span(road, road), b: span, fill: false, variant: nil))
                    start = nil
                }
            }
        }

        if !issues.isEmpty { throw TownError.raster(issues) }
        return placements
    }

    /// Unit vectors of C1...C4 in screen coordinates (y grows downwards; C2 = (0,-1) points down).
    static let vectors: [Int: (dx: Int, dy: Int, name: String)] = [
        1: (1, 0, "right"), 2: (0, 1, "down"), 3: (-1, 0, "left"), 4: (0, -1, "up"),
    ]

    /// Placements for one tile; `q` holds its parts in Quadrant order (TL, TR, BL, BR).
    static func tilePlacements(_ tx: Int, _ ty: Int, _ q: [Token], _ issues: inout [String]) -> [Placement] {
        func at(_ quad: Quadrant) -> Token { q[quad.rawValue] }
        func token(_ kind: String) -> String { "raster \(kind) at tile {\(tx),\(ty)}" }
        func place(_ kind: PlacementKind, _ name: String) -> Placement {
            Placement(token: token(name), kind: kind, a: Span(tx, tx), b: Span(ty, ty), fill: false, variant: nil)
        }
        var out: [Placement] = []
        let before = issues.count

        for t in q where (t.letter == "U" || t.letter == "B") && t.digit != 0 {
            issues.append("\(describe(t)): \(t.letter == "U" ? "urban forest" : "building") parts take no direction; use \(t.letter)0")
        }
        for t in q where t.letter == "C" && t.digit > 4 {
            issues.append("\(describe(t)): commercial parts are C0 (none) or C1-C4 (unit vector right/down/left/up)")
        }

        // Buildings: four B0 make a whole building, otherwise each B0 is a single part.
        let buildings = Quadrant.allCases.filter { at($0).letter == "B" }
        if buildings.count == 4 {
            out.append(place(.building, "B"))
        } else {
            out += buildings.map { place(.buildingPart($0), "B0 (\($0.name))") }
        }

        // Commercial parts.
        let linked = Quadrant.allCases.filter { at($0).letter == "C" && (1...4).contains(at($0).digit) }
        out += Quadrant.allCases.filter { at($0).letter == "C" && at($0).digit == 0 }.map { place(.commercialPart($0), "C0 (\($0.name))") }
        if linked.isEmpty { return issues.count == before ? out : [] }

        // Each linked part must point at another linked commercial part of the same tile.
        var target: [Quadrant: Quadrant] = [:]
        for quad in linked {
            let t = at(quad), v = vectors[t.digit]!
            let cx = quad.rawValue % 2 + v.dx, cy = quad.rawValue / 2 + v.dy
            guard (0...1).contains(cx), (0...1).contains(cy) else {
                issues.append("\(describe(t)) points \(v.name) out of tile {\(tx),\(ty)} across the road; a vector must point to a part of the same tile. "
                    + "Use \(fixes(for: quad)), or C0 for a single part")
                continue
            }
            let other = Quadrant(rawValue: cy * 2 + cx)!
            let o = at(other)
            guard o.letter == "C", o.digit != 0 else {
                issues.append("\(describe(t)) points \(v.name) to \(describe(o)), which is not a linked commercial part (C1-C4). "
                    + "Make it part of the block, or use C0 for a single part")
                continue
            }
            target[quad] = other
        }
        guard issues.count == before else { return [] }

        let whole: [Quadrant: Int] = [.topLeft: 1, .topRight: 2, .bottomRight: 3, .bottomLeft: 4]
        if linked.count == 4 && Quadrant.allCases.allSatisfy({ at($0).digit == whole[$0] }) {
            return out + [place(.commercial, "C")]
        }
        var paired = Set<Quadrant>()
        for quad in linked where !paired.contains(quad) {
            let other = target[quad]!
            guard target[other] == quad else {
                issues.append("\(describe(at(quad))) and \(describe(at(other))) do not form a block in tile {\(tx),\(ty)}: "
                    + "use C1 C3 for a horizontal half, C2 over C4 for a vertical half, or C1 C2 / C4 C3 for a whole tile")
                paired.insert(quad)
                continue
            }
            paired.formUnion([quad, other])
            let pair = Set([quad, other])
            let side: HalfSide = pair == [.topLeft, .topRight] ? .top : pair == [.bottomLeft, .bottomRight] ? .bottom
                : pair == [.topLeft, .bottomLeft] ? .left : .right
            out.append(place(.half(side), "C\(side.rawValue)"))
        }
        return issues.count == before ? out : []
    }

    /// Valid ways to use a linked part at `quad`.
    static func fixes(for quad: Quadrant) -> String {
        switch quad {
        case .topLeft: "C1 here (pair with C3 at top-right) or C2 (pair with C4 at bottom-left)"
        case .topRight: "C3 here (pair with C1 at top-left) or C2 (pair with C4 at bottom-right)"
        case .bottomLeft: "C1 here (pair with C3 at bottom-right) or C4 (pair with C2 at top-left)"
        case .bottomRight: "C3 here (pair with C1 at bottom-left) or C4 (pair with C2 at top-right)"
        }
    }

    // MARK: Tokens and positions

    static func tokenize(_ text: String, _ issues: inout [String]) -> [Token] {
        var out: [Token] = []
        var chars = Array(text)[...]
        while let c = chars.first {
            if c.isWhitespace || c == "," || c == ";" { chars.removeFirst(); continue }
            if c == "#" {
                while let d = chars.first, !d.isNewline { chars.removeFirst() }
                continue
            }
            chars.removeFirst()
            let digits = chars.prefix { $0.isASCII && $0.isNumber }
            chars.removeFirst(digits.count)
            let index = out.count + 1
            guard "CUBFR".contains(c), let d = Int(String(digits)) else {
                issues.append("token #\(index) '\(c)\(String(digits))': each part is a letter C, U, B, F or R followed by a digit (e.g. C1, U0)")
                continue
            }
            out.append(Token(letter: c, digit: d, index: index))
        }
        return out
    }

    /// Position of a part in the part grid, with its tile.
    static func partName(_ px: Int, _ py: Int) -> String {
        let quad = Quadrant(rawValue: (py % 2) * 2 + px % 2)!
        return "part row \(py), col \(px) (tile {\(px / 2),\(py / 2)} \(quad.name))"
    }

    static func describe(_ t: Token) -> String {
        "token #\(t.index) \(t.text)" + (t.part.map { " at \(partName($0.x, $0.y))" } ?? "")
    }
}
