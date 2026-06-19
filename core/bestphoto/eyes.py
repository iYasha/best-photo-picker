"""The Eyes-open rule: the size-weighted open fraction and the portrait gate that reads it.

Eyes-open is one domain concept (CONTEXT.md), but it is read in two phases: scoring computes
the size-weighted open fraction per frame (faces exist only then, and the result is cached),
while binning interprets that fraction as a hard gate for a single-face portrait. Keeping both
halves of the rule — what counts as open, and what fails the gate — in one module means the
whole Eyes-open policy reads top to bottom in one place.
"""
from __future__ import annotations


def open_fraction(faces, cfg):
    """Size-weighted fraction of faces with open eyes; None when no face was found.

    Big foreground faces dominate the weight, tiny background faces barely count — so the frame
    where the people who matter have their eyes open scores highest.
    """
    if not faces:
        return None
    den = sum(f.area for f in faces)
    if den <= 0:
        return None
    num = sum(f.area * (1.0 if f.open_prob >= cfg.eye_open_min else 0.0) for f in faces)
    return num / den


def gate_fails(eye_score, cfg) -> bool:
    """True when the size-weighted open fraction is below the portrait gate threshold.

    Only meaningful when a face was found (`eye_score` is not None); no face -> no gate.
    """
    return eye_score is not None and eye_score < cfg.open_gate
