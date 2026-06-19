"""The `score` phase: scan -> group -> detect -> measure -> bin -> manifest.

A GroupingStrategy (bursts.py) decides how frames form bursts and the subject region used to
score each one. The Scorer is the engine that decodes, measures, caches, and computes
sharpness — sequenced against the strategy. Two strategies (cfg.group_method):
- "time": capture-time gap bursts with a per-burst locked subject region (single decode).
- "similarity": near-duplicate clustering by perceptual hash — camera-agnostic.

Moves no files. Reads each new photo once; cached measurements are reused on re-run.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from . import decode, eyes, exposure, manifest
from . import sharpness as sharp
from .binning import bin_burst
from .bursts import Frame, Measurement, grouping_for
from .config import Config
from .detect import FaceDetector
from .exif import read_capture
from .log import get_logger
from .phash import dhash

IMG_EXT = {".jpg", ".jpeg"}
log = get_logger()


def _round_box(box):
    return tuple(round(v, 3) for v in box) if box else "whole"


def _scan(source_root, subject_mode, cfg, detector):
    paths = sorted(p for p in source_root.rglob("*") if p.suffix.lower() in IMG_EXT)
    log.info("scan", images=len(paths), root=str(source_root),
             subject_mode=subject_mode, group=cfg.group_method)
    if not detector.available:
        log.warning("face_detector_unavailable", note="no faces; sharpness + exposure only")
    elif not detector.eyes_available:
        log.warning("eyes_unavailable", note="faces detected but eye gate disabled")
    frames = []
    for p in paths:
        cap = read_capture(p)
        st = p.stat()
        frames.append(Frame(path=p, rel=str(p.relative_to(source_root)),
                            when=cap.when, mtime=st.st_mtime, size=st.st_size,
                            has_subsec=cap.has_subsec))
    return frames


@dataclass
class _Run:
    """The mutable state of one `Scorer.run`: the open measurement cache and a tally of frames
    freshly decoded this run. Passed explicitly to every step so each method's interface names
    what it touches — the Scorer itself holds only configuration and stays reusable across runs.
    """
    cache: "manifest.MeasurementCache"
    decoded: int = 0


class Scorer:
    """Decode + measure + cache + sharpness — the engine a GroupingStrategy drives.

    Per-frame measurements (faces, eyes, exposure) are identical across strategies and live
    here. What the strategy decides: the grouping order (`groups_before_decode`), the cache
    tag, and the subject region used for sharpness. The one branch in `run` is that order —
    irreducible, because time can group on timestamps before decoding (and so decodes one
    burst at a time) while similarity must decode every frame to get its perceptual hash.
    """

    def __init__(self, cfg, detector, cache_path, resume, subject_mode):
        self.cfg = cfg
        self.detector = detector
        self.cache_path = cache_path
        self.resume = resume
        self.subject_mode = subject_mode

    def run(self, frames, strategy):
        with manifest.MeasurementCache(self.cache_path, strategy.tag, self.resume) as cache:
            run = _Run(cache=cache)
            if strategy.groups_before_decode:
                groups = self._group_then_score(run, frames, strategy)
            else:
                groups = self._score_then_group(run, frames, strategy)
        log.info("decoded", new=run.decoded, from_cache=len(frames) - run.decoded)
        return groups

    def _group_then_score(self, run, frames, strategy):
        """Time: group on timestamps, then decode each burst and score it on one locked region."""
        groups = strategy.group(frames)
        strategy.log_grouped(groups)
        for burst in groups:
            held = {}  # id(frame) -> full-res gray for frames decoded this run
            for fr in burst.frames:
                if self._fill_if_cached(run, fr):
                    continue
                gray, rgb_down = decode.load_image(fr.path, self.cfg.downscale_long_edge)
                held[id(fr)] = gray
                if gray is None:
                    log.warning("decode_failed", rel=fr.rel)
                    continue
                self._measure(run, fr, gray, rgb_down)
            resolve = strategy.subject_region(self.subject_mode, burst=burst)
            log.debug("burst", id=burst.id, frames=len(burst.frames), region=_round_box(resolve(None)))
            for fr in burst.frames:
                if run.cache.has(fr):
                    continue
                gray = held.get(id(fr))
                fr.m.sharpness = sharp.laplacian_variance(gray, resolve(fr)) if gray is not None else 0.0
                run.cache.put(fr)
            held.clear()
        return groups

    def _score_then_group(self, run, frames, strategy):
        """Similarity: decode every frame (phash + own-box sharpness), then group on phash."""
        resolve = strategy.subject_region(self.subject_mode)   # per-frame, no burst yet
        for fr in frames:
            if self._fill_if_cached(run, fr):
                continue
            gray, rgb_down = decode.load_image(fr.path, self.cfg.downscale_long_edge)
            if gray is None:
                log.warning("decode_failed", rel=fr.rel)
                run.cache.put(fr)
                continue
            self._measure(run, fr, gray, rgb_down)   # replaces fr.m, so phash + sharpness go on after
            fr.m.phash = dhash(gray, self.cfg.phash_size)
            fr.m.sharpness = sharp.laplacian_variance(gray, resolve(fr))
            run.cache.put(fr)
        groups = strategy.group(frames)
        strategy.log_grouped(groups)
        return groups

    def _fill_if_cached(self, run, fr) -> bool:
        if not run.cache.fill(fr):
            return False
        log.debug("cached", rel=fr.rel, faces=fr.face_count, sharpness=round(fr.sharpness, 1))
        return True

    def _measure(self, run, fr, gray, rgb_down):
        """Per-frame, group-independent measurements: faces, eyes, exposure. Replaces the frame's
        Measurement; sharpness (and phash, for similarity) are filled onto it afterwards."""
        faces = self.detector.faces(rgb_down)
        fr.faces = faces
        flag, blown, crushed = exposure.flags(gray, self.cfg)
        fr.m = Measurement(
            face_count=len(faces),
            primary_box=max((f.box for f in faces), key=lambda b: b[2] * b[3]) if faces else None,
            eye_score=eyes.open_fraction(faces, self.cfg),
            exposure_flag=flag, blown=blown, crushed=crushed,
        )
        run.decoded += 1
        log.debug("measured", rel=fr.rel, faces=fr.face_count,
                  eye_score=None if fr.eye_score is None else round(fr.eye_score, 3),
                  exposure_flag=fr.exposure_flag)


def score(source_root, cfg: Config, manifest_path, cache_path, resume: bool = True,
          subject_mode: str = "auto", detector=None):
    source_root = Path(source_root)
    detector = detector or FaceDetector(cfg)
    frames = _scan(source_root, subject_mode, cfg, detector)
    groups = Scorer(cfg, detector, cache_path, resume, subject_mode).run(frames, grouping_for(cfg))
    return _emit(groups, cfg, manifest_path)


def _emit(groups, cfg, manifest_path):
    rows, counts = [], {}
    for g in groups:
        verdicts = bin_burst(g, cfg)
        for fr in g.frames:
            v = verdicts[fr]
            counts[v.bin] = counts.get(v.bin, 0) + 1
            log.debug("binned", rel=fr.rel, group=g.id, bin=v.bin,
                      rank=v.rank, sharpness=round(fr.sharpness, 1), reason=v.reason)
            rows.append(manifest.manifest_row(fr, g.id, v))
    manifest.write_manifest(manifest_path, rows)
    log.info("scored", manifest=str(manifest_path), bins=counts)
    return counts
