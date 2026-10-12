import Foundation

/// Pixel geometry of the town.
public enum Metrics {
    public static let tile = 19
    public static let road = 2
    public static let pitch = tile + road
    /// Boulevard / canal sprite thickness; they cover the 2px road and spill into neighbouring tiles.
    public static let boulevardThickness = 14
    public static let canalThickness = 6
    /// Rows of `canal_N` (relative to its top) where its green channel is closed off by stone:
    /// a closed north end and a closed south end. Used to cap partial waterways so the cap
    /// shares the canal's own colours.
    static let canalCapTopRows = 0..<3
    static let canalCapBottomRows = 16..<20

    public static let roadColor = RGBA(hex: 0x777777)
    public static let groundColor = RGBA(hex: 0x8A8272)

    /// Canvas size; `margin` is the outer road width (0, or `road` with --border).
    public static func canvasSize(_ g: GridSize, margin: Int = 0) -> (Int, Int) {
        (g.width * pitch - road + 2 * margin, g.height * pitch - road + 2 * margin)
    }

    /// Pixel extent covered by `n` tiles plus the roads between them.
    static func span(_ n: Int) -> Int { n * tile + (n - 1) * road }

    public static let parapetColor = RGBA(hex: 0xC9C5BA)
    public static let bridgeShadowColor = RGBA(hex: 0x2E332C)

    /// Pixel rectangle drawn for a boulevard or waterway: its sprite band centered on the replaced road.
    /// With a margin (outer road), ends that reach the grid edge continue across it to the image edge.
    static func band(of line: Plan.Line, grid: GridSize, margin: Int = 0,
                     extendToEdge: Bool = true) -> (x: Int, y: Int, w: Int, h: Int) {
        let last = (line.kind == .firebreak ? grid.width : grid.height) - 1
        let roadStart = margin + line.index * pitch - road
        var alongStart = margin + line.span.lo * pitch
        var alongLen = line.span.hi * pitch + tile - line.span.lo * pitch
        if extendToEdge && line.span.lo == 0 { alongStart -= margin; alongLen += margin }
        if extendToEdge && line.span.hi == last { alongLen += margin }
        if line.kind == .firebreak {
            let thick = boulevardThickness
            return (alongStart, roadStart - (thick - road) / 2, alongLen, thick)
        }
        let thick = canalThickness
        return (roadStart - (thick - road) / 2, alongStart, thick, alongLen)
    }

    /// Bridge decks: where a boulevard fully crosses a waterway that continues on both sides of it.
    /// Each rectangle is the canal-wide part of the boulevard band.
    static func bridges(boulevards: [Plan.Line], waterways: [Plan.Line], grid: GridSize,
                        margin: Int = 0) -> [(x: Int, y: Int, w: Int, h: Int)] {
        var out: [(x: Int, y: Int, w: Int, h: Int)] = []
        for f in boulevards {
            for w in waterways {
                // Boulevard spans the canal's column; canal has tiles above and below the boulevard.
                let crossesColumn = f.span.lo < w.index && f.span.hi >= w.index
                let crossesRow = w.span.lo < f.index && w.span.hi >= f.index
                guard crossesColumn && crossesRow else { continue }
                let fb = band(of: f, grid: grid, margin: margin), wb = band(of: w, grid: grid, margin: margin)
                out.append((wb.x, fb.y, wb.w, fb.h))
            }
        }
        return out
    }

    static func halfRect(_ side: HalfSide) -> (x: Int, y: Int, w: Int, h: Int) {
        let a = (tile + 1) / 2  // 10
        switch side {
        case .left: return (0, 0, a, tile)
        case .right: return (a, 0, tile - a, tile)
        case .top: return (0, 0, tile, a)
        case .bottom: return (0, a, tile, tile - a)
        }
    }
}

