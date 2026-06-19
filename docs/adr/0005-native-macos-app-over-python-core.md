# A native macOS GUI wraps the Python core; the core stays the CLI

*Planned — no GUI code exists yet; the shipping product is still the CLI. This records the
product-form decision reached before building.*

To open-source the tool and make it usable without a terminal, we weighed three product
forms: a **native macOS desktop app**, a **self-hosted web app** shipped as a Docker image
(the cross-platform option), and **CLI-only** keeping the static `contact.py` sheet. Decision:
build a native macOS app (SwiftUI) that **drives the existing Python core as a subprocess**.
Python stays the single source of grouping/detection/scoring logic; the GUI never
reimplements it.

Why native despite it being Mac-only: the primary user is on a Mac and wants a real desktop
app, not a localhost server; and the heavy ML (mediapipe / OpenCV / YuNet) is the value and
stays in Python regardless of the UI, so a Swift rewrite of detection was never on the table.
The cross-platform reach a web/Docker build would have given is deliberately traded away for
v1.

The app drives the **full loop** — import a folder → run `score` with live progress → review
in a burst gallery → export — rather than being a viewer over a manifest the user produced by
hand. The `manifest.csv` stays the contract underneath (ADR-0001 holds): the GUI *drives* the
pipeline instead of the user typing commands, it does not replace the manifest.

## Consequences

- **Python stays the core.** No detection/scoring logic in Swift. mediapipe/OpenCV/YuNet run
  as a normal Python install invoked by the app; `detect.py` and the rest are unchanged.
- **The app spawns the CLI as a subprocess** and reads back the manifest. The two-phase
  score→manifest→review model and the never-move-originals invariant (ADR-0001) are preserved.
- **Mac-only.** Windows/Linux users get the CLI only. Accepted.
- **Tauri was rejected** even though it would have kept the app cross-platform *and* let a
  Claude-generated HTML design be the literal shipping UI (webview), still spawning the normal
  Python. SwiftUI was chosen for a true-native feel. Consequence: a Claude-designed mockup is
  a **visual spec hand-translated to SwiftUI**, not shippable code (see `docs/design-brief.md`).
- **Unsigned / un-notarized build accepted.** Fine for the author on their own Mac (no
  quarantine on a locally built app). Anyone who *downloads* it hits Gatekeeper and must clear
  quarantine (`xattr -dr com.apple.quarantine BestPhoto.app`) or build their own. Signing +
  notarization ($99/yr Apple account, recursive deep-signing of native dylibs) is deferred.
- **If the core is ever frozen into the `.app`** (PyInstaller) to remove the Python
  dependency, bundling mediapipe is the main tax (`--collect-all mediapipe`, signing nested
  `.so`/`.dylib`, arm64-only wheels, ~300MB binary). Deferred — for now the app assumes a
  present Python core. Note the Tasks API (`mediapipe.tasks`) avoids the legacy
  `mp.solutions` `modules/*.binarypb` copy problem.
