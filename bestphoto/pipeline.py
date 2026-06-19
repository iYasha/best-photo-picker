"""The `score` phase: scan -> group -> detect -> measure -> bin -> manifest.

A GroupingStrategy (bursts.py) decides how frames form bursts and the subject region used to
score each one. The Scorer is the engine that decodes, measures, caches, and computes
sharpness — sequenced against the strategy. Two strategies (cfg.group_method):
- "time": capture-time gap bursts with a per-burst locked subject region (single decode).
- "similarity": near-duplicate clustering by perceptual hash — camera-agnostic.

Moves no files. Reads each new photo once; cached measurements are reused on re-run.
"""
from __future__ import annotations

from pathlib import Path

from . import detect, manifest
from . import sharpness as sharp
from .binning import bin_burst
from .bursts import Frame, grouping_for
from .config import Config
from .detect import FaceDetector
from .exif import read_capture
from .log import get_logger
from .phash import dhash

IMG_EXT = {".jpg", ".jpeg"}
log = get_logger()


def _round_box(box):
    return tuple(round(v, 3) for v in box) if box else "whole"


def _box_to_str(b):
    return ";".join(f"{v:.5f}" for v in b) if b else ""


def _box_from_str(s):
    if not s:
        return None
    try:
        x, y, w, h = (float(v) for v in s.split(";"))
        return (x, y, w, h)
    except ValueError:
        return None


def _eye_score(faces, cfg):
    """Size-weighted fraction of faces with open eyes. None when no face."""
    if not faces:
        return None
    den = sum(f.area for f in faces)
    if den <= 0:
        return None
    num = sum(f.area * (1.0 if f.open_prob >= cfg.eye_open_min else 0.0) for f in faces)
    return num / den


def _cache_row(fr, tag):
    return {
        "rel": fr.rel, "mtime": fr.mtime, "size": fr.size, "gap": tag,
        "when_iso": fr.when.isoformat() if fr.when else "",
        "has_subsec": int(fr.has_subsec),
        "face_count": fr.face_count,
        "primary_box": _box_to_str(fr.primary_box),
        "eye_score": "" if fr.eye_score is None else f"{fr.eye_score:.4f}",
        "sharpness": f"{fr.sharpness:.3f}",
        "blown_frac": f"{fr.blown:.4f}",
        "crushed_frac": f"{fr.crushed:.4f}",
        "exposure_flag": int(fr.exposure_flag),
        "phash": fr.phash,
    }


def _fill_from_cache(fr: Frame, row: dict) -> None:
    fr.face_count = int(row.get("face_count") or 0)
    fr.primary_box = _box_from_str(row.get("primary_box", ""))
    es = row.get("eye_score", "")
    fr.eye_score = float(es) if es not in ("", None) else None
    fr.sharpness = float(row.get("sharpness") or 0.0)
    fr.exposure_flag = bool(int(row.get("exposure_flag") or 0))
    fr.blown = float(row.get("blown_frac") or 0.0)
    fr.crushed = float(row.get("crushed_frac") or 0.0)
    fr.phash = int(row.get("phash") or 0)


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
        self.tag = strategy.tag
        self._cache = manifest.load_cache(self.cache_path, self.tag) if self.resume else {}
        self._writer = manifest.CacheWriter(self.cache_path, self.resume)
        self._decoded = 0
        try:
            if strategy.groups_before_decode:
                groups = self._group_then_score(frames, strategy)
            else:
                groups = self._score_then_group(frames, strategy)
        finally:
            self._writer.close()
        log.info("decoded", new=self._decoded, from_cache=len(frames) - self._decoded)
        return groups

    def _group_then_score(self, frames, strategy):
        """Time: group on timestamps, then decode each burst and score it on one locked region."""
        groups = strategy.group(frames)
        strategy.log_grouped(groups)
        for burst in groups:
            held = {}  # id(frame) -> full-res gray for frames decoded this run
            for fr in burst.frames:
                if self._fill_if_cached(fr):
                    continue
                gray, rgb_down = detect.load_image(fr.path, self.cfg.downscale_long_edge)
                held[id(fr)] = gray
                if gray is None:
                    log.warning("decode_failed", rel=fr.rel)
                    continue
                self._measure(fr, gray, rgb_down)
            box = strategy.region(burst, None, self.subject_mode)
            log.debug("burst", id=burst.id, frames=len(burst.frames), region=_round_box(box))
            for fr in burst.frames:
                if (fr.rel, fr.mtime, fr.size) in self._cache:
                    continue
                gray = held.get(id(fr))
                fr.sharpness = sharp.laplacian_variance(gray, box) if gray is not None else 0.0
                self._writer.append(_cache_row(fr, self.tag))
            held.clear()
        return groups

    def _score_then_group(self, frames, strategy):
        """Similarity: decode every frame (phash + own-box sharpness), then group on phash."""
        for fr in frames:
            if self._fill_if_cached(fr):
                continue
            gray, rgb_down = detect.load_image(fr.path, self.cfg.downscale_long_edge)
            if gray is None:
                log.warning("decode_failed", rel=fr.rel)
                self._writer.append(_cache_row(fr, self.tag))
                continue
            fr.phash = dhash(gray, self.cfg.phash_size)
            self._measure(fr, gray, rgb_down)
            fr.sharpness = sharp.laplacian_variance(gray, strategy.region(None, fr, self.subject_mode))
            self._writer.append(_cache_row(fr, self.tag))
        groups = strategy.group(frames)
        strategy.log_grouped(groups)
        return groups

    def _fill_if_cached(self, fr) -> bool:
        cached = self._cache.get((fr.rel, fr.mtime, fr.size))
        if cached is None:
            return False
        _fill_from_cache(fr, cached)
        log.debug("cached", rel=fr.rel, faces=fr.face_count, sharpness=round(fr.sharpness, 1))
        return True

    def _measure(self, fr, gray, rgb_down):
        """Per-frame, group-independent measurements: faces, eyes, exposure."""
        faces = self.detector.faces(rgb_down)
        fr.faces = faces
        fr.face_count = len(faces)
        fr.primary_box = max((f.box for f in faces), key=lambda b: b[2] * b[3]) if faces else None
        fr.eye_score = _eye_score(faces, self.cfg)
        flag, blown, crushed = sharp.exposure_flags(gray, self.cfg)
        fr.exposure_flag = flag
        fr.blown, fr.crushed = blown, crushed
        self._decoded += 1
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
        bin_burst(g, cfg)
        for fr in g.frames:
            counts[fr.bin] = counts.get(fr.bin, 0) + 1
            log.debug("binned", rel=fr.rel, group=g.id, bin=fr.bin,
                      rank=fr.rank, sharpness=round(fr.sharpness, 1), reason=fr.reason)
            rows.append({
                "rel": fr.rel, "filename": Path(fr.rel).name, "burst_id": g.id,
                "when_iso": fr.when.isoformat() if fr.when else "",
                "face_count": fr.face_count,
                "eye_score": "" if fr.eye_score is None else f"{fr.eye_score:.4f}",
                "sharpness": f"{fr.sharpness:.3f}",
                "exposure_flag": int(fr.exposure_flag),
                "blown_frac": f"{fr.blown:.4f}",
                "crushed_frac": f"{fr.crushed:.4f}",
                "bin": fr.bin, "reason": fr.reason, "rank_in_burst": fr.rank,
            })
    manifest.write_manifest(manifest_path, rows)
    log.info("scored", manifest=str(manifest_path), bins=counts)
    return counts
