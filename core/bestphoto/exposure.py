"""The Exposure rule: flag a frame whose highlights are blown or shadows crushed, and the
reason annotation that surfaces the flag downstream.

Exposure is one domain concept (CONTEXT.md), read in two phases — exactly like the Eyes-open
rule in `eyes.py`. Scoring computes the flag per frame (and the result is cached); binning
annotates a frame's reason when the flag is set. It is a Flag, never a Gate: it surfaces the
issue without ever changing the bin. Both halves — what counts as badly exposed, and how the
flag reads on a verdict — live here, so the whole Exposure policy reads top to bottom in one
place.
"""
from __future__ import annotations


def flags(gray, cfg):
    """Return (flagged, blown_frac, crushed_frac) over the whole frame.

    Flagged when too large a fraction of pixels are blown (near-white, highlights clipped) or
    crushed (near-black, shadows clipped). Some frames are dark or bright by intent, so this
    only flags — it never rejects.
    """
    if gray is None or gray.size == 0:
        return (False, 0.0, 0.0)
    total = gray.size
    blown = float((gray >= cfg.blown_value).sum()) / total
    crushed = float((gray <= cfg.crushed_value).sum()) / total
    flagged = blown > cfg.blown_frac or crushed > cfg.crushed_frac
    return (flagged, blown, crushed)


def annotate(reason: str, flagged: bool) -> str:
    """Append the exposure flag to a binning reason when set, else leave it unchanged. A Flag,
    not a Gate — the caller has already decided the bin; this only surfaces the warning."""
    return reason + "; exposure flag" if flagged else reason
