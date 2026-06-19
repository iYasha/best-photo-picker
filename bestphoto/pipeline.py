"""The `score` phase: scan -> group bursts -> detect -> lock region -> measure -> bin -> manifest.

Moves no files. Reads each new photo once; cached measurements are reused on re-run.
"""
from __future__ import annotations

from pathlib import Path

from . import detect, manifest
from . import sharpness as sharp
from .binning import bin_burst
from .bursts import Frame, consensus_box, group_into_bursts
from .config import Config
from .exif import read_capture
from .log import get_logger

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


def _region_for(burst, mode: str):
    """Subject-region ladder. auto/face -> per-burst consensus (falls back to centre when no
    face); center -> fixed central crop; whole -> entire frame."""
    if mode == "whole":
        return None
    if mode == "center":
        return (0.25, 0.25, 0.5, 0.5)
    return consensus_box(burst)


def score(source_root, cfg: Config, manifest_path, cache_path, resume: bool = True,
          subject_mode: str = "auto"):
    source_root = Path(source_root)
    paths = sorted(p for p in source_root.rglob("*") if p.suffix.lower() in IMG_EXT)
    log.info("scan", images=len(paths), root=str(source_root), subject_mode=subject_mode)
    if not detect.mediapipe_available():
        log.warning("mediapipe_unavailable", note="sharpness + exposure only; eye gate disabled")

    frames = []
    for p in paths:
        cap = read_capture(p)
        st = p.stat()
        frames.append(Frame(
            path=p, rel=str(p.relative_to(source_root)),
            when=cap.when, mtime=st.st_mtime, size=st.st_size, has_subsec=cap.has_subsec,
        ))

    bursts = group_into_bursts(frames, cfg.gap_seconds)
    singles = sum(1 for b in bursts if b.is_single)
    log.info("grouped", groups=len(bursts), singles=singles, bursts=len(bursts) - singles,
             gap_seconds=cfg.gap_seconds)

    cache = manifest.load_cache(cache_path, cfg.gap_seconds) if resume else {}
    writer = manifest.CacheWriter(cache_path, resume)
    decoded = 0
    try:
        for burst in bursts:
            held = {}  # id(frame) -> full-res gray for frames decoded this run
            for fr in burst.frames:
                key = (fr.rel, fr.mtime, fr.size)
                cached = cache.get(key)
                if cached is not None:
                    _fill_from_cache(fr, cached)
                    log.debug("cached", rel=fr.rel, faces=fr.face_count, sharpness=round(fr.sharpness, 1))
                    continue
                gray, rgb_down = detect.load_image(fr.path, cfg.downscale_long_edge)
                held[id(fr)] = gray
                if gray is None:
                    log.warning("decode_failed", rel=fr.rel)
                    continue
                faces = detect.detect_faces(rgb_down, cfg.max_faces)
                fr.faces = faces
                fr.face_count = len(faces)
                fr.primary_box = max((f.box for f in faces), key=lambda b: b[2] * b[3]) if faces else None
                fr.eye_score = _eye_score(faces, cfg)
                flag, blown, crushed = sharp.exposure_flags(gray, cfg)
                fr.exposure_flag = flag
                fr.blown, fr.crushed = blown, crushed
                decoded += 1
                log.debug("measured", rel=fr.rel, faces=fr.face_count,
                          eye_score=None if fr.eye_score is None else round(fr.eye_score, 3),
                          exposure_flag=fr.exposure_flag, blown=round(blown, 3), crushed=round(crushed, 3))

            box = _region_for(burst, subject_mode)
            log.debug("burst", id=burst.id, frames=len(burst.frames), region=_round_box(box))

            for fr in burst.frames:
                key = (fr.rel, fr.mtime, fr.size)
                if key in cache:
                    continue  # sharpness already cached
                gray = held.get(id(fr))
                fr.sharpness = sharp.laplacian_variance(gray, box) if gray is not None else 0.0
                writer.append({
                    "rel": fr.rel, "mtime": fr.mtime, "size": fr.size, "gap": cfg.gap_seconds,
                    "when_iso": fr.when.isoformat() if fr.when else "",
                    "has_subsec": int(fr.has_subsec),
                    "face_count": fr.face_count,
                    "primary_box": _box_to_str(fr.primary_box),
                    "eye_score": "" if fr.eye_score is None else f"{fr.eye_score:.4f}",
                    "sharpness": f"{fr.sharpness:.3f}",
                    "blown_frac": f"{fr.blown:.4f}",
                    "crushed_frac": f"{fr.crushed:.4f}",
                    "exposure_flag": int(fr.exposure_flag),
                })
            held.clear()
    finally:
        writer.close()
    log.info("decoded", new=decoded, from_cache=len(frames) - decoded)

    rows, counts = [], {}
    for burst in bursts:
        bin_burst(burst, cfg)
        for fr in burst.frames:
            counts[fr.bin] = counts.get(fr.bin, 0) + 1
            log.debug("binned", rel=fr.rel, burst=burst.id, bin=fr.bin,
                      rank=fr.rank, sharpness=round(fr.sharpness, 1), reason=fr.reason)
            rows.append({
                "rel": fr.rel, "filename": Path(fr.rel).name, "burst_id": burst.id,
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


def _fill_from_cache(fr: Frame, row: dict) -> None:
    fr.face_count = int(row.get("face_count") or 0)
    fr.primary_box = _box_from_str(row.get("primary_box", ""))
    es = row.get("eye_score", "")
    fr.eye_score = float(es) if es not in ("", None) else None
    fr.sharpness = float(row.get("sharpness") or 0.0)
    fr.exposure_flag = bool(int(row.get("exposure_flag") or 0))
    fr.blown = float(row.get("blown_frac") or 0.0)
    fr.crushed = float(row.get("crushed_frac") or 0.0)
