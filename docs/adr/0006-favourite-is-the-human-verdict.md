# Favourite is the human's verdict; the AI's bins are read-only recommendations

*Planned — applies to the GUI (ADR-0005), not yet built. The CLI has no favourites.*

In the CLI the bin (`keeper`/`maybe`/`rejected`) is the algorithm's output and the user
"overrides" it by hand-editing the manifest. For the GUI we split that into **two axes with
two owners**:

- **AI mark** — the bin (`keeper`/`maybe`/`rejected`). The AI's *opinion*, read-only in the
  UI, shown as a badge and used to sort. `keeper` is the AI's recommended best frame of a
  burst; it is a recommendation, not a verdict.
- **Favourite** — a star. The user's *decision*, and the only thing the user sets. The user
  can favourite any photo regardless of its AI mark, including rescuing one the AI rejected.

AI proposes, human disposes. One clear verb for the user (favourite / unfavourite) culls
thousands of frames faster than reclassifying three bins by hand, and it stops "keeper" from
meaning both the AI's pick and the human's pick. This **redefines Keeper** in `CONTEXT.md`:
it is the AI's recommended pick, not "the photo the user actually wants" — that is now the
**Favourite**.

## Consequences

- **`CONTEXT.md` updated**: Keeper redefined as the AI's recommendation; **Favourite** added
  as the human's pick (orthogonal axis).
- **AI marks are not editable in the GUI** (read-only). Manual bin re-classification is out of
  scope for v1; favourite is the sole user action. If it is ever wanted, that is a separate
  decision.
- **Two distinct exports, extending ADR-0002:**
  - *Review staging* (existing `review`) stages whole bins as **symlinks** — a huge set, just
    for inspection; don't copy ~40GB.
  - *Deliver favourites* (new) **copies** the starred photos as real files into a chosen
    folder — a small final set and the actual handoff, so real files (not dangling symlinks)
    are correct.
  - Both are non-destructive; originals never move (ADR-0001).
- **The manifest gains a `favourite` column** (the human's verdict) alongside the AI's `bin`.
  The CLI does not write it; the GUI does.
