"""Image decode + face/eye detection.

Two models, each used for what it's good at:
- **YuNet** (`cv2.FaceDetectorYN`) finds face boxes — robust on real scene photos and across
  scales, where MediaPipe's selfie-tuned detector silently drops faces.
- **MediaPipe FaceLandmarker** runs on each face crop to read eye-open from blendshapes.

Both model bundles are resolved from env vars, else cached under ~/.cache/best-photo-picker/
and fetched on first use.
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

_LANDMARKER_URL = (
    "https://storage.googleapis.com/mediapipe-models/face_landmarker/"
    "face_landmarker/float16/1/face_landmarker.task"
)
_YUNET_URL = (
    "https://media.githubusercontent.com/media/opencv/opencv_zoo/main/"
    "models/face_detection_yunet/face_detection_yunet_2023mar.onnx"
)

_landmarker = None
_landmarker_failed = False
_mp = None              # mediapipe module, for building mp.Image
_yunet = None
_yunet_failed = False


def _cache_dir() -> Path:
    d = Path.home() / ".cache" / "best-photo-picker"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _fetch(url: str, dest: Path, what: str) -> "Path | None":
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    try:
        log.info("model_download", model=what, url=url, dest=str(dest))
        urllib.request.urlretrieve(url, dest)
        return dest
    except Exception as e:
        log.warning("model_download_failed", model=what, error=str(e))
        return None


# ---- YuNet face detector -------------------------------------------------

def _get_yunet():
    global _yunet, _yunet_failed
    if _yunet_failed:
        return None
    if _yunet is not None:
        return _yunet
    try:
        import cv2

        path = Path(os.environ.get("BPP_FACE_DETECTOR") or _cache_dir() / "yunet_face_2023mar.onnx")
        model = _fetch(_YUNET_URL, path, "yunet")
        if model is None:
            _yunet_failed = True
            return None
        _yunet = cv2.FaceDetectorYN.create(str(model), "", (320, 320), 0.6, 0.3, 5000)
    except Exception as e:
        log.warning("yunet_init_failed", error=str(e))
        _yunet_failed = True
    return _yunet


def detector_available() -> bool:
    return _get_yunet() is not None


# ---- MediaPipe FaceLandmarker (eyes) -------------------------------------

def _get_landmarker():
    global _landmarker, _landmarker_failed, _mp
    if _landmarker_failed:
        return None
    if _landmarker is not None:
        return _landmarker
    try:
        import mediapipe as mp
        from mediapipe.tasks import python as mp_python
        from mediapipe.tasks.python import vision

        path = Path(os.environ.get("BPP_FACE_MODEL") or _cache_dir() / "face_landmarker.task")
        model = _fetch(_LANDMARKER_URL, path, "face_landmarker")
        if model is None:
            _landmarker_failed = True
            return None
        options = vision.FaceLandmarkerOptions(
            base_options=mp_python.BaseOptions(model_asset_path=str(model)),
            output_face_blendshapes=True,
            num_faces=1,            # always run on a single-face crop
            running_mode=vision.RunningMode.IMAGE,
        )
        _landmarker = vision.FaceLandmarker.create_from_options(options)
        _mp = mp
    except Exception as e:
        log.warning("face_landmarker_init_failed", error=str(e))
        _landmarker_failed = True
    return _landmarker


def eyes_available() -> bool:
    return _get_landmarker() is not None


@dataclass
class Face:
    box: tuple        # normalized (x, y, w, h)
    area: float       # normalized area (fraction of frame)
    open_prob: float  # 1 - max(eyeBlinkLeft, eyeBlinkRight); 1.0 wide open, 0.0 shut


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
    vals = [c.score for c in blendshapes if c.category_name in ("eyeBlinkLeft", "eyeBlinkRight")]
    return max(vals) if vals else 0.0


def _eye_open_for(rgb: np.ndarray, box_px) -> float:
    """Run FaceLandmarker on a padded crop of one face; return open prob (1.0 if unknown)."""
    lm = _get_landmarker()
    if lm is None:
        return 1.0
    h, w = rgb.shape[:2]
    x, y, bw, bh = box_px
    mx, my = bw * 0.4, bh * 0.4
    x0, y0 = max(0, int(x - mx)), max(0, int(y - my))
    x1, y1 = min(w, int(x + bw + mx)), min(h, int(y + bh + my))
    crop = np.ascontiguousarray(rgb[y0:y1, x0:x1])
    if crop.size == 0:
        return 1.0
    try:
        res = lm.detect(_mp.Image(image_format=_mp.ImageFormat.SRGB, data=crop))
    except Exception:
        return 1.0
    if not res.face_blendshapes:
        return 1.0
    return 1.0 - _blink(res.face_blendshapes[0])


def detect_faces(rgb: np.ndarray, max_faces: int = 6, min_face_frac: float = 0.005,
                 score_thresh: float = 0.6, foreground_ratio: float = 0.6):
    """Detect faces with YuNet, then read eye-open per face. Keeps only foreground faces:
    those at least `foreground_ratio` of the largest face's area (faces at the same distance
    are similar size; background people are much smaller), with `min_face_frac` as an absolute
    floor for the degenerate all-far case."""
    yn = _get_yunet()
    if yn is None or rgb is None:
        return []
    import cv2

    h, w = rgb.shape[:2]
    frame_area = float(w * h)
    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    yn.setInputSize((w, h))
    try:
        yn.setScoreThreshold(score_thresh)
    except Exception:
        pass
    _, faces = yn.detect(bgr)
    if faces is None:
        return []

    rows = sorted(faces, key=lambda f: f[2] * f[3], reverse=True)
    if not rows:
        return []
    max_frac = (rows[0][2] * rows[0][3]) / frame_area
    keep_frac = max(min_face_frac, foreground_ratio * max_frac)

    out = []
    for f in rows:
        if len(out) >= max_faces:
            break
        x, y, bw, bh = float(f[0]), float(f[1]), float(f[2]), float(f[3])
        area_frac = (bw * bh) / frame_area
        if area_frac < keep_frac:
            continue
        nb = (x / w, y / h, bw / w, bh / h)
        out.append(Face(box=nb, area=area_frac, open_prob=_eye_open_for(rgb, (x, y, bw, bh))))
    return out
