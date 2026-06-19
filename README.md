# Best Photo Picker

Burst-aware JPEG culler for big shoots (built around a Nikon ZR firing 20fps bursts onto a
NAS). It scores every photo into a **manifest**, then stages the keepers as **symlinks** for
you to review. It **never moves or deletes an original** — see
[`docs/adr/0001`](docs/adr/0001-manifest-first-never-move-originals.md).

The domain language lives in [`CONTEXT.md`](CONTEXT.md); the why-decisions in
[`docs/adr/`](docs/adr).

## How it works

```
score  →  manifest.csv     slow, run once (on the Mac), moves nothing
review →  symlink folder    fast, re-runnable, stages keeper/maybe/rejected bins
```

Grouping is selectable (`--group` / `[group] method`):
- **time** (default) — bursts by capture-time gap; cheapest, good for one camera/clean gaps.
- **similarity** — clusters near-duplicate frames by perceptual hash; camera-agnostic, splits
  a pan mid-hold and merges a recompose pause. See `docs/adr/0004`.

Per photo, `score`:
1. reads EXIF capture time (sub-second when present), honoring the orientation tag;
2. groups frames — by time gap, or by perceptual-hash similarity (a lone frame is a **single**);
3. finds the **subject** — face (MediaPipe) → centre → whole frame — and **locks one region
   per burst** so every frame is scored on the same pixels;
4. applies **gate + rank**: eyes-closed gates a portrait (size-weighted across faces for
   groups), bad exposure is a soft flag, and **sharpness** (Laplacian variance on the locked
   region, full-res) ranks the survivors;
5. assigns a bin — top-1 per burst → **keeper**, runners-up → **maybe**, high-confidence
   trash → **rejected**. When unsure it picks `maybe`, never `rejected`.

## Install

Uses [uv](https://docs.astral.sh/uv/).

```bash
uv sync --extra faces   # with face/eye detection (recommended)
uv sync                 # sharpness + exposure only (no mediapipe)
```

`opencv-python`, `Pillow`, `numpy` are core. `mediapipe` lives in the optional `faces` extra —
without it there's no face/eye detection (eye gate disabled); the tool still runs.

## Usage

```bash
# 1. score the NAS folder into a manifest (nothing is moved)
uv run bestphoto score /Volumes/photo/2026-06-19 -m manifest.csv -c config.toml

#    grouping strategy: time bursts (default) or content near-duplicate clustering
uv run bestphoto score /Volumes/photo/2026-06-19 --group similarity

# 2. eyeball / hand-edit manifest.csv if you like, then stage symlinks to review
uv run bestphoto review /Volumes/photo/2026-06-19 -m manifest.csv -o ~/review

#    stage rejects too, or copy instead of symlink:
uv run bestphoto review /Volumes/photo/2026-06-19 --bins keeper maybe rejected
uv run bestphoto review /Volumes/photo/2026-06-19 --copy

# 3. (to evaluate) build a self-contained HTML contact sheet: photos grouped by burst,
#    keeper highlighted, each frame labeled with bin + reason + scores
uv run bestphoto contact /Volumes/photo/2026-06-19 -m manifest.csv -o sheet.html
```

`score` is **resumable**: it caches per-photo measurements in `.bpp-cache.csv` (keyed by
path+mtime+size+gap), so a re-run skips unchanged files. `--no-resume` forces a full rescore.

Add `-v` / `--verbose` to either command for debug logging (structlog) — per-frame
measurements, burst regions, and per-bin decisions:

```bash
uv run bestphoto score /Volumes/photo/<shoot> -v
```

Staged layout:
```
~/review/keepers/b0_DSC0123.JPG          # symlink, one per burst
~/review/maybe/b0/DSC0124.JPG            # runners-up, grouped by burst
~/review/rejected/eyes-closed_DSC0125.JPG
```

## Tuning

Copy `config.example.toml` → `config.toml`, edit, pass with `-c`. Defaults are conservative
and bias toward `maybe`. The manifest records raw sharpness / eye scores / exposure fractions
so you can recalibrate after one real shoot.

## Before trusting sub-second grouping

EXIF `DateTimeOriginal` is 1-second resolution; at 20fps a whole burst shares one second.
Grouping only needs the *gap between* bursts (≥2s, visible at 1s resolution), so it works
regardless. Sub-second (`SubSecTimeOriginal`) just refines within-burst ordering. Confirm
your ZR writes it:

```bash
exiftool -SubSecTimeOriginal -DateTimeOriginal DSC0001.JPG
```

If absent, frames fall back to filename order within a burst.

## Known limits (v1)

- **Symlinks dangle** if the NAS share is unmounted/renamed after `review`
  ([`docs/adr/0002`](docs/adr/0002-score-on-mac-stage-as-symlinks.md)). Keep originals put.
- **Locked region assumes the subject barely moves** within a burst (true at 20fps/<1s). Fast
  subjects crossing the frame need per-frame tracking — region selection is a pluggable step
  left for v2.
- **No framing/composition scoring** — out of scope.
- Large bursts hold one full-res grayscale frame each in memory while scoring.
