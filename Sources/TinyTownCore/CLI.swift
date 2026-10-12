import Foundation

public struct CLIOptions: Equatable {
    public var layout: String?
    /// `--raster`: the city as a stream of 2x2 parts per tile (see `RasterLayout`).
    public var raster: String?
    public var output: String?
    /// nil: not given on the command line (fall back to the layout's @grid, then 13x7).
    public var grid: GridSize?
    /// nil: not given on the command line (fall back to the layout's @seed, then 1).
    public var seed: Int?
    public static let defaultGrid = GridSize(width: 13, height: 7)
    public static let defaultSeed = 1
    public var scale = 1
    public var verbose = false
    public var border = false
    public var help = false
    /// `--list-variants`: render a contact sheet of these patterns instead of a town.
    public var listVariants: [PlacementKind]?

    public init() {}

    public static func parse(_ args: [String]) throws -> CLIOptions {
        var o = CLIOptions()
        var i = 0
        func value(_ name: String, inline: String?) throws -> String {
            if let inline { return inline }
            i += 1
            guard i < args.count else { throw TownError.usage("\(name) requires a value") }
            return args[i]
        }
        while i < args.count {
            var arg = args[i]
            var inline: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                inline = String(arg[arg.index(after: eq)...])
                arg = String(arg[..<eq])
            }
            switch arg {
            case "-h", "--help": o.help = true
            case "-v", "--verbose": o.verbose = true
            case "--border": o.border = true
            case "-l", "--layout": o.layout = try value(arg, inline: inline)
            case "-r", "--raster": o.raster = try value(arg, inline: inline)
            case "--list-variants": o.listVariants = try VariantSheet.parseTarget(value(arg, inline: inline))
            case "-o", "--output": o.output = try value(arg, inline: inline)
            case "-g", "--grid": o.grid = try GridSize(parsing: value(arg, inline: inline))
            case "-s", "--seed":
                let v = try value(arg, inline: inline)
                guard let n = Int(v), n >= 1 else { throw TownError.usage("--seed must be an integer >= 1, got '\(v)'") }
                o.seed = n
            case "--scale":
                let v = try value(arg, inline: inline)
                guard let n = Int(v), (1...32).contains(n) else { throw TownError.usage("--scale must be 1-32, got '\(v)'") }
                o.scale = n
            default:
                throw TownError.usage("unknown option '\(arg)' (see --help)")
            }
            i += 1
        }
        if !o.help {
            let modes = [o.layout != nil, o.raster != nil, o.listVariants != nil].filter { $0 }.count
            if modes > 1 {
                throw TownError.usage("use only one of --layout, --raster and --list-variants")
            }
            if modes == 0 {
                throw TownError.usage("--layout or --raster is required (see --help)")
            }
            if o.output == nil { throw TownError.usage("--output is required (see --help)") }
        }
        return o
    }
}

