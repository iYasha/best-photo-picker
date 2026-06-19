"""Build a self-contained HTML contact sheet from a manifest, for eyeballing the algorithm.

Photos are grouped by burst, each thumbnail labeled with its bin + reason + scores and the
keeper highlighted. Thumbnails are embedded as base64 JPEGs, so the page is one portable
file and the originals never leave the user's disk.
"""
from __future__ import annotations

import base64
import html
import io
from collections import defaultdict
from pathlib import Path

from . import decode
from .log import get_logger
from .manifest import read_manifest

log = get_logger()

_BIN_ORDER = {"keeper": 0, "maybe": 1, "rejected": 2}

_CSS = """
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; background: #16181c; color: #d8dadf; font: 14px/1.45 -apple-system, system-ui, sans-serif; }
header { padding: 18px 22px; border-bottom: 1px solid #2a2e36; position: sticky; top: 0; background: #16181cee; backdrop-filter: blur(6px); z-index: 5; }
h1 { margin: 0 0 6px; font-size: 17px; font-weight: 600; }
.totals span { display: inline-block; margin-right: 14px; font-size: 13px; color: #aab; }
.dot { display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: 5px; vertical-align: middle; }
.k { background: #3fb950; } .m { background: #8b949e; } .r { background: #f85149; }
.burst { padding: 14px 22px 6px; }
.burst h2 { font-size: 13px; font-weight: 600; color: #8b949e; text-transform: uppercase; letter-spacing: .04em; margin: 0 0 10px; border-top: 1px solid #2a2e36; padding-top: 14px; }
.grid { display: flex; flex-wrap: wrap; gap: 12px; }
.card { width: 240px; background: #1c1f26; border: 1px solid #2a2e36; border-radius: 8px; overflow: hidden; }
.card.keeper { border-color: #3fb950; box-shadow: 0 0 0 1px #3fb95066; }
.card.rejected { opacity: .62; }
.card img { display: block; width: 100%; height: 170px; object-fit: cover; background: #000; }
.meta { padding: 8px 10px; }
.name { font-size: 12px; font-weight: 600; color: #e6e8ec; word-break: break-all; }
.badge { display: inline-block; margin: 5px 0; padding: 1px 8px; border-radius: 10px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .03em; }
.badge.keeper { background: #1f6f2e; color: #c6f6d0; }
.badge.maybe { background: #3a3f48; color: #c9ced6; }
.badge.rejected { background: #6e2420; color: #ffd0cc; }
.reason { font-size: 11.5px; color: #9aa2ad; min-height: 14px; }
.nums { margin-top: 6px; font: 11px/1.5 ui-monospace, Menlo, monospace; color: #7d8690; }
.nums b { color: #aeb6c0; font-weight: 600; }
"""


def _thumb_data_uri(path: Path, px: int) -> str | None:
    im = decode.thumbnail(path, px)
    if im is None:
        log.warning("thumb_failed", file=str(path))
        return None
    buf = io.BytesIO()
    im.save(buf, format="JPEG", quality=72)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode("ascii")


def _card(row, uri: str | None) -> str:
    b = row.bin
    name = html.escape(row.filename)
    reason = html.escape(row.reason)
    eye_txt = "—" if row.eye_score is None else f"{row.eye_score:.2f}"
    flag = " ⚠exp" if row.exposure_flag else ""
    img = f'<img src="{uri}" loading="lazy">' if uri else '<div class="card img"></div>'
    return f"""<div class="card {b}">{img}
  <div class="meta">
    <div class="name">{name}</div>
    <span class="badge {b}">{b}</span>
    <div class="reason">{reason}{flag}</div>
    <div class="nums"><b>sharp</b> {row.sharpness:.0f} · <b>eyes</b> {eye_txt} · <b>faces</b> {row.face_count}</div>
  </div></div>"""


def build(manifest_path, source_root, out_html, thumb_px: int = 320) -> Path:
    rows = read_manifest(manifest_path)
    source_root = Path(source_root)
    out_html = Path(out_html)

    bursts = defaultdict(list)
    for r in rows:
        bursts[r.burst_id].append(r)

    totals = defaultdict(int)
    for r in rows:
        totals[r.bin] += 1

    log.info("contact_build", photos=len(rows), bursts=len(bursts), out=str(out_html))

    sections = []
    for bid in sorted(bursts):
        items = sorted(bursts[bid], key=lambda r: (_BIN_ORDER.get(r.bin, 9), r.rank_in_burst))
        when = next((r.when_iso for r in items if r.when_iso), "")
        cards = []
        for r in items:
            uri = _thumb_data_uri(source_root / r.rel, thumb_px)
            cards.append(_card(r, uri))
        sections.append(
            f'<section class="burst"><h2>Burst {bid} · {len(items)} frames'
            f'{" · " + html.escape(when) if when else ""}</h2>'
            f'<div class="grid">{"".join(cards)}</div></section>'
        )

    totals_html = (
        f'<span><i class="dot k"></i>{totals.get("keeper", 0)} keepers</span>'
        f'<span><i class="dot m"></i>{totals.get("maybe", 0)} maybe</span>'
        f'<span><i class="dot r"></i>{totals.get("rejected", 0)} rejected</span>'
    )
    doc = f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Best Photo Picker — contact sheet</title><style>{_CSS}</style></head>
<body><header><h1>Contact sheet — {html.escape(str(source_root))}</h1>
<div class="totals">{totals_html}</div></header>
{"".join(sections)}
</body></html>"""

    out_html.write_text(doc, encoding="utf-8")
    return out_html
