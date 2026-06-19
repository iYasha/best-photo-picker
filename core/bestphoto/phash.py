"""Perceptual hash (dHash) for near-duplicate grouping — camera-agnostic frame similarity."""
from __future__ import annotations

import numpy as np
from PIL import Image


def dhash(gray: np.ndarray, size: int = 8) -> int:
    """Difference hash of a grayscale image -> an (size*size)-bit integer.

    Shrinks to (size+1, size) and compares horizontally adjacent pixels. Robust to small
    exposure/scale changes, so near-duplicate frames land a small Hamming distance apart.
    """
    if gray is None:
        return 0
    img = Image.fromarray(gray).resize((size + 1, size))
    a = np.asarray(img, dtype=np.int16)
    diff = a[:, 1:] > a[:, :-1]
    bits = 0
    for v in diff.reshape(-1):
        bits = (bits << 1) | int(v)
    return bits


def hamming(a: int, b: int) -> int:
    """Number of differing bits — the perceptual distance between two dHashes."""
    return bin(int(a) ^ int(b)).count("1")