public enum CLI {
    public static let helpText = """
    tinytowngen - render an aerial PNG of a grid city from a text layout

    USAGE
      tinytowngen -l <layout|@file|@-> -o <file.png> [-g WxH] [-s seed] [--border] [--scale n] [-v]
      tinytowngen -r <parts|@file|@-> -o <file.png> [-g WxH] [-s seed] [--border] [--scale n] [-v]
      tinytowngen --list-variants <C|CL|CR|CT|CB|B|all> -o <sheet.png> [--scale n]

    OPTIONS
      -l, --layout <string>  (required) Placement string. See LAYOUT.
                             @path reads it from a file, @- from stdin. A value
                             containing spaces is always an inline layout, so a
                             path with spaces must be passed as: -l @- < "path".
      -r, --raster <string>  Instead of -l: the city as a stream of parts. See RASTER.
                             @path / @- read it from a file / stdin, like -l.
      -o, --output <path>    (required) Output PNG path.
      -g, --grid <WxH>       Grid size in tiles. Default: layout's @grid, else 13x7.
      -s, --seed <int>       Seed (>= 1) for picking C/CL/CR/CT/CB/B variants.
                             Default: layout's @seed, else 1.
          --border           Also draw a 2 px road around the outside of the grid
                             (also enabled by @border in the layout).
          --scale <int>      Integer nearest-neighbour upscale of the output (1-32). Default: 1.
      -v, --verbose          Print every resolved placement (and its variant) to stderr.
          --list-variants <P> Instead of a town, write a contact sheet of every
                             variant of pattern P (C, CL, CR, CT, CB or B), each
                             labelled with the n to use as P{x,y}#n. P=all puts
                             all six patterns on one sheet, one section each
                             under a yellow header naming the pattern.
                             Needs -o; cannot be combined with -l.
      -h, --help             Show this help.

    GEOMETRY
      Tiles are 19x19 px separated by 2 px roads (#777777). Tile {x,y} is
      0-based from the top-left; its pixel origin is (x*21, y*21).
      Image size = (W*21-2) x (H*21-2) px, e.g. 13x7 -> 271x145.
      With --border every pixel position shifts by +2 and the image is
      (W*21+2) x (H*21+2) px, e.g. 13x7 -> 275x149. F/W lines that reach the
      grid edge then continue across the outer road to the image edge.
      Road lines are numbered 1..W-1 (vertical) and 1..H-1 (horizontal);
      road k lies between tile column/row k-1 and k.

    LAYOUT
      Tokens separated by spaces, newlines or ';'. Later tokens never overwrite
      earlier ones - any overlap is an error. Unspecified tiles are bare ground.
      A word starting with '#' begins a comment to the end of the line
      (C{1,2}#3 is a variant, but C{1,2} #3 is a token plus a comment).

      Directives (anywhere in the layout; the value is the next word):
      @grid WxH     Grid size, like -g.         @seed N   Seed, like -s.
      @border       Outer road, like --border.
      Command-line -g/-s override @grid/@seed; @border and --border add up.
      A layout file with directives reproduces the same image on its own.

      C{x,y}        Commercial block, 1 tile.               (alias: C1{x,y})
      CL{x,y}       Commercial half: left  half of the tile (also CR right,
      CT{x,y}         CT top, CB bottom). CL+CR or CT+CB share one tile.
      B{x,y}        Building under construction, 1 tile.
      U<n>{x,y}     Urban forest n x n tiles, top-left at {x,y}. Covers the
      U<w>x<h>{x,y}   roads inside it. Sizes: U1, U2, U3, U1x2, U2x1 (U1x2 turned 90°).
      F{r}          Fire-block boulevard replacing horizontal road r (full width).
      F{r,x0-x1}      ...only along tile columns x0..x1.
      W{c}          Waterway replacing vertical road c (full height).
      W{c,y0-y1}      ...only along tile rows y0..y1. Ends inside the grid are
                      drawn closed; a single row (W{c,y-y}) is a short canal.
                      Where F crosses W and W continues on both sides of it, F is
                      drawn as a bridge over the canal; a W that ends at an F runs
                      under it.
      C*  B*        Fill every still-empty tile (C* also completes lone halves).

      Ranges: x or y of C/CL/CR/CT/CB/B may be a range a-b, filling a
      rectangle, e.g. C{0-12,0-6}.
      Variant: append #n to C/CL/CR/CT/CB/B (or C*/B*) to force atlas variant n.

    RASTER (-r)
      Every tile is 2x2 parts, so a WxH grid has (2W) x (2H) parts. Give them
      row by row, left to right (line breaks optional; separators between
      tokens optional: "C1C3" = "C1 C3"; '#' comments to end of line).
      Each part is a letter and a digit:
        C0          Commercial part on its own (a quarter of a block).
        C1..C4      Commercial part linked to its neighbour in the same tile by
                    a unit vector: C1=(1,0) right, C2=(0,-1) down, C3=(-1,0)
                    left, C4=(0,1) up. Valid blocks:
                      C1 C3          horizontal half (top or bottom row)
                      C2 / C4        vertical half (C2 above C4, left or right column)
                      C1 C2 / C4 C3  whole tile
        B0          Building part; B0 B0 / B0 B0 is a whole building tile,
                    fewer B0 are single parts.
        U0          Urban-forest part; a tile-aligned rectangle of U0 is one
                    forest (sizes 1x1, 1x2, 2x1, 2x2, 3x3 tiles). Neighbouring
                    U0 regions merge into one forest.
      Firebreaks and canals replace roads, so they are NOT parts and are not
      counted:
        F0 row      A row of 2W F0 (F0F0 per tile) between two tile rows, i.e.
                    right before part row 2, 4, ... 2H-2. Horizontal only.
        R0          Inside a part row, between the parts of two neighbouring
                    tiles (between part cols 1|2, 3|4, ...). R0R0 - one R0 in
                    each of a tile's two part rows - is one tile of canal;
                    consecutive tile rows join into one waterway. Vertical only.
      -g/-s/--border work as for -l (no @directives in raster input).

      Raster errors (exit 1) are all reported together; each names the token
      number (#n, counted from 1 over all tokens incl. F/R), the part row/col
      (0-based), the tile {x,y} and the part's corner, plus a fix:
      - part count (F/R excluded) differs from (2W)x(2H): where parts are
        missing or which tokens are extra;
      - unknown token, C digit > 4, or a digit other than 0 on U/B/F/R;
      - a C1-C4 vector pointing out of its tile, at a part that is not
        C1-C4, or parts that do not form one of the blocks above;
      - F not as a whole row at a road between tile rows, or a row with the
        wrong number of F0; R0 not on a road between tiles, or only one R0
        of a tile's R0R0;
      - a U0 region that is not a rectangle of whole tiles or has no sprite
        size; an F row or R0 run crossing a forest (along its edge is fine).

    VARIANTS (seed)
      Without #n, variant = (tileCount mod seed + order) mod candidates,
      where tileCount = W*H and order counts cells of the same pattern
      (C, CL, CR, CT, CB, B separately) in specification order, 0-based.
      Candidates: C=63, CL=12, CR=12, CT=20, CB=20, B=2. Use -v to see choices,
      and --list-variants to see what each #n looks like.

    ERRORS (exit code 1, message on stderr)
      - Any token that extends outside the grid.
      - Two tokens covering the same tile (or the same half).
      - An urban forest crossed by F or W (F/W only on its edge is allowed).
      - Unknown pattern, malformed coordinates, unsupported forest size,
        or a #n variant that does not exist.
      - Unknown directive, directive without a valid value, or the same
        directive twice. In a multi-line layout these
        messages start with "line N:".
      Usage errors (missing/invalid options, unreadable @file) exit with code 2.

    EXAMPLES
      tinytowngen -l "C*" -o town.png
      tinytowngen -g 13x7 -s 5 -o city.png \\
        -l "U3{0,0} U2{9,4} B{5,2} CL{6,2} CR{6,2}#3 F{3} W{4,4-6} C*"
      tinytowngen -g 6x4 -o small.png -l "C{0-5,0-1} W{3} U1x2{0,2} B*"
      tinytowngen -o town.png -l @town.txt     # town.txt:
                                               #   @grid 13x7 @seed 5
                                               #   # parks
                                               #   U3{0,0} U2{9,4}
                                               #   F{3}   # boulevard
                                               #   C*
      printf 'U2{0,0}\\nC*' | tinytowngen -o town.png -l @-
      tinytowngen -o small.png -l "@grid 4x3 @border U2{0,0} C*"
      tinytowngen -g 2x2 -o raster.png -r "C1C2 C0B0 C4C3 B0C0 F0F0F0F0 U0U0 R0 C2C2 U0U0 R0 C4C4"
      tinytowngen --list-variants C -o variants-C.png --scale 4
      tinytowngen --list-variants all -o variants.png --scale 4
    """

