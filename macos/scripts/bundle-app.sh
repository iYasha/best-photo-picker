#!/bin/bash
# Build a fully self-contained BestPhotoPicker.app:
#   1. build the embedded Python core (build-embedded-core.sh) unless it exists
#   2. Release-build the SwiftUI app
#   3. inject the core into Contents/Resources/core
#   4. ad-hoc re-sign (nested binaries first), so it runs on this Mac with no toolchain
#
# Output: macos/dist/BestPhotoPicker.app   (arm64, ad-hoc; not notarized).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS="$(cd "$HERE/.." && pwd)"
STAGE="$MACOS/EmbeddedCore"
DIST="$MACOS/dist"
DD="$MACOS/.build/DerivedData"
APP_NAME="BestPhotoPicker.app"

# 1. Embedded core (reuse if already built; pass --rebuild-core to force).
if [[ "${1:-}" == "--rebuild-core" || ! -x "$STAGE/bestphoto" ]]; then
  "$HERE/build-embedded-core.sh" "$STAGE"
else
  echo "==> reusing existing embedded core at $STAGE"
fi

# 2. Release build (ad-hoc; no dev team configured).
#    release.sh stamps the version by exporting MARKETING_VERSION / CURRENT_PROJECT_VERSION;
#    unset (plain `make`-style build) → xcodebuild keeps the pbxproj defaults.
echo "==> xcodebuild Release…"
xcodebuild -project "$MACOS/BestPhotoPicker.xcodeproj" -scheme BestPhotoPicker \
  -configuration Release -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  ${MARKETING_VERSION:+MARKETING_VERSION="$MARKETING_VERSION"} \
  ${CURRENT_PROJECT_VERSION:+CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION"} \
  clean build | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED' || true

BUILT="$DD/Build/Products/Release/$APP_NAME"
[[ -d "$BUILT" ]] || { echo "ERROR: build produced no $APP_NAME" >&2; exit 1; }

# 3. Copy app to dist, inject the core.
mkdir -p "$DIST"
rm -rf "$DIST/$APP_NAME"
cp -R "$BUILT" "$DIST/$APP_NAME"
RES="$DIST/$APP_NAME/Contents/Resources/core"
rm -rf "$RES"
mkdir -p "$RES"
# rsync preserves exec bits / symlinks inside the interpreter.
rsync -a "$STAGE/" "$RES/"

# 4. Re-sign ad-hoc, nested code first (no hardened runtime: keeps a local ad-hoc app
#    runnable without library-validation pain from the embedded third-party dylibs).
echo "==> ad-hoc signing (nested first)…"
find "$RES/python" \( -name '*.dylib' -o -name '*.so' \) -print0 \
  | xargs -0 -I{} codesign --force --sign - {} 2>/dev/null || true
codesign --force --sign - "$RES/python/bin/python3" 2>/dev/null || true
codesign --force --deep --sign - "$DIST/$APP_NAME"

echo "==> verifying seal (strict)…"
if codesign --verify --strict --deep --verbose=1 "$DIST/$APP_NAME" 2>&1; then
  echo "   seal: VALID (ad-hoc). Transfer + clear quarantine (xattr -dr com.apple.quarantine) → runs on arm64."
else
  echo "   seal: INVALID — something mutated the bundle after signing." >&2
fi
echo "   gatekeeper (expected to reject — ad-hoc, not notarized):"
spctl -a -t exec -vv "$DIST/$APP_NAME" 2>&1 | sed 's/^/     /' || true

echo "==> done:"
du -sh "$DIST/$APP_NAME"
echo "$DIST/$APP_NAME"
