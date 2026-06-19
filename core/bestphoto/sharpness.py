"""Sharpness (Laplacian variance) on the locked subject region. Exposure lives in exposure.py."""
from __future__ import annotations

import numpy as np

try:
    import cv2
except Exception:  # pragma: no cover
    cv2 = None


def laplacian_variance(gray: np.ndarray, box=None) -> float:
    """Variance of the Laplacian over the (optionally cropped) grayscale region.

    Higher = sharper. Must be computed on full-resolution pixels — downscaling
    destroys the high-frequency signal that distinguishes sharp from soft.
    """
    if gray is None:
        return 0.0
    region = _crop(gray, box)
    if region.size == 0:
        region = gray
    if cv2 is not None:
        return float(cv2.Laplacian(region, cv2.CV_64F).var())
    # numpy fallback: 4-neighbour Laplacian
    f = region.astype(np.float64)
    lap = (-4.0 * f
           + np.roll(f, 1, 0) + np.roll(f, -1, 0)
           + np.roll(f, 1, 1) + np.roll(f, -1, 1))
    return float(lap.var())


def _crop(gray: np.ndarray, box):
    if box is None:
        return gray
    h, w = gray.shape[:2]
    x, y, bw, bh = box
    x0 = max(0, int(x * w))
    y0 = max(0, int(y * h))
    x1 = min(w, int((x + bw) * w))
    y1 = min(h, int((y + bh) * h))
    if x1 <= x0 or y1 <= y0:
        return np.empty((0, 0), dtype=gray.dtype)
    return gray[y0:y1, x0:x1]
