# tinytowngen

Swift Package (macOS 13+, no external dependencies). CLI that renders a grid-city aerial PNG from a layout string.

- Build/test: `swift build`, `swift test`. Run: `.build/debug/tinytowngen --help`.
- `Sources/TinyTownCore/EmbeddedResources.swift` is generated — never edit it; run `Scripts/embed-resources.sh` after changing `Resources/`.
- Pipeline: `LayoutParser` (string → `[Placement]`) → `Planner` (validation, seed/variant selection → `Plan`) → `Renderer` (`Plan` → `Bitmap`) → PNG via the pure-Swift `PNGEncoder`; the embedded atlas is read by the pure-Swift `PNGDecoder`. Sources must not import CoreGraphics/ImageIO (Linux support); tests may, only under `#if canImport(ImageIO)` as an independent reference (`ImageIOReference`).
- Layout grammar, errors and seed formula are documented in three places that must stay in sync: `CLI.helpText`, `README.md`, and tests (`candidateCountsMatchHelp`).
- Visually check rendering changes: render with `--scale 4` into the scratchpad and view the PNG.
- `GoldenImageTests` pins pixel hashes of representative renders. Any intended rendering change makes it fail with the new hash and a PNG path: view the PNG, and only if it looks right, paste the new hash into `cases`. Never update a hash without looking.
- Improvement backlog lives in `BACKLOG.md`; the `/nextStep` skill works through it.
