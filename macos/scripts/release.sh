#!/usr/bin/env bash
# Cut a Best Photo Picker release: build the self-contained .app, EdDSA-sign it
# for Sparkle, publish a GitHub release with the zipped app, and update the
# appcast feed so already-installed copies auto-update.
#
#   macos/scripts/release.sh 1.1.0
#
# Prereqs:
#   - gh authenticated (gh auth status)
#   - Sparkle EdDSA private key in the login keychain (its public key must match
#     Info.plist's SUPublicEDKey; created once via Sparkle's generate_keys).
#   - The Sparkle package has been resolved at least once (sign_update present);
#     this script triggers a build that resolves it anyway.
#
# The feed URL baked into Info.plist (SUFeedURL) is the repo-root appcast.xml
# served raw from GitHub, so this script writes/commits appcast.xml at the repo root.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$(git -C "$MACOS" rev-parse --show-toplevel)" && pwd)"

VERSION="${1:?usage: release.sh <version>   e.g. release.sh 1.1.0}"
TAG="v$VERSION"
REPO="iYasha/best-photo-picker"
APP="BestPhotoPicker.app"
ZIP="BestPhotoPicker-$VERSION.zip"
FEED="$REPO_ROOT/appcast.xml"
MIN_MACOS="14.0"
DD="$MACOS/.build/DerivedData"

command -v gh >/dev/null || { echo "✗ gh CLI not found"; exit 1; }

# 1. Build the bundle stamped at this version (reuses the embedded Python core;
#    pass --rebuild-core to bundle-app.sh manually if the core changed).
echo "› building $VERSION"
MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" "$HERE/bundle-app.sh"

APP_PATH="$MACOS/dist/$APP"
[ -d "$APP_PATH" ] || { echo "✗ build produced no $APP_PATH"; exit 1; }

# Locate Sparkle's signing tool (resolved into DerivedData by the build above).
SIGN_TOOL="$(find "$DD/SourcePackages/artifacts" -path '*/Sparkle/bin/sign_update' -type f 2>/dev/null | head -1)"
[ -x "$SIGN_TOOL" ] || { echo "✗ sign_update not found under $DD/SourcePackages/artifacts"; exit 1; }

# 2. Zip it (ditto keeps the .app wrapper, which Sparkle requires).
echo "› zipping $ZIP"
rm -f "$MACOS/dist/$ZIP"
ditto -c -k --keepParent "$APP_PATH" "$MACOS/dist/$ZIP"

# 3. EdDSA-sign the archive.
echo "› signing"
SIG_LINE="$("$SIGN_TOOL" "$MACOS/dist/$ZIP")"          # sparkle:edSignature="…" length="…"
ED_SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIG_LINE")"
LENGTH="$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<<"$SIG_LINE")"
[ -n "$ED_SIG" ] && [ -n "$LENGTH" ] || { echo "✗ signing failed: $SIG_LINE"; exit 1; }

DL_URL="https://github.com/$REPO/releases/download/$TAG/$ZIP"
PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# 4. Publish the GitHub release with the zip asset.
echo "› publishing GitHub release $TAG"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$MACOS/dist/$ZIP" --repo "$REPO" --clobber
else
  gh release create "$TAG" "$MACOS/dist/$ZIP" --repo "$REPO" \
    --title "Best Photo Picker $VERSION" --notes "Best Photo Picker $VERSION"
fi

# 5. Regenerate the appcast — a single latest <item>; older clients update to it.
echo "› writing $FEED"
cat > "$FEED" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Best Photo Picker</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
      <enclosure url="$DL_URL"
                 sparkle:edSignature="$ED_SIG"
                 length="$LENGTH"
                 type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

# 6. Commit + push the appcast so the raw URL serves the new version.
git -C "$REPO_ROOT" add "$FEED"
git -C "$REPO_ROOT" commit -m "Release $VERSION: update appcast"
git -C "$REPO_ROOT" push origin main

echo "✓ released $VERSION"
echo "  asset:   $DL_URL"
echo "  appcast: https://raw.githubusercontent.com/$REPO/main/appcast.xml"
