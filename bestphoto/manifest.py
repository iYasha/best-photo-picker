"""CSV I/O and the Frame⇄row contract: the human-readable manifest (output) and a resumable
measurement cache.

One module owns how a Frame's measurements serialize. `measurement_cells` is the single
formatter shared by the manifest and the cache, so the two can never drift. `MeasurementCache`
owns the resumable round-trip: a re-run skips the expensive decode+detect for unchanged files.
It is keyed by (rel, mtime, size) and tagged by the grouping signature (gap-seconds for time
mode, "sim" for similarity), so both modes' rows coexist in one file without colliding —
changing the burst gap invalidates cached sharpness, since the locked region changes.
"""
from __future__ import annotations

import csv
from pathlib import Path

CACHE_FIELDS = [
    "rel", "mtime", "size", "gap", "when_iso", "has_subsec",
    "face_count", "primary_box", "eye_score", "sharpness",
    "blown_frac", "crushed_frac", "exposure_flag", "phash",
]

MANIFEST_FIELDS = [
    "rel", "filename", "burst_id", "when_iso", "face_count",
    "eye_score", "sharpness", "exposure_flag", "blown_frac", "crushed_frac",
    "bin", "reason", "rank_in_burst",
]


# ---- the one Frame serializer, shared by manifest + cache ----------------

def measurement_cells(fr) -> dict:
    """A Frame's measured fields formatted as CSV cells — the single source the manifest and
    the cache both build on, so their shared columns never drift. Each writer adds its own
    identity, key, or verdict cells around these."""
    return {
        "when_iso": fr.when.isoformat() if fr.when else "",
        "face_count": fr.face_count,
        "eye_score": "" if fr.eye_score is None else f"{fr.eye_score:.4f}",
        "sharpness": f"{fr.sharpness:.3f}",
        "exposure_flag": int(fr.exposure_flag),
        "blown_frac": f"{fr.blown:.4f}",
        "crushed_frac": f"{fr.crushed:.4f}",
    }


def manifest_row(fr, burst_id, verdict) -> dict:
    """One manifest row for a scored frame: identity + shared measurement cells + the verdict
    (bin / reason / rank) that binning returned for it."""
    return {
        "rel": fr.rel, "filename": Path(fr.rel).name, "burst_id": burst_id,
        "bin": verdict.bin, "reason": verdict.reason, "rank_in_burst": verdict.rank,
        **measurement_cells(fr),
    }


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


# ---- resumable measurement cache -----------------------------------------

class MeasurementCache:
    """The resumable per-frame measurement cache, behind one interface.

    Replaces what used to be a load function, a writer class, and a pair of free
    serialize/deserialize functions split across two modules. Construct it (loading prior rows
    for this tag when resuming), then `fill(frame)` to populate a frame from cache, `has(frame)`
    to test membership without mutating, and `put(frame)` to append a fresh measurement. Rows
    are flushed per append, so a crash mid-run keeps prior work. Use as a context manager.
    """

    def __init__(self, path, tag, resume: bool):
        self.path = Path(path)
        self.tag = tag
        self._loaded = self._load() if resume else {}
        fresh = not (resume and self.path.exists() and self.path.stat().st_size > 0)
        self._fh = self.path.open("w" if fresh else "a", newline="")
        self._w = csv.DictWriter(self._fh, fieldnames=CACHE_FIELDS)
        if fresh:
            self._w.writeheader()
            self._fh.flush()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def _load(self) -> dict:
        """Load cached rows whose discriminator (`gap` column) matches this cache's tag."""
        out = {}
        if not self.path.exists():
            return out
        with self.path.open(newline="") as fh:
            for row in csv.DictReader(fh):
                try:
                    if str(row.get("gap", "")) != str(self.tag):
                        continue
                    key = (row["rel"], float(row["mtime"]), int(row["size"]))
                except (KeyError, ValueError, TypeError):
                    continue
                out[key] = row
        return out

    @staticmethod
    def _key(fr):
        return (fr.rel, fr.mtime, fr.size)

    def has(self, fr) -> bool:
        return self._key(fr) in self._loaded

    def fill(self, fr) -> bool:
        """Populate a frame's measured fields from cache. Returns False on a miss (frame
        untouched). `when`/`has_subsec` are not restored — they come from the fresh scan."""
        row = self._loaded.get(self._key(fr))
        if row is None:
            return False
        fr.face_count = int(row.get("face_count") or 0)
        fr.primary_box = _box_from_str(row.get("primary_box", ""))
        es = row.get("eye_score", "")
        fr.eye_score = float(es) if es not in ("", None) else None
        fr.sharpness = float(row.get("sharpness") or 0.0)
        fr.exposure_flag = bool(int(row.get("exposure_flag") or 0))
        fr.blown = float(row.get("blown_frac") or 0.0)
        fr.crushed = float(row.get("crushed_frac") or 0.0)
        fr.phash = int(row.get("phash") or 0)
        return True

    def put(self, fr) -> None:
        """Append a frame's measurement, tagged for this grouping mode, and flush."""
        row = {
            "rel": fr.rel, "mtime": fr.mtime, "size": fr.size, "gap": self.tag,
            "has_subsec": int(fr.has_subsec),
            "primary_box": _box_to_str(fr.primary_box),
            "phash": fr.phash,
            **measurement_cells(fr),
        }
        self._w.writerow({k: row.get(k, "") for k in CACHE_FIELDS})
        self._fh.flush()

    def close(self) -> None:
        self._fh.close()


# ---- manifest read/write -------------------------------------------------

def write_manifest(path, rows) -> None:
    with Path(path).open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=MANIFEST_FIELDS)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in MANIFEST_FIELDS})


def read_manifest_rows(path):
    with Path(path).open(newline="") as fh:
        return list(csv.DictReader(fh))
