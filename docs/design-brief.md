# Design brief — Best Photo Picker GUI

A prompt for generating the visual design of the planned macOS app (ADR-0005). Paste the
block below into a design-capable Claude session. It describes **what the app does and
contains**; visual direction (palette, type, density) is deliberately left to the designer.
The output is a high-fidelity mockup that serves as a **visual spec hand-translated to
SwiftUI** — not shippable code.

Decisions behind this brief: `docs/adr/0005` (native app over the Python core),
`docs/adr/0006` (favourite is the human verdict), and the vocabulary in `CONTEXT.md`.

---

```
Design a desktop macOS application called **Best Photo Picker**.

Produce high-fidelity mockups of every screen and key state, framed as a
native macOS desktop app (desktop window chrome and information density —
not a website, not mobile). You own all visual direction: palette,
typography, spacing, components, overall art style. Make it distinctive and
intentional, appropriate to a professional photography tool. The constraints
below are about WHAT the app does and contains, not how it should look.

## What the app is

Photographers who shoot in continuous "burst" mode (e.g. 20 frames/second)
come home with thousands of near-identical frames and must cull them down by
hand. Best Photo Picker uses on-device AI to do the first pass: it groups the
frames into bursts, recommends the best frame of each burst, and explains why
— so the human can fly through, pick their favourites, and export them.

Core promise, reinforced throughout the UI: it is **non-destructive**. It
never moves or deletes the user's original photos. It only reads them and
copies favourites out on request.

## Domain vocabulary (use these exact terms in the UI)

- **Burst** — a run of frames shot rapidly, capturing one moment. The app
  groups photos into bursts automatically; bursts vary in length.
- **AI mark** (per photo, read-only — the AI's opinion, shown as a badge and
  used to sort): **Keeper** = the AI's recommended best frame of the burst;
  **Maybe** = the AI is unsure; **Rejected** = the AI thinks it's weak
  (blurry, eyes closed). These are *suggestions*. The AI never has the final
  word.
- **Scores** the AI shows per photo: **Sharpness** (how crisp the subject is —
  the main quality axis), **Eyes-open** (for faces), **Faces** (count),
  **Exposure** (a warning flag when highlights are blown / shadows crushed),
  and a short plain-English **Reason** ("eyes closed", "below the burst's
  sharpness peak", etc.).
- **Favourite** — the USER's pick (a star). This is the only thing the user
  sets. The user can favourite any photo regardless of its AI mark — including
  rescuing one the AI rejected.

## Screens & features to design

1. **Import / start.** Choose a source folder of photos. Choose a grouping
   strategy: *Time* (split bursts by the gap between shots) or *Similarity*
   (group near-duplicate frames by visual likeness). Start.

2. **Scoring progress.** The AI pass runs and can take a while over thousands
   of photos. Show live progress: count done / total, the photo being
   processed, elapsed/remaining, and a cancel control.

3. **Review — the heart of the app.** Photos grouped by burst. Two layered
   views:
   - **Grid overview** — bursts as sections, thumbnails carrying their AI mark
     badge + key scores, the AI's keeper visually distinguished.
   - **Loupe** — one large photo plus a filmstrip of the rest of its burst;
     keyboard-driven for fast culling (move between frames and bursts with the
     keyboard, one key to favourite, zoom to 100% to verify sharpness);
     side-by-side compare of two frames.
   - Favourite toggle available everywhere, with a running favourites count.
   - Filter / sort: by AI mark, by favourite, by burst.
   Design the empty state, the loading state, and a "no faces found / model
   unavailable" state.

4. **Export favourites.** Choose a destination folder; the app copies the
   starred photos there as real files (originals untouched). Show a summary
   of what will be exported.

5. **Settings.** Tuning that currently lives in a config file. Surface the
   everyday knobs plainly (grouping strategy and its parameters, how many
   keepers per burst); tuck the advanced ML thresholds (face-detection
   confidence, eye-open threshold, exposure blown/crushed limits, rejection
   sharpness ratio) behind an "Advanced" area. Settings persist.

## Cross-cutting requirements

- The photos are the hero — UI chrome should recede so colour and exposure
  read true.
- Must feel fast and stay legible over many thousands of frames.
- Keyboard-forward: a power user should be able to cull a whole shoot without
  the mouse.
- Reinforce the non-destructive promise where it matters (import, export).
```
