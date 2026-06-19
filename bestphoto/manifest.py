"""CSV I/O: the human-readable manifest (output) and a resumable measurement cache.

The cache lets a re-run skip the expensive decode+detect for unchanged files. It is keyed by
(rel, mtime, size, gap); changing the burst gap invalidates cached sharpness, since the
locked region — and therefore the measurement — changes.
"""
from __future__ import annotations

import csv
from pathlib import Path

CACHE_FIELDS = [
    "rel", "mtime", "size", "gap", "when_iso", "has_subsec",
    "face_count", "primary_box", "eye_score", "sharpness",
    "blown_frac", "crushed_frac", "exposure_flag",
]

MANIFEST_FIELDS = [
    "rel", "filename", "burst_id", "when_iso", "face_count",
    "eye_score", "sharpness", "exposure_flag", "blown_frac", "crushed_frac",
    "bin", "reason", "rank_in_burst",
]


def load_cache(path, gap: float) -> dict:
    out = {}
    p = Path(path)
    if not p.exists():
        return out
    with p.open(newline="") as fh:
        for row in csv.DictReader(fh):
            try:
                if abs(float(row["gap"]) - gap) > 1e-9:
                    continue
                key = (row["rel"], float(row["mtime"]), int(row["size"]))
            except (KeyError, ValueError, TypeError):
                continue
            out[key] = row
    return out


class CacheWriter:
    """Append-as-you-go, flushed per row, so a crash mid-run keeps prior work."""

    def __init__(self, path, resume: bool):
        self.path = Path(path)
        fresh = not (resume and self.path.exists() and self.path.stat().st_size > 0)
        mode = "w" if fresh else "a"
        self.fh = self.path.open(mode, newline="")
        self.w = csv.DictWriter(self.fh, fieldnames=CACHE_FIELDS)
        if fresh:
            self.w.writeheader()
            self.fh.flush()

    def append(self, row: dict) -> None:
        self.w.writerow({k: row.get(k, "") for k in CACHE_FIELDS})
        self.fh.flush()

    def close(self) -> None:
        self.fh.close()


def write_manifest(path, rows) -> None:
    with Path(path).open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=MANIFEST_FIELDS)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in MANIFEST_FIELDS})


def read_manifest_rows(path):
    with Path(path).open(newline="") as fh:
        return list(csv.DictReader(fh))
