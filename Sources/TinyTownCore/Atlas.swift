import Foundation

/// A rectangle in atlas pixel space.
public struct AtlasRect: Equatable, Sendable {
    public var x, y, w, h: Int
}

/// One entry of `tiles.json`.
struct PieceRecord: Decodable {
    let id: String
    let kind: String
    let zone: String?
    let atlas_x: Int
    let atlas_y: Int
    let atlas_w: Int
    let atlas_h: Int
    let split: String?
    let local_rect: [Int]?

    var rect: AtlasRect { AtlasRect(x: atlas_x, y: atlas_y, w: atlas_w, h: atlas_h) }
}

private struct TilesFile: Decodable {
    let pieces: [PieceRecord]
}

/// Which part of a 19x19 tile a commercial half occupies.
/// One of the four parts (2x2) of a tile, as used by the raster layout.
public enum Quadrant: Int, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    public var name: String {
        switch self {
        case .topLeft: "top-left"
        case .topRight: "top-right"
        case .bottomLeft: "bottom-left"
        case .bottomRight: "bottom-right"
        }
    }
}

public enum HalfSide: String, CaseIterable, Sendable {
    case left = "L", right = "R", top = "T", bottom = "B"
}

/// Park footprint in tiles.
public struct ParkSize: Hashable, Sendable, CustomStringConvertible {
    public var w: Int
    public var h: Int
    public var description: String { w == h ? "U\(w)" : "U\(w)x\(h)" }
}

/// An urban-forest sprite, possibly drawn rotated 90° clockwise.
public struct ParkSprite: Equatable, Sendable {
    public var source: AtlasRect
    public var rotated: Bool
}

/// Sprite catalog built from the embedded atlas and tiles.json.
public struct Atlas: Sendable {
    public let image: Bitmap
    public let commercial: [AtlasRect]
    public let halves: [HalfSide: [AtlasRect]]
    public let buildings: [AtlasRect]
    public let parks: [ParkSize: AtlasRect]
    public let boulevard: AtlasRect
    public let canal: AtlasRect
    /// Short canal closed at both ends (`canal_S`): single-tile waterways and end caps.
    public let canalShort: AtlasRect

    /// Park pieces in the atlas, keyed by their tile footprint.
    static let parkIDs: [String: ParkSize] = [
        "park_D": ParkSize(w: 1, h: 1),
        "park_B": ParkSize(w: 1, h: 2),
        "park_C": ParkSize(w: 2, h: 2),
        "park_A": ParkSize(w: 3, h: 3),
    ]

    public static func loadEmbedded() throws -> Atlas {
        guard let png = Data(base64Encoded: EmbeddedResources.patternsPNG),
              let json = Data(base64Encoded: EmbeddedResources.tilesJSON) else {
            throw TownError.resource("embedded resources are not valid base64")
        }
        return try Atlas(png: png, json: json)
    }

    init(png: Data, json: Data) throws {
        image = try Bitmap(pngData: png)
        let pieces = try JSONDecoder().decode(TilesFile.self, from: json).pieces

        var commercial: [AtlasRect] = []
        var halves: [HalfSide: [AtlasRect]] = [:]
        var buildings: [AtlasRect] = []
        var parks: [ParkSize: AtlasRect] = [:]
        var boulevard: AtlasRect?
        var canal: AtlasRect?
        var canalShort: AtlasRect?

        for p in pieces {
            switch p.kind {
            case "block" where p.zone == "commercial_zone":
                commercial.append(p.rect)
            case "block_half":
                // Vertical half (≈10x19): usable as either a left or right half.
                halves[.left, default: []].append(p.rect)
                halves[.right, default: []].append(p.rect)
            case "block_part":
                guard let lr = p.local_rect, lr.count == 4 else { continue }
                let side: HalfSide = p.split == "v"
                    ? (lr[0] == 0 ? .left : .right)
                    : (lr[1] == 0 ? .top : .bottom)
                halves[side, default: []].append(p.rect)
            case "building":
                buildings.append(p.rect)
            case "urban_forest":
                if let size = Atlas.parkIDs[p.id] { parks[size] = p.rect }
            case "river_canal" where p.id == "canal_N":
                canal = p.rect
            case "river_canal" where p.id == "canal_S":
                canalShort = p.rect
            case "firebreak_boulevard":
                boulevard = p.rect
            default:
                break
            }
        }
        guard let boulevard, let canal, let canalShort, !commercial.isEmpty, !buildings.isEmpty else {
            throw TownError.resource("tiles.json is missing required pieces")
        }
        self.commercial = commercial
        self.halves = halves
        self.buildings = buildings
        self.parks = parks
        self.boulevard = boulevard
        self.canal = canal
        self.canalShort = canalShort
    }

    /// The sprite for an urban forest of `size`. A non-square piece also serves its transposed
    /// size by drawing it rotated 90° clockwise (e.g. the 1x2 piece gives U2x1).
    public func parkSprite(for size: ParkSize) -> ParkSprite? {
        if let rect = parks[size] { return ParkSprite(source: rect, rotated: false) }
        if let rect = parks[ParkSize(w: size.h, h: size.w)] { return ParkSprite(source: rect, rotated: true) }
        return nil
    }

    /// Every forest size that `parkSprite(for:)` can serve.
    public var parkSizes: [ParkSize] {
        Set(parks.keys.flatMap { [$0, ParkSize(w: $0.h, h: $0.w)] }).sorted { ($0.w, $0.h) < ($1.w, $1.h) }
    }

    /// Number of selectable variants for a placement kind (nil if the kind has no variants).
    public func variantCount(for kind: PlacementKind) -> Int? {
        switch kind {
        case .commercial: commercial.count
        case .half(let side): halves[side]?.count ?? 0
        case .building: buildings.count
        case .commercialPart: commercial.count
        case .buildingPart: buildings.count
        default: nil
        }
    }
}
