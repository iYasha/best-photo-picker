# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Uses [uv](https://docs.astral.sh/uv/). Python 3.11+.

```bash
uv sync --extra faces        # install deps incl. mediapipe (omit --extra faces = no face/eye detection)
uv run bestphoto score  <photos> -m manifest.csv [--group similarity] [--keep N] [-v]
uv run bestphoto review <photos> -m manifest.csv -o <out>   # symlink keepers/maybe[/rejected]
uv run bestphoto contact <photos> -m manifest.csv -o sheet.html   # HTML contact sheet to evaluate
```

Tests (split fast/slow — see `[tool.pytest.ini_options]`):
```bash
uv run pytest                # default: fast deterministic logic units only (~0.04s)
uv run pytest -m slow        # golden tests: re-score real photos with ML models (~33s)
uv run pytest -m ""          # everything
uv run pytest tests/test_logic.py::test_portrait_eyes_closed_rejected_even_if_sharper  # single test
BPP_REGEN=1 uv run pytest -m slow   # regenerate golden snapshots after an INTENTIONAL behavior change
```

Golden tests need a real photo set: `BPP_TEST_PHOTOS=/path/to/photos` (defaults to `~/Desktop/test_photos`); they skip if absent.

## Architecture

A non-destructive burst/near-duplicate photo culler. **It never moves or deletes originals** — `score` only writes a CSV manifest; physical sorting (`review`) is symlink-only and opt-in. This invariant is the point of the tool (see `docs/adr/0001`), do not break it.

**Two phases, manifest is the contract between them:**
- `score` (`pipeline.py`) → `manifest.csv` (one row per photo: group id, faces, eye_score, sharpness, exposure, bin, reason). Moves nothing.
- `review` (`review.py`) / `contact` (`contact.py`) → consume the manifest. You can hand-edit the manifest before either.

**`score` flow:** scan → group → per-group detect/measure → gate+rank bin → manifest. Two interchangeable grouping strategies (`cfg.group_method`, `--group`):
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

- **Domain language lives in `CONTEXT.md`** (glossary: Keeper, Burst, Single, Subject, Sharpness, Gate, Flag, Maybe, Rejected, Manifest, Review). Use these terms in code and messages; it is the source of truth for vocabulary.
- **Decisions live in `docs/adr/`** — read them before changing grouping, output, or detection; they record *why*. Add an ADR for hard-to-reverse, surprising, trade-off decisions.
- All tuning is in a TOML config (`config.example.toml` → `config.toml`, passed with `-c`); defaults live in `config.py` (`Config` dataclass). Thresholds are conservative by design.
- `Frame`/`Burst` (`bursts.py`) are the core data structures; `Burst` is the generic group container for both strategies.
- Logging is structlog (`log.py`); `-v` enables DEBUG (per-frame/per-group/per-bin detail).

## Before committing a refactor

Behavior is pinned by golden characterization tests. A pure refactor must keep `uv run pytest -m slow` **green** (asserts each photo's bin/face-count/grouping is unchanged vs `tests/golden/`). Red golden = behavior changed.
