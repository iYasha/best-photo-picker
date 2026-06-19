"""Gate + rank: turn per-frame measurements into a Verdict (keeper / maybe / rejected).

`bin_burst` is a pure function of a burst: it reads each frame's measurements and returns a
`{frame: Verdict}` map, mutating nothing. The frame stays a measurement record; the bin, the
reason, and the rank are a value the caller writes to the manifest.

Principle: bias toward `maybe`. `rejected` is reserved for high-confidence trash; anything
uncertain is surfaced, never buried.
"""
from __future__ import annotations

from dataclasses import dataclass
from statistics import median

from .bursts import Burst
from .config import Config


@dataclass(frozen=True)
class Verdict:
    """The binning outcome for one frame: its bin, the human-readable reason, and its rank
    within the burst (0 = best; -1 = gated out)."""
    bin: str
    reason: str
    rank: int


def bin_burst(burst: Burst, cfg: Config) -> "dict[object, Verdict]":
    frames = burst.frames
    peak = max((f.sharpness for f in frames), default=0.0)
    nonzero = [f.face_count for f in frames if f.face_count > 0]
    has_faces = bool(nonzero)
    is_group = has_faces and median(nonzero) >= 2

    # Eyes gate: only for a single-face (portrait) burst. Groups use eyes as a rank term.
    gated = {
        f: (
            has_faces
            and not is_group
            and f.face_count >= 1
            and f.eye_score is not None
            and f.eye_score < cfg.open_gate
        )
        for f in frames
    }

    if burst.is_single:
        return {frames[0]: _verdict_single(frames[0], cfg)}

    candidates = [f for f in frames if not gated[f]]
    if is_group:
        candidates.sort(key=lambda f: (-(f.eye_score or 0.0), -f.sharpness))
    else:
        candidates.sort(key=lambda f: -f.sharpness)

    keep = set(candidates[: cfg.keep_per_burst])
    verdicts = {}
    for rank, f in enumerate(candidates):
        if f in keep:
            b = "keeper"
            reason = "best eyes + sharpness" if is_group else "sharpest in burst"
        elif peak > 0 and f.sharpness < peak * cfg.reject_sharpness_ratio:
            b = "rejected"
            reason = "much softer than burst peak"
        else:
            b = "maybe"
            reason = "burst runner-up"
        if f.exposure_flag and b != "rejected":
            reason += "; exposure flag"
        verdicts[f] = Verdict(b, reason, rank)

    for f in frames:
        if gated[f]:
            verdicts[f] = Verdict("rejected", "eyes closed", -1)
    return verdicts


def _verdict_single(f, cfg: Config) -> Verdict:
    if f.face_count == 1 and f.eye_score is not None and f.eye_score < cfg.open_gate:
        return Verdict("rejected", "single, eyes closed", 0)
    if f.sharpness < cfg.single_sharpness_floor:
        # Absolute sharpness is scene-dependent and unreliable -> surface, don't bury.
        b, reason = "maybe", "single, sharpness uncertain"
    else:
        b, reason = "keeper", "single, passed checks"
    if f.exposure_flag:
        reason += "; exposure flag"
    return Verdict(b, reason, 0)
