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
from dataclasses import dataclass
from pathlib import Path

from .bursts import Measurement

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


def measurement_from_row(row) -> Measurement:
    """Rebuild a Measurement from a cache row — the read side of `measurement_cells`, in the
    same module, so the cached schema has one (de)serializer per direction."""
    es = row.get("eye_score", "")
    return Measurement(
        face_count=int(row.get("face_count") or 0),
        primary_box=_box_from_str(row.get("primary_box", "")),
        eye_score=float(es) if es not in ("", None) else None,
        sharpness=float(row.get("sharpness") or 0.0),
        exposure_flag=bool(int(row.get("exposure_flag") or 0)),
        blown=float(row.get("blown_frac") or 0.0),
        crushed=float(row.get("crushed_frac") or 0.0),
        phash=int(row.get("phash") or 0),
    )


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
        """Restore a frame's Measurement from cache. Returns False on a miss (frame untouched).
        `when`/`has_subsec` are not restored — they come from the fresh scan."""
        row = self._loaded.get(self._key(fr))
        if row is None:
            return False
        fr.m = measurement_from_row(row)
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


# ---- the typed manifest row: the read-side contract ----------------------

def _opt_float(s):
    return float(s) if s not in ("", None) else None


def _int(s, default=0):
    try:
        return int(str(s).strip())
    except (ValueError, TypeError):
        return default


def _float(s, default=0.0):
    try:
        return float(s)
    except (ValueError, TypeError):
        return default


@dataclass(frozen=True)
class ManifestRow:
    """One manifest row, parsed and typed — the read-side interface to the Manifest.

    Scoring writes CSV strings; every downstream reader used to re-coerce each cell
    (`int(rank or 0)`, `flag in ("1", 1, True)`) on its own. `parse` does that once, here, so
    consumers see typed fields and the row schema lives in a single module.
    """
    rel: str
    filename: str
    burst_id: int
    when_iso: str
    face_count: int
    eye_score: "float | None"
    sharpness: float
    exposure_flag: bool
    blown_frac: float
    crushed_frac: float
    bin: str
    reason: str
    rank_in_burst: int

    @classmethod
    def parse(cls, row: dict) -> "ManifestRow":
        rel = row.get("rel", "")
        return cls(
            rel=rel,
            filename=row.get("filename") or Path(rel).name,
            burst_id=_int(row.get("burst_id")),
            when_iso=row.get("when_iso", "") or "",
            face_count=_int(row.get("face_count")),
            eye_score=_opt_float(row.get("eye_score", "")),
            sharpness=_float(row.get("sharpness")),
            exposure_flag=str(row.get("exposure_flag", "")) in ("1", "True", "true"),
            blown_frac=_float(row.get("blown_frac")),
            crushed_frac=_float(row.get("crushed_frac")),
            bin=row.get("bin", ""),
            reason=row.get("reason", "") or "",
            rank_in_burst=_int(row.get("rank_in_burst")),
        )


# ---- manifest read/write -------------------------------------------------

def write_manifest(path, rows) -> None:
    with Path(path).open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=MANIFEST_FIELDS)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in MANIFEST_FIELDS})


def read_manifest(path) -> "list[ManifestRow]":
    """Read the manifest into typed rows — the deep read side of the contract."""
    with Path(path).open(newline="") as fh:
        return [ManifestRow.parse(r) for r in csv.DictReader(fh)]