    /// Runs the CLI. Returns the process exit code.
    public static func run(_ args: [String]) -> Int32 {
        var opts: CLIOptions
        do {
            opts = try CLIOptions.parse(args)
            if let layout = opts.layout { opts.layout = try loadLayout(layout) }
            if let raster = opts.raster { opts.raster = try loadLayout(raster) }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 2
        }
        if opts.help {
            print(helpText)
            return 0
        }
        do {
            let atlas = try Atlas.loadEmbedded()
            if let kinds = opts.listVariants {
                let image = VariantSheet.render(kinds, atlas: atlas).scaled(by: opts.scale)
                try image.writePNG(to: URL(fileURLWithPath: opts.output!))
                let ranges = kinds.map { kind -> String in
                    let count = atlas.variantCount(for: kind) ?? 0
                    return "\(kind.orderKey) #0-#\(count - 1)"
                }
                print("wrote \(opts.output!) (\(image.width)x\(image.height) px, variants: \(ranges.joined(separator: ", ")))")
                return 0
            }
            let placements: [Placement], grid: GridSize, seed: Int, border: Bool
            if let raster = opts.raster {
                (grid, seed, border) = resolve(opts, LayoutSettings())
                placements = try RasterLayout.parse(raster, grid: grid, parkSizes: atlas.parkSizes)
            } else {
                let doc = try LayoutParser.parseDocument(opts.layout!)
                (grid, seed, border) = resolve(opts, doc.settings)
                placements = doc.placements
            }
            let plan = try Planner.plan(placements, grid: grid, seed: seed, atlas: atlas)
            if opts.verbose { FileHandle.standardError.write(Data(describe(plan).utf8)) }
            let image = Renderer.render(plan, atlas: atlas, border: border).scaled(by: opts.scale)
            try image.writePNG(to: URL(fileURLWithPath: opts.output!))
            print("wrote \(opts.output!) (\(image.width)x\(image.height) px, grid \(grid.width)x\(grid.height), seed \(seed)\(border ? ", border" : ""))")
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            if case TownError.usage = error { return 2 }
            return 1
        }
    }

