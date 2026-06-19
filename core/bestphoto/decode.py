"""Pixel decode that honours EXIF orientation — the one place an image file is opened.

Two readers need a frame opened the same way: scoring wants full-resolution gray (for
sharpness) plus a downscaled RGB (for detection); the contact sheet wants a thumbnail. Both
must apply the camera's EXIF orientation and convert to RGB first, or a portrait shot scores
and renders sideways. Keeping that decode here means the orientation handling — and any future
fix to it (a colour space, a corrupt-file guard) — lives in one module and reaches both.

This is pixel I/O, not detection: it used to sit in `detect.py`, which is about faces.
"""
from __future__ import annotations

import numpy as np
from PIL import Image, ImageOps


def _open_oriented(path):
    """Open an image, apply its EXIF orientation, convert to RGB. Returns a PIL image detached
    from the file (so it survives the closed handle), or None on any decode failure."""
    try:
        with Image.open(path) as im:
            return ImageOps.exif_transpose(im).convert("RGB")
    except Exception:
        return None


def load_image(path, long_edge: int):
    """Return (gray_fullres uint8, rgb_downscaled uint8) with orientation honoured, or
    (None, None) on failure. Gray stays full resolution — downscaling destroys the
    high-frequency signal sharpness depends on; the RGB is shrunk to long_edge for detection."""
    im = _open_oriented(path)
    if im is None:
        return None, None
    w, h = im.size
    gray = np.asarray(im.convert("L"))
    scale = long_edge / max(w, h)
    if scale < 1.0:
        small = im.resize((max(1, int(w * scale)), max(1, int(h * scale))))
        rgb_down = np.asarray(small)
    else:
        rgb_down = np.asarray(im)
    return gray, rgb_down


def thumbnail(path, px: int):
    """Open an image oriented and shrink it in place to fit a px x px box, returning a PIL image
    (or None on failure). The caller encodes it — e.g. the contact sheet as a base64 JPEG."""
    im = _open_oriented(path)
    if im is None:
        return None
    im.thumbnail((px, px))
    return im
