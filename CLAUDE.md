# tinytowngen

Swift Package (macOS 13+, no external dependencies). CLI that renders a grid-city aerial PNG from a layout string.

- Build/test: `swift build`, `swift test`. Run: `.build/debug/tinytowngen --help`.
- `Sources/TinyTownCore/EmbeddedResources.swift` is generated — never edit it; run `Scripts/embed-resources.sh` after changing `Resources/`.
- Pipeline: `LayoutParser` (string → `[Placement]`) → `Planner` (validation, seed/variant selection → `Plan`) → `Renderer` (`Plan` → `Bitmap`) → PNG via ImageIO.
- Layout grammar, errors and seed formula are documented in three places that must stay in sync: `CLI.helpText`, `README.md`, and tests (`candidateCountsMatchHelp`).
- Visually check rendering changes: render with `--scale 4` into the scratchpad and view the PNG.
- Improvement backlog lives in `BACKLOG.md`; the `/nextStep` skill works through it.
