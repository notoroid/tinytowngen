import Foundation

public struct CLIOptions: Equatable {
    public var layout: String?
    public var output: String?
    public var grid = GridSize(width: 13, height: 7)
    public var seed = 1
    public var scale = 1
    public var verbose = false
    public var help = false

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
            case "-l", "--layout": o.layout = try value(arg, inline: inline)
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
            if o.layout == nil { throw TownError.usage("--layout is required (see --help)") }
            if o.output == nil { throw TownError.usage("--output is required (see --help)") }
        }
        return o
    }
}

public enum CLI {
    public static let helpText = """
    tinytowngen - render an aerial PNG of a grid city from a text layout

    USAGE
      tinytowngen -l <layout> -o <file.png> [-g WxH] [-s seed] [--scale n] [-v]

    OPTIONS
      -l, --layout <string>  (required) Placement string. See LAYOUT.
      -o, --output <path>    (required) Output PNG path.
      -g, --grid <WxH>       Grid size in tiles. Default: 13x7.
      -s, --seed <int>       Seed (>= 1) for picking C/CL/CR/CT/CB/B variants. Default: 1.
          --scale <int>      Integer nearest-neighbour upscale of the output (1-32). Default: 1.
      -v, --verbose          Print every resolved placement (and its variant) to stderr.
      -h, --help             Show this help.

    GEOMETRY
      Tiles are 19x19 px separated by 2 px roads (#777777). Tile {x,y} is
      0-based from the top-left; its pixel origin is (x*21, y*21).
      Image size = (W*21-2) x (H*21-2) px, e.g. 13x7 -> 271x145.
      Road lines are numbered 1..W-1 (vertical) and 1..H-1 (horizontal);
      road k lies between tile column/row k-1 and k.

    LAYOUT
      Tokens separated by spaces or ';'. Later tokens never overwrite earlier
      ones - any overlap is an error. Unspecified tiles are bare ground.

      C{x,y}        Commercial block, 1 tile.               (alias: C1{x,y})
      CL{x,y}       Commercial half: left  half of the tile (also CR right,
      CT{x,y}         CT top, CB bottom). CL+CR or CT+CB share one tile.
      B{x,y}        Building under construction, 1 tile.
      U<n>{x,y}     Urban forest n x n tiles, top-left at {x,y}. Covers the
      U<w>x<h>{x,y}   roads inside it. Sizes: U1, U2, U3, U1x2.
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

    VARIANTS (seed)
      Without #n, variant = (tileCount mod seed + order) mod candidates,
      where tileCount = W*H and order counts cells of the same pattern
      (C, CL, CR, CT, CB, B separately) in specification order, 0-based.
      Candidates: C=63, CL=12, CR=12, CT=20, CB=20, B=2. Use -v to see choices.

    ERRORS (exit code 1, message on stderr)
      - Any token that extends outside the grid.
      - Two tokens covering the same tile (or the same half).
      - An urban forest crossed by F or W (F/W only on its edge is allowed).
      - Unknown pattern, malformed coordinates, unsupported forest size,
        or a #n variant that does not exist.
      Usage errors (missing/invalid options) exit with code 2.

    EXAMPLES
      tinytowngen -l "C*" -o town.png
      tinytowngen -g 13x7 -s 5 -o city.png \\
        -l "U3{0,0} U2{9,4} B{5,2} CL{6,2} CR{6,2}#3 F{3} W{4,4-6} C*"
      tinytowngen -g 6x4 -o small.png -l "C{0-5,0-1} W{3} U1x2{0,2} B*"
    """

    /// Runs the CLI. Returns the process exit code.
    public static func run(_ args: [String]) -> Int32 {
        let opts: CLIOptions
        do {
            opts = try CLIOptions.parse(args)
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
            let placements = try LayoutParser.parse(opts.layout!)
            let plan = try Planner.plan(placements, grid: opts.grid, seed: opts.seed, atlas: atlas)
            if opts.verbose { FileHandle.standardError.write(Data(describe(plan).utf8)) }
            let image = Renderer.render(plan, atlas: atlas).scaled(by: opts.scale)
            try image.writePNG(to: URL(fileURLWithPath: opts.output!))
            print("wrote \(opts.output!) (\(image.width)x\(image.height) px, grid \(opts.grid.width)x\(opts.grid.height))")
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    static func describe(_ plan: Plan) -> String {
        var s = ""
        for t in plan.tiles { s += "\(t.kind.orderKey){\(t.x),\(t.y)}#\(t.variant)\n" }
        for p in plan.parks { s += "\(p.size){\(p.x),\(p.y)}\n" }
        for l in plan.lines {
            s += "\(l.kind == .firebreak ? "F" : "W"){\(l.index),\(l.span.lo)-\(l.span.hi)}\n"
        }
        return s
    }
}
