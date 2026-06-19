"""The `review` phase: stage manifest bins into a keep-folder as symlinks (or copies).

Originals are never touched. Symlinks store the resolved path of the original, so they
dangle if the source (e.g. a NAS share) is unmounted or moved — an accepted trade-off.
"""
from __future__ import annotations

import os
import re
import shutil
from pathlib import Path

from .log import get_logger
from .manifest import read_manifest

log = get_logger()


def _slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", (s or "").lower()).strip("-")[:30] or "x"


def _symlink_supported(d: Path) -> bool:
    d.mkdir(parents=True, exist_ok=True)
    probe = d / ".bpp-symlink-probe"
    try:
        if probe.is_symlink() or probe.exists():
            probe.unlink()
        os.symlink(__file__, probe)
        probe.unlink()
        return True
    except OSError:
        try:
            probe.unlink()
        except OSError:
            pass
        return False


def stage(manifest_path, source_root, out_dir, bins=("keeper", "maybe"), use_copy=False):
    rows = read_manifest(manifest_path)
    out_dir = Path(out_dir)
    source_root = Path(source_root)

    link = (lambda t, d: shutil.copy2(t, d)) if use_copy else (lambda t, d: os.symlink(t, d))
    if not use_copy and not _symlink_supported(out_dir):
        log.warning("no_symlink_support", out=str(out_dir), note="copying instead")
        link = lambda t, d: shutil.copy2(t, d)
    log.info("review_start", out=str(out_dir), bins=list(bins), mode="copy" if use_copy else "symlink")

    made = {b: 0 for b in bins}
    for r in rows:
        b = r.bin
        if b not in bins:
            continue
        target = (source_root / r.rel).resolve()
        bid, fname = r.burst_id, r.filename
        if b == "keeper":
            dest_dir, name = out_dir / "keepers", f"b{bid}_{fname}"
        elif b == "maybe":
            dest_dir, name = out_dir / "maybe" / f"b{bid}", fname
        else:
            dest_dir, name = out_dir / "rejected", f"{_slug(r.reason)}_{fname}"
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = dest_dir / name
        if dest.is_symlink() or dest.exists():
            dest.unlink()
        try:
            link(target, dest)
            made[b] += 1
            log.debug("staged_link", bin=b, name=name, target=str(target))
        except OSError as e:
            log.warning("stage_failed", bin=b, file=fname, error=str(e))
    log.info("staged", out=str(out_dir), counts=made)
    return made
