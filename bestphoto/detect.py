"""Image decode (EXIF-orientation aware) and face/eye detection via MediaPipe Tasks.

Uses the FaceLandmarker task (the legacy `mp.solutions` API was removed in mediapipe 0.10.x).
Eye openness comes from the `eyeBlink` blendshapes, not a hand-rolled aspect ratio.

The task needs a model bundle (`face_landmarker.task`, ~4MB). It is resolved from the
BPP_FACE_MODEL env var, else cached under ~/.cache/best-photo-picker/ and fetched on first use.
"""
from __future__ import annotations

import os
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

from .log import get_logger

log = get_logger()

_MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/face_landmarker/"
    "face_landmarker/float16/1/face_landmarker.task"
)

_DEFAULT_FACES = 6        # matches Config.max_faces; used only for the availability probe
_landmarker = None
_built_faces: "int | None" = None
_init_failed = False
_mp = None                # the mediapipe module, for building mp.Image


def _model_path() -> Path:
    env = os.environ.get("BPP_FACE_MODEL")
    if env:
        return Path(env)
    cache = Path.home() / ".cache" / "best-photo-picker"
    cache.mkdir(parents=True, exist_ok=True)
    return cache / "face_landmarker.task"


def _ensure_model() -> "Path | None":
    p = _model_path()
    if p.exists() and p.stat().st_size > 0:
        return p
    try:
        log.info("face_model_download", url=_MODEL_URL, dest=str(p))
        urllib.request.urlretrieve(_MODEL_URL, p)
        return p
    except Exception as e:
        log.warning("face_model_download_failed", error=str(e),
                    hint="set BPP_FACE_MODEL to a local face_landmarker.task")
        return None


def _get_landmarker(max_faces: int):
    """Build (once) a FaceLandmarker for the given face cap; rebuild if the cap changes.
    A failed init is sticky so we don't retry on every photo."""
    global _landmarker, _built_faces, _init_failed, _mp
    if _init_failed:
        return None
    if _landmarker is not None and _built_faces == max_faces:
        return _landmarker
    try:
        import mediapipe as mp
        from mediapipe.tasks import python as mp_python
        from mediapipe.tasks.python import vision

        model = _ensure_model()
        if model is None:
            _init_failed = True
            return None
        options = vision.FaceLandmarkerOptions(
            base_options=mp_python.BaseOptions(model_asset_path=str(model)),
            output_face_blendshapes=True,
            num_faces=max_faces,
            running_mode=vision.RunningMode.IMAGE,
        )
        if _landmarker is not None:
            _landmarker.close()
        _landmarker = vision.FaceLandmarker.create_from_options(options)
        _built_faces = max_faces
        _mp = mp
    except Exception as e:
        log.warning("face_landmarker_init_failed", error=str(e))
        _landmarker = None
        _init_failed = True
    return _landmarker


def mediapipe_available() -> bool:
    return _get_landmarker(_DEFAULT_FACES) is not None


@dataclass
class Face:
    box: tuple        # normalized (x, y, w, h)
    area: float       # normalized area
    open_prob: float  # 1 - max(eyeBlinkLeft, eyeBlinkRight); 1.0 = wide open, 0.0 = shut


def load_image(path, long_edge: int):
    """Return (gray_fullres uint8, rgb_downscaled uint8) honoring EXIF orientation."""
    try:
        with Image.open(path) as im:
            im = ImageOps.exif_transpose(im).convert("RGB")
            w, h = im.size
            gray = np.asarray(im.convert("L"))
            scale = long_edge / max(w, h)
            if scale < 1.0:
                small = im.resize((max(1, int(w * scale)), max(1, int(h * scale))))
                rgb_down = np.asarray(small)
            else:
                rgb_down = np.asarray(im)
            return gray, rgb_down
    except Exception:
        return None, None


def _blink(blendshapes) -> float:
    """Max of the two eye-blink blendshape scores (0 open .. 1 shut)."""
    vals = [c.score for c in blendshapes if c.category_name in ("eyeBlinkLeft", "eyeBlinkRight")]
    return max(vals) if vals else 0.0


def detect_faces(rgb: np.ndarray, max_faces: int):
    """Detect faces; return list[Face] with normalized boxes and eye-open probability.
    Returns [] when no model/faces."""
    lm = _get_landmarker(max_faces)
    if lm is None or rgb is None:
        return []
    image = _mp.Image(image_format=_mp.ImageFormat.SRGB, data=np.ascontiguousarray(rgb))
    res = lm.detect(image)
    if not res.face_landmarks:
        return []
    faces = []
    blends = res.face_blendshapes or []
    for i, marks in enumerate(res.face_landmarks):
        xs = [p.x for p in marks]
        ys = [p.y for p in marks]
        x0, x1 = min(xs), max(xs)
        y0, y1 = min(ys), max(ys)
        box = (x0, y0, x1 - x0, y1 - y0)
        area = max(0.0, x1 - x0) * max(0.0, y1 - y0)
        blink = _blink(blends[i]) if i < len(blends) else 0.0
        faces.append(Face(box=box, area=area, open_prob=1.0 - blink))
    return faces