    /// Command-line options win over @directives in the layout, which win over defaults.
    static func resolve(_ o: CLIOptions, _ s: LayoutSettings) -> (grid: GridSize, seed: Int, border: Bool) {
        (o.grid ?? s.grid ?? CLIOptions.defaultGrid, o.seed ?? s.seed ?? CLIOptions.defaultSeed, o.border || s.border)
    }

    /// Resolves `@path` / `@-` to the file's or stdin's contents; other values are the layout itself.
    /// A value containing whitespace is always an inline layout, so one that starts with a
    /// directive (`@grid 4x3 C*`) is not mistaken for a file name.
    static func loadLayout(_ arg: String, stdin: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }) throws -> String {
        guard arg.hasPrefix("@"), !arg.contains(where: \.isWhitespace) else { return arg }
        let path = String(arg.dropFirst())
        if path == "-" {
            guard let text = String(data: stdin(), encoding: .utf8) else {
                throw TownError.usage("layout from stdin is not valid UTF-8")
            }
            return text
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw TownError.usage("cannot read layout file '\(path)'")
        }
        return text
    }

    static func describe(_ plan: Plan) -> String {
        var s = ""
        for t in plan.tiles {
            var part = ""
            if case .commercialPart(let q) = t.kind { part = " (\(q.name))" }
            if case .buildingPart(let q) = t.kind { part = " (\(q.name))" }
            s += "\(t.kind.orderKey){\(t.x),\(t.y)}#\(t.variant)\(part)\n"
        }
        for p in plan.parks { s += "\(p.size){\(p.x),\(p.y)}\n" }
        for l in plan.lines {
            s += "\(l.kind == .firebreak ? "F" : "W"){\(l.index),\(l.span.lo)-\(l.span.hi)}\n"
        }
        return s
    }
}
