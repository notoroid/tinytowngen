import Foundation

public indirect enum TownError: Error, Equatable, CustomStringConvertible {
    case usage(String)
    case syntax(token: String, String)
    case outOfBounds(token: String, String)
    case overlap(token: String, other: String, x: Int, y: Int)
    case parkCrossesLine(park: String, line: String)
    case resource(String)
    case output(String)
    /// Wraps a syntax error with its 1-based line number in a multi-line layout.
    case atLine(Int, TownError)
    /// Every problem found in a raster layout, each naming its token and part position.
    case raster([String])

    public var description: String {
        switch self {
        case .usage(let m): "usage: \(m)"
        case .syntax(let t, let m): "syntax error in '\(t)': \(m)"
        case .outOfBounds(let t, let m): "out of bounds: '\(t)' \(m)"
        case .overlap(let t, let o, let x, let y): "overlap: '\(t)' overlaps '\(o)' at tile {\(x),\(y)}"
        case .parkCrossesLine(let p, let l): "conflict: urban forest '\(p)' cannot be crossed by '\(l)'"
        case .resource(let m): "resource error: \(m)"
        case .output(let m): "output error: \(m)"
        case .atLine(let n, let e): "line \(n): \(e)"
        case .raster(let issues):
            "raster layout has \(issues.count) problem\(issues.count == 1 ? "" : "s"):\n" + issues.map { "  - \($0)" }.joined(separator: "\n")
        }
    }
}

public struct GridSize: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }

    /// Parses "13x7".
    public init(parsing s: String) throws {
        let parts = s.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else {
            throw TownError.usage("grid size must look like WxH with positive integers (e.g. 13x7), got '\(s)'")
        }
        self.init(width: w, height: h)
    }

    public var tileCount: Int { width * height }
}

public enum PlacementKind: Equatable, Sendable {
    case commercial
    case half(HalfSide)
    /// One part (quarter) of a tile, cut from a full commercial block (raster `C0`).
    case commercialPart(Quadrant)
    /// One part (quarter) of a tile, cut from a full building sprite (raster `B0`).
    case buildingPart(Quadrant)
    case building
    case park(ParkSize)
    case firebreak
    case waterway

    /// Key used to count "指定順番" for seed-based variant selection.
    var orderKey: String {
        switch self {
        case .commercial: "C"
        case .half(let s): "C" + s.rawValue
        case .commercialPart: "C0"
        case .buildingPart: "B0"
        case .building: "B"
        case .park(let p): p.description
        case .firebreak: "F"
        case .waterway: "W"
        }
    }
}

/// Render settings written inside a layout with `@grid`, `@seed`, `@border`.
/// Command-line options take precedence over them.
public struct LayoutSettings: Equatable, Sendable {
    public var grid: GridSize?
    public var seed: Int?
    public var border = false
}

/// A parsed layout: placements plus any settings directives.
public struct LayoutDocument: Equatable, Sendable {
    public var placements: [Placement] = []
    public var settings = LayoutSettings()
}

/// An inclusive integer range written as `n` or `a-b`.
public struct Span: Equatable, Sendable {
    public var lo: Int
    public var hi: Int
    public init(_ lo: Int, _ hi: Int) { self.lo = lo; self.hi = hi }
}

/// One parsed token of the layout string.
public struct Placement: Equatable, Sendable {
    public var token: String
    public var kind: PlacementKind
    /// Tile kinds: x/y spans. F: `a` = road row, `b` = optional x span. W: `a` = road column, `b` = optional y span.
    public var a: Span?
    public var b: Span?
    /// `*` form: fill every remaining empty cell.
    public var fill: Bool
    public var variant: Int?
}

/// Per-tile occupancy bitmask of quadrants: TL=1, TR=2, BL=4, BR=8.
enum Quadrants {
    static let full = 0b1111
    static func mask(_ kind: PlacementKind) -> Int {
        switch kind {
        case .half(.left): 0b0101
        case .half(.right): 0b1010
        case .half(.top): 0b0011
        case .half(.bottom): 0b1100
        case .commercialPart(let q), .buildingPart(let q): 1 << q.rawValue
        default: full
        }
    }
    static func complement(of mask: Int) -> HalfSide? {
        switch mask {
        case 0b0101: .right
        case 0b1010: .left
        case 0b0011: .bottom
        case 0b1100: .top
        default: nil
        }
    }
}
