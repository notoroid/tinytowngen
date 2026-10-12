import Foundation

/// A map pattern: which embedded atlas to draw with, plus the colours drawn without sprites.
public struct MapTheme: Sendable, Equatable {
    public let name: String
    /// One-line description for --help.
    public let summary: String
    let pngBase64: String
    let jsonBase64: String
    public let roadColor: RGBA
    /// Bare ground of tiles with nothing on them.
    public let groundColor: RGBA
    public let parapetColor: RGBA
    public let bridgeShadowColor: RGBA

    public static func == (a: MapTheme, b: MapTheme) -> Bool { a.name == b.name }

    /// Modern aerial photo tiles (the original atlas). Default.
    public static let sapporo = MapTheme(
        name: "sapporo", summary: "modern city from aerial photos (default)",
        pngBase64: EmbeddedResources.patternsPNG, jsonBase64: EmbeddedResources.tilesJSON,
        roadColor: RGBA(hex: 0x777777), groundColor: RGBA(hex: 0x8A8272),
        parapetColor: RGBA(hex: 0xC9C5BA), bridgeShadowColor: RGBA(hex: 0x2E332C))

    /// 11th-century Heian-kyo in pixel art: walled compounds, temples, river, great avenues.
    public static let heiankyo11c = MapTheme(
        name: "heiankyo11c", summary: "11th-century Heian-kyo (Kyoto), pixel art",
        pngBase64: EmbeddedResources.heiankyoPNG, jsonBase64: EmbeddedResources.heiankyoJSON,
        roadColor: RGBA(hex: 0xBF763A), groundColor: RGBA(hex: 0xCDAE7F),
        parapetColor: RGBA(hex: 0xB8432F), bridgeShadowColor: RGBA(hex: 0x3A2A1E))

    public static let all: [MapTheme] = [.sapporo, .heiankyo11c]

    public static func named(_ name: String) throws -> MapTheme {
        guard let theme = all.first(where: { $0.name == name }) else {
            throw TownError.usage("unknown map '\(name)' (use \(all.map(\.name).joined(separator: ", ")))")
        }
        return theme
    }
}
