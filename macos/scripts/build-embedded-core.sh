#!/bin/bash
# Build a self-contained, relocatable Python core for embedding in the .app.
#
# Produces  <STAGE>/  =  python/ (standalone CPython + site-packages)
#                        models/ (YuNet + FaceLandmarker bundles)
#                        bestphoto (launcher: sets model env, execs the interpreter)
#
# The result is copied into BestPhotoPicker.app/Contents/Resources/core by
# bundle-app.sh. arm64-only (mediapipe/cv2 wheels are single-arch here).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"                       # repo root (holds core/, uv.lock)
STAGE="${1:-$REPO/macos/EmbeddedCore}"
PYVER="3.13"
CACHE="$HOME/.cache/best-photo-picker"

echo "==> repo:  $REPO"
echo "==> stage: $STAGE"

# 1. Locate uv's relocatable (python-build-standalone) interpreter for $PYVER.
#    `uv python find` may hand back the project's .venv (whose bin/python is a symlink
#    into ~/.local/share/uv/… — NOT relocatable). Resolve to the real base interpreter
#    via sys.base_prefix; that standalone install is what we embed.
uv python install "$PYVER" >/dev/null 2>&1 || true
PYBIN="$(uv python find "$PYVER")"
PYROOT="$("$PYBIN" -c 'import sys; print(sys.base_prefix)')"
echo "==> standalone interpreter root: $PYROOT"
case "$PYROOT" in
  *"/uv/python/"*) : ;;
  *) echo "ERROR: '$PYROOT' is not a uv-managed standalone interpreter — cannot build a" >&2
     echo "       relocatable bundle from it (a non-uv Python is being picked up)." >&2
     exit 1 ;;
esac
if [[ "$(uname -m)" == "arm64" && "$PYROOT" != *aarch64* ]]; then
  echo "WARN: host is arm64 but interpreter '$PYROOT' is not aarch64." >&2
fi

# 2. Fresh stage; copy the interpreter in (it is relocatable: finds its prefix from argv0).
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$PYROOT" "$STAGE/python"
SITE="$STAGE/python/lib/python$PYVER/site-packages"
mkdir -p "$SITE"

# 3. Install the package + runtime deps (incl. faces extra) into the bundled site-packages.
#    --target installs into a plain dir (no venv); the interpreter has it on sys.path.
echo "==> installing best-photo-picker[faces] into bundle (this pulls cv2/mediapipe/numpy)…"
uv pip install --python "$STAGE/python/bin/python3" --target "$SITE" --no-cache \
  "$REPO/core[faces]"

# 3b. Drop the console-script wrappers: unused at runtime (the launcher calls the
#     interpreter directly) and their shebangs hard-code the build machine's path.
rm -rf "$SITE/bin"

# 4. Models: copy the cached bundles in (detect.py reads them via BPP_FACE_* env).
mkdir -p "$STAGE/models"
for f in yunet_face_2023mar.onnx face_landmarker.task; do
  if [[ -f "$CACHE/$f" ]]; then
    cp "$CACHE/$f" "$STAGE/models/$f"
  else
    echo "ERROR: model $f not in $CACHE — run a score once to download it, then re-run." >&2
    exit 1
  fi
done

# 5. Launcher. -I isolates from host PYTHON* env / user site (still loads the bundled
#    site-packages from the interpreter's own prefix); -u keeps stdout line-flushed so
#    progress JSON streams. CRITICAL: `-X pycache_prefix` sends ALL bytecode writes to a
#    per-user cache OUTSIDE the bundle — so a signed/installed (read-only) .app is never
#    mutated at runtime, keeping its code signature valid. BPP_FACE_* point at the models.
cat > "$STAGE/bestphoto" <<'LAUNCHER'
#!/bin/bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BPP_FACE_DETECTOR="${BPP_FACE_DETECTOR:-$HERE/models/yunet_face_2023mar.onnx}"
export BPP_FACE_MODEL="${BPP_FACE_MODEL:-$HERE/models/face_landmarker.task}"
PYC="${XDG_CACHE_HOME:-$HOME/Library/Caches}/BestPhotoPicker/pycache"
exec "$HERE/python/bin/python3" -I -u -X pycache_prefix="$PYC" \
  -c 'from bestphoto.cli import main; main(prog_name="bestphoto")' "$@"
LAUNCHER
chmod +x "$STAGE/bestphoto"

# 6. Smoke test — prove it runs with a scrubbed environment (no uv, no venv, no PATH deps)
#    AND is relocatable (its prefix resolves inside the bundle, not the host).
echo "==> smoke test (scrubbed env)…"
# Redirect this test's bytecode writes to a throwaway dir so the staged bundle stays clean.
env -i HOME="$HOME" "$STAGE/python/bin/python3" -I -X pycache_prefix=/tmp/bpp-smoke-pyc -c "
import sys
assert sys.prefix.startswith('$STAGE'), 'NOT relocatable: prefix=' + sys.prefix
import cv2, mediapipe, numpy, PIL, bestphoto.cli
print('relocatable prefix OK:', sys.prefix)
print('imports OK:', cv2.__version__, mediapipe.__version__)
"
env -i HOME="$HOME" "$STAGE/bestphoto" --help >/dev/null
# Guard against stray host-pointing symlinks in the embedded interpreter.
if find "$STAGE/python" -type l -lname "$HOME/*" | grep -q .; then
  echo "ERROR: embedded interpreter has symlinks pointing outside the bundle:" >&2
  find "$STAGE/python" -type l -lname "$HOME/*" >&2
  exit 1
fi

# 7. Strip every __pycache__ so the staged tree is pristine before signing — the launcher's
#    pycache_prefix keeps runtime writes out, so the installed .app never mutates its seal.
find "$STAGE" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

echo "==> done. size:"
du -sh "$STAGE"
