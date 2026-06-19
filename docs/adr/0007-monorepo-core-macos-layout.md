# One repo, two codebases: `core/` (Python) + `macos/` (Swift) as a uv workspace

The project is one product with two codebases: the Python engine/CLI that holds all the
grouping/detection/scoring logic, and a planned native macOS app (ADR-0005) that drives it.
We keep them in a single repository so the shared docs (ADRs, `CONTEXT.md`, the design brief)
and the cross-cutting decisions live in one place, and changes to the contract between the two
(ADR-0008) are atomic. Layout: peer top-level dirs `core/` and `macos/`, shared `docs/` at the
root, and a uv workspace root so the Python tooling still runs from the top.

Why `core/` + `macos/` (not Python-at-root with a bolt-on `macos/`, and not `apps/macos/`):
ADR-0005 frames Python as *the core* and macOS as *one frontend* (Linux/Windows get the CLI).
Peer directories make that legible and leave room for a second frontend without another
reshuffle. The `apps/` nesting was dropped as premature — there is one app; add the layer only
if a second appears.

Why a uv workspace: a virtual root `pyproject.toml` with `members = ["core"]` keeps a single
`uv.lock` at the root and lets `uv run bestphoto …` work from the repo top, so moving the
package into `core/` costs no day-to-day CLI ergonomics.

## Consequences

- The Python package lives at `core/bestphoto/`; its packaging (`core/pyproject.toml`, PyPI
  `best-photo-picker`) and tests (`core/tests/`) travel with it. `uv.lock` stays at the
  workspace root.
- `uv run bestphoto …` runs from the repo root (the workspace resolves the script). Tests need
  the config in `core/`, so run them with `uv run --directory core pytest`.
- The repo `README.md` is a monorepo overview; the CLI/package README is `core/README.md`
  (what `core/pyproject.toml`'s `readme` points at).
- `macos/` is an empty placeholder until the app is scaffolded; it is **not** a uv member
  (built with Xcode, not installed into the Python env).
- Bare module names in earlier ADRs and `CLAUDE.md` (`pipeline.py`, `binning.py`, …) now
  resolve under `core/bestphoto/`.