public enum Renderer {
    /// - Parameter border: also draw the 2 px road around the outside of the grid.
    public static func render(_ plan: Plan, atlas: Atlas, border: Bool = false) -> Bitmap {
        let m = border ? Metrics.road : 0
        let (w, h) = Metrics.canvasSize(plan.grid, margin: m)
        var canvas = Bitmap(width: w, height: h, fill: Metrics.roadColor)
        let p = Metrics.pitch, t = Metrics.tile

        // Empty tiles show bare ground.
        for y in 0..<plan.grid.height {
            for x in 0..<plan.grid.width {
                canvas.fillRect(x: m + x * p, y: m + y * p, w: t, h: t, color: Metrics.groundColor)
            }
        }

        for tile in plan.tiles {
            let ox = m + tile.x * p, oy = m + tile.y * p
            if case .half(let side) = tile.kind {
                let r = Metrics.halfRect(side)
                canvas.blitFit(atlas.image, tile.source, dx: ox + r.x, dy: oy + r.y, dw: r.w, dh: r.h)
            } else {
                canvas.blitFit(atlas.image, tile.source, dx: ox, dy: oy, dw: t, dh: t)
            }
        }

        for park in plan.parks {
            let dw = Metrics.span(park.size.w), dh = Metrics.span(park.size.h)
            if park.sprite.rotated {
                let turned = atlas.image.rotatedClockwise(park.sprite.source)
                canvas.blitScaled(turned, AtlasRect(x: 0, y: 0, w: turned.width, h: turned.height),
                                  dx: m + park.x * p, dy: m + park.y * p, dw: dw, dh: dh)
            } else {
                canvas.blitScaled(atlas.image, park.sprite.source, dx: m + park.x * p, dy: m + park.y * p,
                                  dw: dw, dh: dh)
            }
        }

        // Waterways first, then boulevards, which cross them on bridges.
        let waterways = plan.lines.filter { $0.kind == .waterway }
        let boulevards = plan.lines.filter { $0.kind == .firebreak }
        for line in waterways {
            let band = Metrics.band(of: line, grid: plan.grid, margin: m)
            let short = atlas.canalShort
            if line.span.lo == line.span.hi {
                // A single-tile waterway is the short canal piece on its own, kept within its tile.
                let b = Metrics.band(of: line, grid: plan.grid, margin: m, extendToEdge: false)
                canvas.blitFit(atlas.image, short, dx: b.x, dy: b.y, dw: b.w, dh: b.h)
                continue
            }
            canvas.blitTiled(atlas.image, atlas.canal, dx: band.x, dy: band.y, dw: band.w, dh: band.h,
                             phaseY: band.y)
            // Ends inside the grid are closed off; ends at the image edge run out of frame.
            if line.span.lo > 0 {
                let rows = Metrics.canalCapTopRows, h = rows.count
                let cap = AtlasRect(x: atlas.canal.x, y: atlas.canal.y + rows.lowerBound, w: atlas.canal.w, h: h)
                canvas.blitFit(atlas.image, cap, dx: band.x, dy: band.y, dw: band.w, dh: h)
            }
            if line.span.hi < plan.grid.height - 1 {
                let rows = Metrics.canalCapBottomRows, h = rows.count
                let cap = AtlasRect(x: atlas.canal.x, y: atlas.canal.y + rows.lowerBound, w: atlas.canal.w, h: h)
                canvas.blitFit(atlas.image, cap, dx: band.x, dy: band.y + band.h - h, dw: band.w, dh: h)
            }
        }
        for line in boulevards {
            let band = Metrics.band(of: line, grid: plan.grid, margin: m)
            canvas.blitTiled(atlas.image, atlas.boulevard, dx: band.x, dy: band.y, dw: band.w, dh: band.h,
                             phaseX: band.x)
        }
        for bridge in Metrics.bridges(boulevards: boulevards, waterways: waterways, grid: plan.grid, margin: m) {
            // Parapets along both edges of the deck, and the deck's shadow on the water below.
            canvas.fillRect(x: bridge.x, y: bridge.y, w: bridge.w, h: 1, color: Metrics.parapetColor)
            canvas.fillRect(x: bridge.x, y: bridge.y + bridge.h - 1, w: bridge.w, h: 1, color: Metrics.parapetColor)
            canvas.fillRect(x: bridge.x, y: bridge.y + bridge.h, w: bridge.w, h: 1, color: Metrics.bridgeShadowColor)
        }
        return canvas
    }
}
