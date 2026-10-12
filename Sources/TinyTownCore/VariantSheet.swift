import Foundation

/// Contact sheet of atlas variants, each labelled with its `#n`: one pattern, or
/// every pattern stacked in sections with a header naming the pattern.
public enum VariantSheet {
    static let columns = 8
    static let gap = 2
    static let labelHeight = 5
    static let background = RGBA(hex: 0x303030)
    static let labelColor = RGBA(hex: 0xFFFFFF)
    static let headerColor = RGBA(hex: 0xFFD54A)

    /// Patterns that have variants, in display order, as written in the layout grammar.
    public static let allKinds: [(name: String, kind: PlacementKind)] = [
        ("C", .commercial), ("CL", .half(.left)), ("CR", .half(.right)),
        ("CT", .half(.top)), ("CB", .half(.bottom)), ("B", .building),
    ]

    public static func parseKind(_ s: String) throws -> PlacementKind {
        guard let kind = allKinds.first(where: { $0.name == s })?.kind else {
            throw TownError.usage("--list-variants takes one of C, CL, CR, CT, CB, B, all; got '\(s)'")
        }
        return kind
    }

    /// `all` or a single pattern name.
    public static func parseTarget(_ s: String) throws -> [PlacementKind] {
        s == "all" ? allKinds.map(\.kind) : [try parseKind(s)]
    }

    /// One pattern: the plain sheet. Several: sections stacked top to bottom, each under its name.
    public static func render(_ kinds: [PlacementKind], atlas: Atlas) -> Bitmap {
        if kinds.count == 1 { return render(kinds[0], atlas: atlas) }
        let sections = kinds.map { render($0, atlas: atlas) }
        let headerH = gap + labelHeight
        var sheet = Bitmap(width: sections.map(\.width).max() ?? 0,
                           height: sections.reduce(0) { $0 + headerH + $1.height }, fill: background)
        var y = 0
        for (kind, section) in zip(kinds, sections) {
            drawText(kind.orderKey, into: &sheet, x: gap, y: y + gap, color: headerColor)
            y += headerH
            sheet.blitFit(section, AtlasRect(x: 0, y: 0, w: section.width, h: section.height),
                          dx: 0, dy: y, dw: section.width, dh: section.height)
            y += section.height
        }
        return sheet
    }

    public static func render(_ kind: PlacementKind, atlas: Atlas) -> Bitmap {
        let pool: [AtlasRect]
        switch kind {
        case .commercial: pool = atlas.commercial
        case .half(let side): pool = atlas.halves[side] ?? []
        case .building: pool = atlas.buildings
        default: pool = []
        }
        let t = Metrics.tile
        let cellW = t + gap, cellH = t + 1 + labelHeight + gap
        let cols = min(columns, max(1, pool.count))
        let rows = (pool.count + cols - 1) / cols
        var sheet = Bitmap(width: gap + cols * cellW, height: gap + max(1, rows) * cellH, fill: background)

        for (i, rect) in pool.enumerated() {
            let ox = gap + (i % cols) * cellW, oy = gap + (i / cols) * cellH
            if case .half(let side) = kind {
                // Show the half where it sits inside a tile.
                sheet.fillRect(x: ox, y: oy, w: t, h: t, color: Metrics.groundColor)
                let r = Metrics.halfRect(side)
                sheet.blitFit(atlas.image, rect, dx: ox + r.x, dy: oy + r.y, dw: r.w, dh: r.h)
            } else {
                sheet.blitFit(atlas.image, rect, dx: ox, dy: oy, dw: t, dh: t)
            }
            let label = String(i)
            let labelW = label.count * 4 - 1
            drawText(label, into: &sheet, x: ox + (t - labelW) / 2, y: oy + t + 1, color: labelColor)
        }
        return sheet
    }

    /// 3x5 pixel glyphs (digits and the pattern letters), one row per string, '#' = lit.
    static let glyphs: [Character: [String]] = [
        "C": ["###", "#..", "#..", "#..", "###"],
        "L": ["#..", "#..", "#..", "#..", "###"],
        "R": ["##.", "#.#", "##.", "#.#", "#.#"],
        "T": ["###", ".#.", ".#.", ".#.", ".#."],
        "B": ["##.", "#.#", "##.", "#.#", "##."],
        "0": ["###", "#.#", "#.#", "#.#", "###"],
        "1": [".#.", "##.", ".#.", ".#.", "###"],
        "2": ["###", "..#", "###", "#..", "###"],
        "3": ["###", "..#", "###", "..#", "###"],
        "4": ["#.#", "#.#", "###", "..#", "..#"],
        "5": ["###", "#..", "###", "..#", "###"],
        "6": ["###", "#..", "###", "#.#", "###"],
        "7": ["###", "..#", "..#", "..#", "..#"],
        "8": ["###", "#.#", "###", "#.#", "###"],
        "9": ["###", "#.#", "###", "..#", "###"],
    ]

    static func drawText(_ s: String, into b: inout Bitmap, x: Int, y: Int, color: RGBA) {
        for (i, ch) in s.enumerated() {
            guard let glyph = glyphs[ch] else { continue }
            for (gy, row) in glyph.enumerated() {
                for (gx, px) in row.enumerated() where px == "#" {
                    b.fillRect(x: x + i * 4 + gx, y: y + gy, w: 1, h: 1, color: color)
                }
            }
        }
    }
}
