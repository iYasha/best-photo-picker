# Auto-update via Sparkle over GitHub Releases

The native macOS app (ADR-0005) ships as a self-contained `.app` with an embedded Python
core — there is no App Store, no Sparkle-less "download the new DMG yourself" story that a
non-technical photographer would follow. So the app needs to update itself. We adopt
**Sparkle 2** (the de-facto macOS updater) pointed at a **GitHub Releases** feed, mirroring
the sibling `github-pr-bar` app's setup verbatim so there is one update pattern to maintain
across both projects.

**How it hangs together.** `score`/`review` are untouched; this is app-shell plumbing only.
`AppUpdater` (`macos/BestPhotoPicker/Core/AppUpdater.swift`) is a thin singleton over
`SPUStandardUpdaterController`. It starts the updater **only when the running bundle carries an
`SUFeedURL`** — always true for the packaged `.app`, so a feedless/bare build stays dormant and
never errors on a missing feed. The app menu gains a standard **"Check for Updates…"** item
(under About) for the manual path; `SUEnableAutomaticChecks` + a daily
`SUScheduledCheckInterval` cover the passive path. The feed is `appcast.xml` at the **repo
root**, served raw from GitHub; `scripts/release.sh` builds a version-stamped bundle, zips it,
EdDSA-signs the zip, publishes a `gh release`, then regenerates and pushes that appcast — older
clients update to its single latest `<item>`.

**Why this is ADR-worthy — three trade-offs that will surprise a future reader:**

- **Ad-hoc signed, not notarized.** The bundle is ad-hoc signed (no Developer ID), same as
  pr-radar. Sparkle's trust comes from the **EdDSA signature on the appcast enclosure**, not
  Gatekeeper, so in-app updates verify and install fine. The cost: the *first manual* install of
  a download is quarantined and needs `xattr -dr com.apple.quarantine` (or a right-click-open).
  Proper Developer ID + notarization is deliberately deferred to its own task — it does not block
  the updater working.

- **Hardened runtime is effectively stripped at package time.** The Xcode target builds with
  `ENABLE_HARDENED_RUNTIME = YES`, but `scripts/bundle-app.sh` re-signs the whole bundle ad-hoc
  with `codesign --force --deep --sign -` and **no `--options runtime`**, which drops the runtime
  flag. This is intentional: it sidesteps library-validation failures from the embedded
  third-party Python dylibs (cv2/mediapipe) and matches pr-radar. Sparkle's nested XPC services
  (`Downloader.xpc`, `Installer.xpc`) are covered by the `--deep` re-sign.

- **The EdDSA signing key is shared across apps.** Sparkle's `generate_keys` stores one private
  key in the login keychain; both pr-radar and Best Photo Picker sign against it, so they carry
  the **same `SUPublicEDKey`** (`o5pi0q…` in `Info.plist`). One key to guard for all personal
  apps, rather than per-app keypairs. The private key lives only in the keychain — never in the
  repo.

## Consequences

- **Versioning moved to build settings.** `Info.plist` now reads `CFBundleShortVersionString` /
  `CFBundleVersion` from `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`. `release.sh
  <version>` exports both, `bundle-app.sh` forwards them to `xcodebuild`, so a release is stamped
  from one CLI arg — no hand-editing the plist. A plain `make` build keeps the pbxproj defaults
  (currently `1.0` / `1`).

- **The feed does not exist until the first release.** `release.sh 1.1.0` creates and pushes
  `appcast.xml`. Before that, a running app's scheduled check just 404s silently — harmless.

- **Sparkle is an SPM dependency in the Xcode project** (`from: "2.6.0"`, resolved 2.9.3),
  linked into the Frameworks phase; Xcode auto-embeds `Sparkle.framework` into the bundle. The
  target already had `@executable_path/../Frameworks` on `LD_RUNPATH_SEARCH_PATHS`. First build
  needs network to resolve the package; `release.sh` finds Sparkle's `sign_update` tool under the
  resolved `DerivedData/SourcePackages/artifacts`.

- **Release in one command:** `macos/scripts/release.sh <version>`. Prereqs: `gh` authenticated,
  the EdDSA private key in the login keychain.
