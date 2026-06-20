# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

Monorepo (uv workspace; see `docs/adr/0007`). The Python engine + CLI live in `core/`
(package `best-photo-picker`), the planned SwiftUI app in `macos/` (`docs/adr/0005`), shared
decisions in `docs/adr/`. `uv.lock` is the single workspace lock at the repo root. Bare module
names in this file (`pipeline.py`, …) resolve under `core/bestphoto/`.

## Commands

Uses [uv](https://docs.astral.sh/uv/). Python 3.11+. The CLI runs from the repo root (the
workspace resolves the `bestphoto` script):

```bash
uv sync --extra faces        # install deps incl. mediapipe (omit --extra faces = no face/eye detection)
uv run bestphoto score  <photos> -m manifest.csv [--group similarity] [--keep N] [-v]
uv run bestphoto review <photos> -m manifest.csv -o <out>   # symlink keepers/maybe[/rejected]
uv run bestphoto contact <photos> -m manifest.csv -o sheet.html   # HTML contact sheet to evaluate
```

Tests live in `core/` (config in `core/pyproject.toml`), so run them with `--directory core`:
```bash
uv run --directory core pytest                # default: fast deterministic logic units only (~0.04s)
uv run --directory core pytest -m slow        # golden tests: re-score real photos with ML models (~33s)
uv run --directory core pytest -m ""          # everything
uv run --directory core pytest tests/test_logic.py::test_portrait_eyes_closed_rejected_even_if_sharper  # single test
BPP_REGEN=1 uv run --directory core pytest -m slow   # regenerate golden snapshots after an INTENTIONAL behavior change
```

Golden tests need a real photo set: `BPP_TEST_PHOTOS=/path/to/photos` (defaults to `~/Desktop/test_photos`); they skip if absent.

## Architecture

A non-destructive burst/near-duplicate photo culler. **It never moves or deletes originals** — `score` only writes a CSV manifest; physical sorting (`review`) is symlink-only and opt-in. This invariant is the point of the tool (see `docs/adr/0001`), do not break it.

**Two phases, manifest is the contract between them:**
- `score` (`pipeline.py`) → `manifest.csv` (one row per photo: group id, faces, eye_score, sharpness, exposure, bin, reason). Moves nothing.
- `review` (`review.py`) / `contact` (`contact.py`) → consume the manifest. You can hand-edit the manifest before either.

**`score` flow:** scan → group → per-group detect/measure → gate+rank bin → manifest. The per-frame measure (decode+detect+exposure+sharpness) fans out over a **process pool by default** (`cfg.workers`, env `BPP_WORKERS`; 0=auto `min(cpu,8)`, 1=serial). Processes, not threads, because the detection model singletons segfault when shared across threads (`docs/adr/0009`). Parallel and serial paths score **identically** (golden-pinned); the pool is bypassed for injected detectors (tests), `workers==1`, or tiny sets. Two interchangeable grouping strategies (`cfg.group_method`, `--group`):
- **time** (`group_into_bursts`): split on capture-time gap. Single decode per photo; sharpness measured on a **per-burst locked region** (`consensus_box`) so a blurry frame can't dodge the detector. Unchanged legacy path.
- **similarity** (`group_by_similarity` + `phash.py`): cluster near-duplicate frames by perceptual-hash distance, camera-agnostic. Sharpness measured on each frame's own subject box. See `docs/adr/0004`.

**Scoring model — gate + rank (`binning.py`), not a blended score:**
- eyes-open is a **hard gate** for a single-face (portrait) group; for groups (≥2 faces) it becomes a size-weighted *rank* term, never a hard reject.
- exposure is a soft **flag**, never a reject.
- sharpness (Laplacian variance, `sharpness.py`) is the ranking axis.
- **Bias to `maybe`:** `rejected` is reserved for high-confidence trash (closed-eye portrait, or far below the group's sharpness peak); anything uncertain → `maybe`. Don't make rejection eager.

**Detection (`detect.py`) — two models, each for what it's good at (`docs/adr/0003`):**
- **YuNet** (`cv2.FaceDetectorYN`) finds face boxes — robust on scene photos where MediaPipe's selfie-tuned detector drops faces. `foreground_ratio` keeps only faces near the largest (drops background bystanders).
- **MediaPipe FaceLandmarker** (Tasks API — *not* the removed `mp.solutions`) runs per face crop for eye-open via `eyeBlink` blendshapes.
- Both model bundles auto-download to `~/.cache/best-photo-picker/` (override: `BPP_FACE_DETECTOR`, `BPP_FACE_MODEL`). Missing detector → no faces (sharpness+exposure only); missing landmarker → faces but no eye gate.

**Resumable cache:** `score` writes per-photo measurements to `.bpp-cache.csv`, keyed by `(rel, mtime, size)` and tagged by grouping signature (gap-seconds for time, `"sim"` for similarity) so both modes coexist in one file. Re-runs skip unchanged photos. `--no-resume` forces rescore.

## Conventions

- **Domain language lives in `CONTEXT.md`** (glossary: Keeper, Favourite, Burst, Single, Subject, Sharpness, Gate, Flag, Maybe, Rejected, Manifest, Review). Use these terms in code and messages; it is the source of truth for vocabulary. Note `Keeper` is the *AI's* recommendation and `Favourite` is the *human's* pick (`docs/adr/0006`).
- **Decisions live in `docs/adr/`** — read them before changing grouping, output, or detection; they record *why*. Add an ADR for hard-to-reverse, surprising, trade-off decisions.
- All tuning is in a TOML config (`core/config.example.toml` → `config.toml`, passed with `-c`); defaults live in `config.py` (`Config` dataclass). Thresholds are conservative by design.
- `Frame`/`Burst` (`bursts.py`) are the core data structures; `Burst` is the generic group container for both strategies.
- Logging is structlog (`log.py`); `-v` enables DEBUG (per-frame/per-group/per-bin detail).

## Before committing a refactor

Behavior is pinned by golden characterization tests. A pure refactor must keep `uv run --directory core pytest -m slow` **green** (asserts each photo's bin/face-count/grouping is unchanged vs `core/tests/golden/`). Red golden = behavior changed.
