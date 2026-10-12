import Foundation

/// Pixel geometry of the town.
public enum Metrics {
    public static let tile = 19
    public static let road = 2
    public static let pitch = tile + road
    /// Boulevard / canal sprite thickness; they cover the 2px road and spill into neighbouring tiles.
    public static let boulevardThickness = 14
    public static let canalThickness = 6
    /// Rows of `canal_S` showing its closed north / south end, used to cap partial waterways.
    static let canalCapTop = 3
    static let canalCapBottom = 4

    public static let roadColor = RGBA(hex: 0x777777)
    public static let groundColor = RGBA(hex: 0x8A8272)

    public static func canvasSize(_ g: GridSize) -> (Int, Int) {
        (g.width * pitch - road, g.height * pitch - road)
    }

    /// Pixel extent covered by `n` tiles plus the roads between them.
    static func span(_ n: Int) -> Int { n * tile + (n - 1) * road }

    public static let parapetColor = RGBA(hex: 0xC9C5BA)
    public static let bridgeShadowColor = RGBA(hex: 0x2E332C)

    /// Pixel rectangle drawn for a boulevard or waterway: its sprite band centered on the replaced road.
    static func band(of line: Plan.Line) -> (x: Int, y: Int, w: Int, h: Int) {
        let roadStart = line.index * pitch - road
        let alongStart = line.span.lo * pitch
        let alongLen = line.span.hi * pitch + tile - alongStart
        if line.kind == .firebreak {
            let thick = boulevardThickness
            return (alongStart, roadStart - (thick - road) / 2, alongLen, thick)
        }
        let thick = canalThickness
        return (roadStart - (thick - road) / 2, alongStart, thick, alongLen)
    }

    /// Bridge decks: where a boulevard fully crosses a waterway that continues on both sides of it.
    /// Each rectangle is the canal-wide part of the boulevard band.
    static func bridges(boulevards: [Plan.Line], waterways: [Plan.Line]) -> [(x: Int, y: Int, w: Int, h: Int)] {
        var out: [(x: Int, y: Int, w: Int, h: Int)] = []
        for f in boulevards {
            for w in waterways {
                // Boulevard spans the canal's column; canal has tiles above and below the boulevard.
                let crossesColumn = f.span.lo < w.index && f.span.hi >= w.index
                let crossesRow = w.span.lo < f.index && w.span.hi >= f.index
                guard crossesColumn && crossesRow else { continue }
                let fb = band(of: f), wb = band(of: w)
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
    public static func render(_ plan: Plan, atlas: Atlas) -> Bitmap {
        let (w, h) = Metrics.canvasSize(plan.grid)
        var canvas = Bitmap(width: w, height: h, fill: Metrics.roadColor)
        let p = Metrics.pitch, t = Metrics.tile

        // Empty tiles show bare ground.
        for y in 0..<plan.grid.height {
            for x in 0..<plan.grid.width {
                canvas.fillRect(x: x * p, y: y * p, w: t, h: t, color: Metrics.groundColor)
            }
        }

        for tile in plan.tiles {
            let ox = tile.x * p, oy = tile.y * p
            if case .half(let side) = tile.kind {
                let r = Metrics.halfRect(side)
                canvas.blitFit(atlas.image, tile.source, dx: ox + r.x, dy: oy + r.y, dw: r.w, dh: r.h)
            } else {
                canvas.blitFit(atlas.image, tile.source, dx: ox, dy: oy, dw: t, dh: t)
            }
        }

        for park in plan.parks {
            canvas.blitScaled(atlas.image, park.source, dx: park.x * p, dy: park.y * p,
                              dw: Metrics.span(park.size.w), dh: Metrics.span(park.size.h))
        }

        // Waterways first, then boulevards, which cross them on bridges.
        let waterways = plan.lines.filter { $0.kind == .waterway }
        let boulevards = plan.lines.filter { $0.kind == .firebreak }
        for line in waterways {
            let band = Metrics.band(of: line)
            let short = atlas.canalShort
            if line.span.lo == line.span.hi {
                // A single-tile waterway is the short canal piece on its own.
                canvas.blitFit(atlas.image, short, dx: band.x, dy: band.y, dw: band.w, dh: band.h)
                continue
            }
            canvas.blitTiled(atlas.image, atlas.canal, dx: band.x, dy: band.y, dw: band.w, dh: band.h,
                             phaseY: band.y)
            // Ends inside the grid are closed off; ends at the image edge run out of frame.
            if line.span.lo > 0 {
                let h = Metrics.canalCapTop
                let cap = AtlasRect(x: short.x, y: short.y, w: short.w, h: h)
                canvas.blitFit(atlas.image, cap, dx: band.x, dy: band.y, dw: band.w, dh: h)
            }
            if line.span.hi < plan.grid.height - 1 {
                let h = Metrics.canalCapBottom
                let cap = AtlasRect(x: short.x, y: short.y + short.h - h, w: short.w, h: h)
                canvas.blitFit(atlas.image, cap, dx: band.x, dy: band.y + band.h - h, dw: band.w, dh: h)
            }
        }
        for line in boulevards {
            let band = Metrics.band(of: line)
            canvas.blitTiled(atlas.image, atlas.boulevard, dx: band.x, dy: band.y, dw: band.w, dh: band.h,
                             phaseX: band.x)
        }
        for bridge in Metrics.bridges(boulevards: boulevards, waterways: waterways) {
            // Parapets along both edges of the deck, and the deck's shadow on the water below.
            canvas.fillRect(x: bridge.x, y: bridge.y, w: bridge.w, h: 1, color: Metrics.parapetColor)
            canvas.fillRect(x: bridge.x, y: bridge.y + bridge.h - 1, w: bridge.w, h: 1, color: Metrics.parapetColor)
            canvas.fillRect(x: bridge.x, y: bridge.y + bridge.h, w: bridge.w, h: 1, color: Metrics.bridgeShadowColor)
        }
        return canvas
    }
}
