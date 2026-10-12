import Foundation

/// Validated, fully resolved drawing instructions.
public struct Plan: Equatable {
    public struct Tile: Equatable {
        public var x, y: Int
        public var kind: PlacementKind
        public var variant: Int
        public var source: AtlasRect
    }
    public struct Park: Equatable {
        public var x, y: Int
        public var size: ParkSize
        public var sprite: ParkSprite
    }
    public struct Line: Equatable {
        public var kind: PlacementKind  // .firebreak or .waterway
        public var index: Int           // road row (F) or road column (W), 1...n-1
        public var span: Span           // tile range along the line
    }

    public var grid: GridSize
    public var tiles: [Tile] = []
    public var parks: [Park] = []
    public var lines: [Line] = []
}

public enum Planner {
    /// Validates placements against the grid and picks atlas variants.
    ///
    /// Variant index for multi-candidate patterns (C, CL/CR/CT/CB, B):
    /// `(tileCount mod seed + order) mod candidateCount`, where `order` counts
    /// cells of the same pattern in the order they were specified (0-based).
    public static func plan(_ placements: [Placement], grid: GridSize, seed: Int, atlas: Atlas) throws -> Plan {
        guard seed >= 1 else { throw TownError.usage("seed must be >= 1") }
        var plan = Plan(grid: grid)
        var mask = [[Int]](repeating: [Int](repeating: 0, count: grid.width), count: grid.height)
        // Which token claimed each quadrant mask, for error messages.
        var owner = [[String]](repeating: [String](repeating: "", count: grid.width), count: grid.height)
        var order: [String: Int] = [:]
        let base = grid.tileCount % seed

        func claim(_ x: Int, _ y: Int, _ m: Int, _ token: String) throws {
            if mask[y][x] & m != 0 {
                throw TownError.overlap(token: token, other: owner[y][x], x: x, y: y)
            }
            mask[y][x] |= m
            owner[y][x] = token
        }

        func pickVariant(_ kind: PlacementKind, explicit: Int?, token: String) throws -> (Int, AtlasRect) {
            let pool: [AtlasRect]
            switch kind {
            case .commercial, .commercialPart: pool = atlas.commercial
            case .half(let s): pool = atlas.halves[s] ?? []
            case .building, .buildingPart: pool = atlas.buildings
            default: fatalError("no variants for \(kind)")
            }
            guard !pool.isEmpty else { throw TownError.resource("no atlas pieces for '\(token)'") }
            let n = order[kind.orderKey, default: 0]
            order[kind.orderKey] = n + 1
            if let explicit {
                guard explicit < pool.count else {
                    throw TownError.syntax(token: token, "variant #\(explicit) does not exist (0-\(pool.count - 1))")
                }
                return (explicit, pool[explicit])
            }
            let idx = (base + n) % pool.count
            return (idx, pool[idx])
        }

        func checkSpan(_ s: Span, _ limit: Int, _ axis: String, _ token: String) throws {
            guard s.lo >= 0, s.hi < limit else {
                throw TownError.outOfBounds(token: token,
                    "\(axis)=\(s.lo == s.hi ? "\(s.lo)" : "\(s.lo)-\(s.hi)") exceeds grid \(grid.width)x\(grid.height) (\(axis) must be 0-\(limit - 1))")
            }
        }

        // Pass 1: explicit tiles, parks, and lines, in spec order.
        for p in placements where !p.fill {
            switch p.kind {
            case .commercial, .half, .building, .commercialPart, .buildingPart:
                let xs = p.a!, ys = p.b!
                try checkSpan(xs, grid.width, "x", p.token)
                try checkSpan(ys, grid.height, "y", p.token)
                for y in ys.lo...ys.hi {
                    for x in xs.lo...xs.hi {
                        try claim(x, y, Quadrants.mask(p.kind), p.token)
                        let (v, rect) = try pickVariant(p.kind, explicit: p.variant, token: p.token)
                        plan.tiles.append(.init(x: x, y: y, kind: p.kind, variant: v, source: rect))
                    }
                }
            case .park(let size):
                guard let sprite = atlas.parkSprite(for: size) else {
                    let avail = atlas.parkSizes.map(\.description)
                    throw TownError.syntax(token: p.token,
                        "no urban forest of size \(size.w)x\(size.h); available: \(avail.joined(separator: ", "))")
                }
                let x = p.a!.lo, y = p.b!.lo
                try checkSpan(Span(x, x + size.w - 1), grid.width, "x", p.token)
                try checkSpan(Span(y, y + size.h - 1), grid.height, "y", p.token)
                for yy in y..<y + size.h {
                    for xx in x..<x + size.w { try claim(xx, yy, Quadrants.full, p.token) }
                }
                plan.parks.append(.init(x: x, y: y, size: size, sprite: sprite))
            case .firebreak, .waterway:
                let isF = p.kind == .firebreak
                let lineCount = isF ? grid.height : grid.width
                let index = p.a!.lo
                guard index >= 1, index <= lineCount - 1 else {
                    throw TownError.outOfBounds(token: p.token,
                        "\(isF ? "road row" : "road column") \(index) does not exist (must be 1-\(lineCount - 1); road k lies between \(isF ? "tile rows" : "tile columns") k-1 and k)")
                }
                let alongLimit = isF ? grid.width : grid.height
                let span = p.b ?? Span(0, alongLimit - 1)
                try checkSpan(span, alongLimit, isF ? "x" : "y", p.token)
                plan.lines.append(.init(kind: p.kind, index: index, span: span))
            }
        }

        // Pass 2: fills ("C*", "B*") take every cell still empty; a cell holding a
        // single half is completed with the opposite half.
        for p in placements where p.fill {
            for y in 0..<grid.height {
                for x in 0..<grid.width {
                    let kind: PlacementKind
                    if mask[y][x] == 0 {
                        kind = p.kind
                    } else if p.kind == .commercial, let side = Quadrants.complement(of: mask[y][x]) {
                        kind = .half(side)
                    } else {
                        continue
                    }
                    try claim(x, y, Quadrants.mask(kind), p.token)
                    let explicit = kind == p.kind ? p.variant : nil
                    let (v, rect) = try pickVariant(kind, explicit: explicit, token: p.token)
                    plan.tiles.append(.init(x: x, y: y, kind: kind, variant: v, source: rect))
                }
            }
        }

        // Urban forests may not be crossed by a boulevard or waterway.
        for park in plan.parks {
            for line in plan.lines {
                let (across, alongLo, alongHi) = line.kind == .firebreak
                    ? (park.y, park.x, park.x + park.size.w - 1)
                    : (park.x, park.y, park.y + park.size.h - 1)
                let acrossLen = line.kind == .firebreak ? park.size.h : park.size.w
                let crosses = line.index > across && line.index < across + acrossLen
                let overlapsAlong = line.span.lo <= alongHi && line.span.hi >= alongLo
                if crosses && overlapsAlong {
                    let parkToken = "\(park.size){\(park.x),\(park.y)}"
                    let letter = line.kind == .firebreak ? "F" : "W"
                    let lineToken = "\(letter){\(line.index),\(line.span.lo)-\(line.span.hi)}"
                    throw TownError.parkCrossesLine(park: parkToken, line: lineToken)
                }
            }
        }
        return plan
    }
}
