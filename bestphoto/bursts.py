"""Frame/Burst model, gap-based grouping, and the per-burst locked subject region."""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from statistics import median

from .phash import hamming


@dataclass
class Frame:
    path: object              # pathlib.Path
    rel: str                  # path relative to the source root (portable, NAS-relative)
    when: "datetime | None"
    mtime: float
    size: int
    has_subsec: bool = False
    faces: list = field(default_factory=list)   # detect.Face list (fresh decode only)
    face_count: int = 0
    primary_box: object = None                  # normalized (x, y, w, h) of the largest face
    sharpness: float = 0.0
    eye_score: "float | None" = None
    exposure_flag: bool = False
    blown: float = 0.0
    crushed: float = 0.0
    phash: int = 0
    # filled by binning:
    bin: str = ""
    reason: str = ""
    rank: int = 0


@dataclass
class Burst:
    id: int
    frames: list

    @property
    def is_single(self) -> bool:
        return len(self.frames) == 1


def group_into_bursts(frames, gap_seconds: float):
    """Sort by (time, filename) and split whenever the gap to the previous frame exceeds
    gap_seconds. Frames with no usable timestamp can't be proven to share a moment, so each
    forms its own group."""
    def key(f):
        return (f.when is None, f.when or datetime.max, f.rel)

    ordered = sorted(frames, key=key)
    bursts, cur = [], []
    bid = 0
    prev = None
    for f in ordered:
        split = False
        if cur:
            if f.when is None or prev is None:
                split = True
            elif (f.when - prev).total_seconds() > gap_seconds:
                split = True
        if split:
            bursts.append(Burst(bid, cur))
            bid += 1
            cur = []
        cur.append(f)
        prev = f.when
    if cur:
        bursts.append(Burst(bid, cur))
    return bursts


def group_by_similarity(frames, max_distance: int, time_ceiling: float):
    """Group near-duplicate frames by perceptual-hash distance, regardless of camera/fps.

    Walk frames in capture order; start a new group when the current frame is not a
    near-duplicate of the previous (Hamming distance > max_distance), or when they're more
    than time_ceiling seconds apart (a safety break so similar-looking shots from different
    moments never merge). A frame with no similar neighbour becomes a group of one."""
    def key(f):
        return (f.when is None, f.when or datetime.max, f.rel)

    ordered = sorted(frames, key=key)
    groups, cur = [], []
    gid = 0
    prev = None
    for f in ordered:
        split = False
        if cur and prev is not None:
            if hamming(f.phash, prev.phash) > max_distance:
                split = True
            elif f.when and prev.when and (f.when - prev.when).total_seconds() > time_ceiling:
                split = True
        if split:
            groups.append(Burst(gid, cur))
            gid += 1
            cur = []
        cur.append(f)
        prev = f
    if cur:
        groups.append(Burst(gid, cur))
    return groups


def consensus_box(burst: Burst):
    """One subject region for the whole burst: median of the primary-face boxes from frames
    that found a face; a centered fallback when none did. The same region is then used to
    score every frame, so the blurriest frame can't escape by dodging the detector."""
    boxes = [fr.primary_box for fr in burst.frames if fr.primary_box]
    if not boxes:
        return (0.25, 0.25, 0.5, 0.5)
    return (
        median(b[0] for b in boxes),
        median(b[1] for b in boxes),
        median(b[2] for b in boxes),
        median(b[3] for b in boxes),
    )
