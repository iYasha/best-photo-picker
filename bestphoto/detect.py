"""Image decode + face/eye detection.

`FaceDetector` is the seam: one object that finds face boxes and reads eye-open per face,
built from a `Config`. Two models sit behind it, each used for what it's good at:
- **YuNet** (`cv2.FaceDetectorYN`) finds face boxes — robust on real scene photos and across
  scales, where MediaPipe's selfie-tuned detector silently drops faces.
- **MediaPipe FaceLandmarker** runs on each face crop to read eye-open from blendshapes.

Both model bundles are resolved from env vars, else cached under ~/.cache/best-photo-picker/
and fetched on first use. The loaded models are cached process-wide (by path), so repeated
`FaceDetector(cfg)` construction reuses them; a load failure is cached too (no retry).
"""
from __future__ import annotations

import os
import urllib.request
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

from .config import Config
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


@dataclass
class Face:
    box: tuple        # normalized (x, y, w, h)
    area: float       # normalized area (fraction of frame)
    open_prob: float  # 1 - max(eyeBlinkLeft, eyeBlinkRight); 1.0 wide open, 0.0 shut


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


# ---- process-wide model loaders (cached by path; failure cached, no retry) ----

@lru_cache(maxsize=None)
def _load_yunet(model_path: str):
    """Load the YuNet detector from a resolved path. Returns the detector, or None on failure."""
    try:
        import cv2

        model = _fetch(_YUNET_URL, Path(model_path), "yunet")
        if model is None:
            return None
        return cv2.FaceDetectorYN.create(str(model), "", (320, 320), 0.6, 0.3, 5000)
    except Exception as e:
        log.warning("yunet_init_failed", error=str(e))
        return None


@lru_cache(maxsize=None)
def _load_landmarker(model_path: str):
    """Load the FaceLandmarker + mediapipe module. Returns (landmarker, mp), or (None, None)."""
    try:
        import mediapipe as mp
        from mediapipe.tasks import python as mp_python
        from mediapipe.tasks.python import vision

        model = _fetch(_LANDMARKER_URL, Path(model_path), "face_landmarker")
        if model is None:
            return (None, None)
        options = vision.FaceLandmarkerOptions(
            base_options=mp_python.BaseOptions(model_asset_path=str(model)),
            output_face_blendshapes=True,
            num_faces=1,            # always run on a single-face crop
            running_mode=vision.RunningMode.IMAGE,
        )
        return (vision.FaceLandmarker.create_from_options(options), mp)
    except Exception as e:
        log.warning("face_landmarker_init_failed", error=str(e))
        return (None, None)


def _blink(blendshapes) -> float:
    vals = [c.score for c in blendshapes if c.category_name in ("eyeBlinkLeft", "eyeBlinkRight")]
    return max(vals) if vals else 0.0


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


class FaceLocator:
    """Finds face boxes with YuNet — the model robust on real scene photos across scales.

    Keeps only foreground faces: those at least `foreground_ratio` of the largest face's area
    (faces at the same distance are similar size; background people are much smaller), with
    `min_face_frac` as an absolute floor for the degenerate all-far case. The model is loaded
    lazily and shared process-wide; missing model -> no faces.
    """

    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._yunet_path = str(
            os.environ.get("BPP_FACE_DETECTOR") or _cache_dir() / "yunet_face_2023mar.onnx"
        )

    @property
    def available(self) -> bool:
        return _load_yunet(self._yunet_path) is not None

    def locate(self, rgb: np.ndarray):
        """Return foreground faces, largest first, as (box_norm, area_frac, box_px) tuples.
        `box_norm` is (x, y, w, h) in [0, 1]; `box_px` is the pixel box the eye-reader needs."""
        yn = _load_yunet(self._yunet_path)
        if yn is None or rgb is None:
            return []
        import cv2

        cfg = self.cfg
        h, w = rgb.shape[:2]
        frame_area = float(w * h)
        bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
        yn.setInputSize((w, h))
        try:
            yn.setScoreThreshold(cfg.yunet_score)
        except Exception:
            pass
        _, faces = yn.detect(bgr)
        if faces is None:
            return []

        rows = sorted(faces, key=lambda f: f[2] * f[3], reverse=True)
        if not rows:
            return []
        max_frac = (rows[0][2] * rows[0][3]) / frame_area
        keep_frac = max(cfg.min_face_frac, cfg.foreground_ratio * max_frac)

        out = []
        for f in rows:
            if len(out) >= cfg.max_faces:
                break
            x, y, bw, bh = float(f[0]), float(f[1]), float(f[2]), float(f[3])
            area_frac = (bw * bh) / frame_area
            if area_frac < keep_frac:
                continue
            nb = (x / w, y / h, bw / w, bh / h)
            out.append((nb, area_frac, (x, y, bw, bh)))
        return out


class EyeReader:
    """Reads eye-open for one face crop via MediaPipe FaceLandmarker blendshapes.

    The model is loaded lazily and shared process-wide; a missing model leaves `open_prob` at
    1.0, so the eye gate is effectively disabled.
    """

    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._lm_path = str(
            os.environ.get("BPP_FACE_MODEL") or _cache_dir() / "face_landmarker.task"
        )

    @property
    def available(self) -> bool:
        return _load_landmarker(self._lm_path)[0] is not None

    def open_prob(self, rgb: np.ndarray, box_px) -> float:
        """Run FaceLandmarker on a padded crop of one face; return open prob (1.0 if unknown)."""
        lm, mp = _load_landmarker(self._lm_path)
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
            res = lm.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=crop))
        except Exception:
            return 1.0
        if not res.face_blendshapes:
            return 1.0
        return 1.0 - _blink(res.face_blendshapes[0])


class FaceDetector:
    """Finds faces and reads eye-open per face, behind one interface — a facade composing a
    `FaceLocator` (YuNet boxes, ADR-0003) and an `EyeReader` (MediaPipe eyes). Each collaborator
    owns one model; either can be injected (tests, an alternate model), else it is built from
    `cfg`. Graceful degradation: no locator -> no faces (sharpness + exposure only); no
    eye-reader -> open_prob 1.0, so the eye gate is effectively disabled.
    """

    def __init__(self, cfg: Config, locator=None, eyes=None):
        self.cfg = cfg
        self.locator = locator or FaceLocator(cfg)
        self.eyes = eyes or EyeReader(cfg)

    @property
    def available(self) -> bool:
        return self.locator.available

    @property
    def eyes_available(self) -> bool:
        return self.eyes.available

    def faces(self, rgb: np.ndarray):
        """Locate face boxes, then read eye-open per box."""
        return [
            Face(box=nb, area=area_frac, open_prob=self.eyes.open_prob(rgb, box_px))
            for nb, area_frac, box_px in self.locator.locate(rgb)
        ]
