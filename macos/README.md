# Best Photo Picker — macOS app

Planned native SwiftUI desktop app. See
[`../docs/adr/0005`](../docs/adr/0005-native-macos-app-over-python-core.md) for why native,
and [`../docs/design-brief.md`](../docs/design-brief.md) for the screens.

It drives the Python core in [`../core`](../core) — spawning the `bestphoto` CLI as a
subprocess and consuming its JSON output (the contract, [`../docs/adr/0008`](../docs/adr/0008-cli-json-contract-for-the-app.md)) — and never reimplements detection or scoring in Swift.
The core stays the single source of truth; this is one frontend.

## Status

Empty placeholder. The Xcode project lands here when the app is scaffolded.
