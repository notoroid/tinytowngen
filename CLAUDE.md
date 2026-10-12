# tinytowngen

Swift Package (macOS 13+, no external dependencies). CLI that renders a grid-city aerial PNG from a layout string.

- Build/test: `swift build`, `swift test`. Run: `.build/debug/tinytowngen --help`.
- `Sources/TinyTownCore/EmbeddedResources.swift` is generated — never edit it; run `Scripts/embed-resources.sh` after changing `Resources/`.
- Two inputs: `-l` (`LayoutParser`, token grammar) and `-r` (`RasterLayout`, 2x2 parts per tile streamed in raster order); both produce `[Placement]`.
- Pipeline: `LayoutParser` (string → `[Placement]`) → `Planner` (validation, seed/variant selection → `Plan`) → `Renderer` (`Plan` → `Bitmap`) → PNG via the pure-Swift `PNGEncoder`; the embedded atlas is read by the pure-Swift `PNGDecoder`. Sources must not import CoreGraphics/ImageIO (Linux support); tests may, only under `#if canImport(ImageIO)` as an independent reference (`ImageIOReference`).
- Layout grammar, errors and seed formula are documented in three places that must stay in sync: `CLI.helpText`, `README.md`, and tests (`candidateCountsMatchHelp`).
- Visually check rendering changes: render with `--scale 4` into the scratchpad and view the PNG.
- `GoldenImageTests` pins pixel hashes of representative renders; `Tests/TinyTownCoreTests/Golden/*.png` hold the expected images for diffing. A rendering change fails with the new hash, the changed-pixel count/bounds, and actual / expected / diff PNG paths (diff: changed pixels red). View them; only if the change is intended, run `UPDATE_GOLDEN=1 swift test` (rewrites Golden/*.png), paste the new hash into `cases`, and run `swift test` again. Never update without looking.
- Improvement backlog lives in `BACKLOG.md`; the `/nextStep` skill works through it.
