"""Gate + rank: turn per-frame measurements into a bin (keeper / maybe / rejected).

Principle: bias toward `maybe`. `rejected` is reserved for high-confidence trash; anything
uncertain is surfaced, never buried.
"""
from __future__ import annotations

from statistics import median

from .bursts import Burst
from .config import Config


def bin_burst(burst: Burst, cfg: Config) -> None:
    frames = burst.frames
    peak = max((f.sharpness for f in frames), default=0.0)
    nonzero = [f.face_count for f in frames if f.face_count > 0]
    has_faces = bool(nonzero)
    is_group = has_faces and median(nonzero) >= 2

    # Eyes gate: only for a single-face (portrait) burst. Groups use eyes as a rank term.
    gated = {}
    for f in frames:
        g = (
            has_faces
            and not is_group
            and f.face_count >= 1
            and f.eye_score is not None
            and f.eye_score < cfg.open_gate
        )
        gated[id(f)] = g

    if burst.is_single:
        _bin_single(frames[0], cfg)
        return

    candidates = [f for f in frames if not gated[id(f)]]
    if is_group:
        candidates.sort(key=lambda f: (-(f.eye_score or 0.0), -f.sharpness))
    else:
        candidates.sort(key=lambda f: -f.sharpness)

    keep_ids = {id(f) for f in candidates[: cfg.keep_per_burst]}
    for rank, f in enumerate(candidates):
        f.rank = rank
        if id(f) in keep_ids:
            f.bin = "keeper"
            f.reason = "best eyes + sharpness" if is_group else "sharpest in burst"
        elif peak > 0 and f.sharpness < peak * cfg.reject_sharpness_ratio:
            f.bin = "rejected"
            f.reason = "much softer than burst peak"
        else:
            f.bin = "maybe"
            f.reason = "burst runner-up"
        if f.exposure_flag and f.bin != "rejected":
            f.reason += "; exposure flag"

    for f in frames:
        if gated[id(f)]:
            f.bin = "rejected"
            f.reason = "eyes closed"
            f.rank = -1


def _bin_single(f, cfg: Config) -> None:
    f.rank = 0
    if f.face_count == 1 and f.eye_score is not None and f.eye_score < cfg.open_gate:
        f.bin = "rejected"
        f.reason = "single, eyes closed"
        return
    if f.sharpness < cfg.single_sharpness_floor:
        # Absolute sharpness is scene-dependent and unreliable -> surface, don't bury.
        f.bin = "maybe"
        f.reason = "single, sharpness uncertain"
    else:
        f.bin = "keeper"
        f.reason = "single, passed checks"
    if f.exposure_flag:
        f.reason += "; exposure flag"
