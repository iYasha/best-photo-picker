# Best Photo Picker

Burst-aware JPEG culler for big shoots. On-device AI groups near-identical frames, recommends
the best of each burst, and explains why — so you cull thousands of photos fast instead of by
hand. **Non-destructive**: it never moves or deletes your originals (see [`docs/adr/0001`](docs/adr/0001-manifest-first-never-move-originals.md)).

A monorepo with two codebases under shared docs:

| Path | What |
|---|---|
| [`core/`](core/) | The Python engine + `bestphoto` CLI — all grouping, detection, scoring. Runs anywhere; the single source of truth. Full docs: [`core/README.md`](core/README.md). |
| [`macos/`](macos/) | A native SwiftUI app that drives the core (planned; [`docs/adr/0005`](docs/adr/0005-native-macos-app-over-python-core.md)). |
| [`docs/`](docs/) | Decisions ([`adr/`](docs/adr)) and the GUI [`design-brief.md`](docs/design-brief.md). |
| [`CONTEXT.md`](CONTEXT.md) | Domain vocabulary — the source of truth for terms. |

## Quick start (CLI)

Uses [uv](https://docs.astral.sh/uv/). It's a workspace, so commands run from the repo root:

```bash
uv sync --extra faces                              # deps incl. mediapipe (face/eye detection)
uv run bestphoto score <photos> -m manifest.csv    # score into a manifest (moves nothing)
uv run bestphoto review <photos> -m manifest.csv -o ~/review   # stage keepers as symlinks
uv run bestphoto contact <photos> -m manifest.csv -o sheet.html
```

Full CLI usage, tuning, and known limits: [`core/README.md`](core/README.md).

## Layout note

The Python package lives in `core/` (PyPI: `best-photo-picker`); `uv.lock` is the single
workspace lock at the root. Tests run from `core/`: `uv run --directory core pytest`.
See [`docs/adr/0007`](docs/adr/0007-monorepo-core-macos-layout.md).
