import Foundation

/// Parses the layout string, e.g. `"U3{0,0} C{3-12,0-6} F{4} W{3,0-2} B{5,5}#1 C*"`.
public enum LayoutParser {
    public static func parse(_ text: String) throws -> [Placement] {
        let tokens = text
            .split(whereSeparator: { $0 == ";" || $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { throw TownError.usage("layout is empty") }
        return try tokens.map(parseToken)
    }

    static func parseToken(_ token: String) throws -> Placement {
        var rest = Substring(token)

        // Optional "#n" variant suffix.
        var variant: Int?
        if let hash = rest.lastIndex(of: "#") {
            guard let v = Int(rest[rest.index(after: hash)...]), v >= 0 else {
                throw TownError.syntax(token: token, "variant after '#' must be a non-negative integer")
            }
            variant = v
            rest = rest[..<hash]
        }

        // Head (kind letters + size) and body ("{...}" or "*").
        let headEnd = rest.firstIndex(where: { $0 == "{" || $0 == "*" }) ?? rest.endIndex
        let head = String(rest[..<headEnd])
        let body = rest[headEnd...]

        let kind = try parseKind(head, token: token)
        if variant != nil, case .park = kind {
            throw TownError.syntax(token: token, "urban forest has no variants; remove '#\(variant!)'")
        }
        if variant != nil, kind == .firebreak || kind == .waterway {
            throw TownError.syntax(token: token, "'#' variants are not supported for F/W")
        }

        if body == "*" {
            switch kind {
            case .commercial, .building:
                return Placement(token: token, kind: kind, fill: true, variant: variant)
            default:
                throw TownError.syntax(token: token, "'*' (fill) is only allowed for C and B")
            }
        }
        guard body.hasPrefix("{"), body.hasSuffix("}"), body.count >= 2 else {
            throw TownError.syntax(token: token, "expected '{...}' after '\(head)'")
        }
        let args = try body.dropFirst().dropLast()
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { try parseSpan($0.trimmingCharacters(in: .whitespaces), token: token) }

        switch kind {
        case .firebreak, .waterway:
            guard args.count == 1 || args.count == 2 else {
                throw TownError.syntax(token: token, "expected {line} or {line,from-to}")
            }
            guard args[0].lo == args[0].hi else {
                throw TownError.syntax(token: token, "road line index must be a single number, not a range")
            }
            return Placement(token: token, kind: kind, a: args[0], b: args.count == 2 ? args[1] : nil,
                             fill: false, variant: nil)
        case .park:
            guard args.count == 2, args.allSatisfy({ $0.lo == $0.hi }) else {
                throw TownError.syntax(token: token, "urban forest takes a single top-left {x,y} (no ranges)")
            }
            return Placement(token: token, kind: kind, a: args[0], b: args[1], fill: false, variant: nil)
        default:
            guard args.count == 2 else {
                throw TownError.syntax(token: token, "expected {x,y} (each may be a range like 2-5)")
            }
            return Placement(token: token, kind: kind, a: args[0], b: args[1], fill: false, variant: variant)
        }
    }

    static func parseKind(_ head: String, token: String) throws -> PlacementKind {
        switch head {
        case "C", "C1": return .commercial
        case "CL": return .half(.left)
        case "CR": return .half(.right)
        case "CT": return .half(.top)
        case "CB": return .half(.bottom)
        case "B": return .building
        case "F": return .firebreak
        case "W": return .waterway
        default: break
        }
        if head.hasPrefix("U") {
            let dims = head.dropFirst().split(separator: "x", omittingEmptySubsequences: false)
            if dims.count == 1, let n = Int(dims[0]), n > 0 {
                return .park(ParkSize(w: n, h: n))
            }
            if dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]), w > 0, h > 0 {
                return .park(ParkSize(w: w, h: h))
            }
            throw TownError.syntax(token: token, "urban forest size must be Un or UWxH (e.g. U2, U1x2)")
        }
        throw TownError.syntax(token: token, "unknown pattern '\(head)' (use C, CL, CR, CT, CB, B, Un, UWxH, F, W)")
    }

    static func parseSpan(_ s: String, token: String) throws -> Span {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 1, let v = Int(parts[0]) { return Span(v, v) }
        if parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]) {
            guard lo <= hi else { throw TownError.syntax(token: token, "range '\(s)' must be ascending") }
            return Span(lo, hi)
        }
        throw TownError.syntax(token: token, "'\(s)' is not a number or range (n or a-b)")
    }
}
