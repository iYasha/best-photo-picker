"""EXIF capture-time reads, including sub-second when the camera writes it.

Burst grouping (bursts.py) only needs to see the gap *between* bursts, which is visible
at 1-second resolution. Sub-second, when present, refines ordering within a burst.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

from PIL import Image

_EXIF_IFD = 0x8769
_DATETIME_ORIGINAL = 0x9003
_SUBSEC_ORIGINAL = 0x9291


@dataclass
class Capture:
    path: Path
    when: "datetime | None"   # best-effort capture time, incl. sub-second fraction
    has_subsec: bool


def read_capture(path: Path) -> Capture:
    try:
        with Image.open(path) as im:
            exif = im.getexif()
            ifd = exif.get_ifd(_EXIF_IFD)
    except Exception:
        return Capture(path, None, False)

    dto = ifd.get(_DATETIME_ORIGINAL)
    subsec = ifd.get(_SUBSEC_ORIGINAL)
    if not dto:
        return Capture(path, None, False)
    try:
        when = datetime.strptime(str(dto).strip(), "%Y:%m:%d %H:%M:%S")
    except (ValueError, TypeError):
        return Capture(path, None, False)

    has_subsec = False
    if subsec:
        try:
            frac = float("0." + str(subsec).strip())
            when = when + timedelta(seconds=frac)
            has_subsec = True
        except (ValueError, TypeError):
            pass
    return Capture(path, when, has_subsec)
