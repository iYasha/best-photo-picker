"""Frame/Burst model, the two grouping strategies, and the per-burst locked subject region."""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from statistics import median

from .log import get_logger
from .phash import hamming

log = get_logger()

CENTER_BOX = (0.25, 0.25, 0.5, 0.5)   # centred half-frame: the subject-region fallback


@dataclass
class Measurement:
    """Everything scoring reads off a frame's pixels — and exactly the fields the cache and the
    manifest serialize. Splitting it off Frame (the way Verdict was) means the measurement
    schema lives in one value: add a measurement, touch one type. The raw `faces` list is NOT
    here — it is transient (never cached), so it stays on the Frame. Mutable on purpose:
    sharpness is the late, group-dependent axis, filled after the subject region is known."""
    face_count: int = 0
    primary_box: object = None                  # normalized (x, y, w, h) of the largest face
    eye_score: "float | None" = None
    sharpness: float = 0.0
    exposure_flag: bool = False
    blown: float = 0.0
    crushed: float = 0.0
    phash: int = 0


@dataclass(eq=False)
class Frame:
    """A scanned, then measured, photo. Identity-based (eq=False): every frame is a distinct
    object, so frames are hashable and can key dicts/sets directly — no id() workarounds.

    Identity + capture are fields; the pixel measurements live in `m` (a Measurement), so 'what
    is measured' is one value the cache and manifest serialize. Readers (binning, grouping,
    serialization) reach the measurements through the facade properties below, so they need not
    know about `m`; only the Scorer and the cache, which write measurements, touch it directly.
    The binning verdict (bin/reason/rank) is NOT stored here; binning returns it as a Verdict."""
    path: object              # pathlib.Path
    rel: str                  # path relative to the source root (portable, NAS-relative)
    when: "datetime | None"
    mtime: float
    size: int
    has_subsec: bool = False
    faces: list = field(default_factory=list)        # transient detect.Face list; never cached
    m: Measurement = field(default_factory=Measurement)

    # read facade — measurements read as if they were still frame fields
    @property
    def face_count(self):
        return self.m.face_count

    @property
    def primary_box(self):
        return self.m.primary_box

    @property
    def eye_score(self):
        return self.m.eye_score

    @property
    def sharpness(self):
        return self.m.sharpness

    @property
    def exposure_flag(self):
        return self.m.exposure_flag

    @property
    def blown(self):
        return self.m.blown

    @property
    def crushed(self):
        return self.m.crushed

    @property
    def phash(self):
        return self.m.phash


@dataclass
class Burst:
    id: int
    frames: list

    @property
    def is_single(self) -> bool:
        return len(self.frames) == 1


def _chronological(frames):
    """Frames in capture order: by timestamp, undated ones last, ties broken by filename."""
    return sorted(frames, key=lambda f: (f.when is None, f.when or datetime.max, f.rel))


# ---- grouping strategies -------------------------------------------------

class GroupingStrategy:
    """How frames become bursts, plus the subject region used to score each frame.

    A strategy carries only per-mode policy: how to group, where the subject region is, and
    the cache tag. `groups_before_decode` is the one fact the Scorer needs to sequence a run:
    time grouping reads only timestamps, so it can group before any pixels are decoded (and
    decode one burst at a time); similarity grouping reads perceptual hashes, so every frame
    must be decoded first.

    `subject_region` returns a resolver `frame -> box`, not a box: the whole/center modes are
    frame-independent and shared here; auto is where the strategies differ in *granularity* —
    time locks one region for the whole burst (so it needs the burst), similarity uses each
    frame's own box (so it needs no burst). That difference lives inside the returned closure,
    so the Scorer asks once and calls `resolve(frame)` the same way in either decode order.
    """

    groups_before_decode = True
    method = "?"

    def __init__(self, cfg):
        self.cfg = cfg

    def group(self, frames):
        raise NotImplementedError

    def subject_region(self, mode, burst=None):
        """A `frame -> subject box` resolver for sharpness. `burst` is supplied only by the
        group-before-decode path (time); similarity omits it."""
        if mode == "whole":
            return lambda frame: None
        if mode == "center":
            return lambda frame: CENTER_BOX
        return self._auto_resolver(burst)

    def _auto_resolver(self, burst):
        raise NotImplementedError

    def log_grouped(self, groups):
        raise NotImplementedError


class TimeGrouping(GroupingStrategy):
    """Capture-time gap bursts; one locked consensus region scores every frame in a burst."""

    groups_before_decode = True
    method = "time"

    def __init__(self, cfg):
        super().__init__(cfg)
        self.tag = cfg.gap_seconds   # cache discriminator: the gap invalidates locked-region sharpness

    def group(self, frames):
        """Split into bursts wherever the gap to the previous frame exceeds gap_seconds.
        Frames with no usable timestamp can't be proven to share a moment, so each forms its
        own group."""
        gap_seconds = self.cfg.gap_seconds
        bursts, cur = [], []
        bid = 0
        prev = None
        for f in _chronological(frames):
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

    def _auto_resolver(self, burst):
        """Lock one subject region for the whole burst: median of the primary-face boxes from
        frames that found a face; a centered fallback when none did. The same region scores
        every frame, so the blurriest frame can't escape by dodging the detector."""
        boxes = [fr.primary_box for fr in burst.frames if fr.primary_box]
        if not boxes:
            locked = CENTER_BOX
        else:
            locked = (
                median(b[0] for b in boxes),
                median(b[1] for b in boxes),
                median(b[2] for b in boxes),
                median(b[3] for b in boxes),
            )
        return lambda frame: locked

    def log_grouped(self, groups):
        singles = sum(1 for g in groups if g.is_single)
        log.info("grouped", method="time", groups=len(groups), singles=singles,
                 bursts=len(groups) - singles, gap_seconds=self.cfg.gap_seconds)


class SimilarityGrouping(GroupingStrategy):
    """Near-duplicate clusters by perceptual-hash distance; each frame scored on its own box."""

    groups_before_decode = False
    method = "similarity"

    def __init__(self, cfg):
        super().__init__(cfg)
        self.tag = "sim"

    def group(self, frames):
        """Group near-duplicate frames by perceptual-hash distance, regardless of camera/fps.

        Walk frames in capture order; start a new group when the current frame is not a
        near-duplicate of the previous (Hamming distance > sim_max_distance), or when they're
        more than sim_time_ceiling seconds apart (a safety break so similar-looking shots from
        different moments never merge). A frame with no similar neighbour becomes a group of
        one."""
        max_distance = self.cfg.sim_max_distance
        time_ceiling = self.cfg.sim_time_ceiling
        groups, cur = [], []
        gid = 0
        prev = None
        for f in _chronological(frames):
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

    def _auto_resolver(self, burst):
        return lambda frame: frame.primary_box or CENTER_BOX

    def log_grouped(self, groups):
        singles = sum(1 for g in groups if g.is_single)
        log.info("grouped", method="similarity", groups=len(groups), singles=singles,
                 clusters=len(groups) - singles, max_distance=self.cfg.sim_max_distance)


def grouping_for(cfg) -> GroupingStrategy:
    """Pick the grouping strategy named by cfg.group_method (default: time)."""
    if cfg.group_method == "similarity":
        return SimilarityGrouping(cfg)
    return TimeGrouping(cfg)
