# The CLI's JSON output is the app's contract; the CSV manifest stays human-editable

*Planned — not yet implemented. The app (ADR-0005) is the only intended consumer.*

The macOS app drives the Python core as a subprocess (ADR-0005) and needs a stable,
machine-readable interface. The existing `manifest.csv` is shaped for a human to read and
hand-edit (ADR-0001); parsing it from Swift and tracking its schema drift would be brittle.
Decision: add a machine output to the CLI — `bestphoto score --json` for the final result, and
JSON-lines progress for the scoring screen — and treat that JSON as **the contract** the Swift
bridge consumes. The CSV manifest stays the human-editable artifact on disk; JSON is a view for
the program.

Why: separate the human format (CSV — hand-editable, ADR-0001) from the program format (JSON —
stable, versioned). The app never screen-scrapes the CSV, and the CSV never has to turn rigid
for the app's sake.

## Consequences

- New CLI surface in `core` (`--json`, JSON-lines progress), documented and versioned as an
  API — not just incidental stdout.
- The `favourite` field (ADR-0006) appears in both the CSV manifest and the JSON.
- The Swift `CoreBridge` reads JSON only; the human still opens/edits the CSV when they want to.
