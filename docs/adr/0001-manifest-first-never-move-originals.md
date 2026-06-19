# Manifest-first: scoring writes a manifest and never moves originals

The 2K JPEGs (~40GB) live on a NAS and the user shoots for keeps, so losing or
duplicating photos is the expensive failure. The original plan copied winners into
`good/` and `review/` folders. Instead, scoring writes a single `manifest.csv` — one row
per photo (burst, subject found?, sharpness, eyes gate, exposure flag, bin, reason) — and
moves nothing; turning the manifest into something browsable is a separate, on-demand
`review` phase.

Why: it decouples slow scoring (run once over 40GB) from fast, re-runnable sorting; keeps
originals untouched by construction; and lets the user hand-edit verdicts in the manifest
before anything is staged.

## Consequences

A manifest is not browsable on its own — the `review` phase is required to actually look
at photos. That phase is deliberately cheap and repeatable.
