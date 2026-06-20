"""The machine view of a scored set: `score --json` JSON-lines progress + a final result doc.

ADR-0008 makes this JSON the *contract* the macOS app consumes (the CSV manifest stays the
human-editable artifact, ADR-0001 — `score` still writes it, untouched). This module is the
single place that turns the in-memory grouping/binning result into that wire format, so the
schema lives in one type. It computes a *view* — it never changes scoring, grouping, or
binning behavior (the golden characterization tests must stay green).

Wire shape (snake_case keys; the Swift side decodes with `.convertFromSnakeCase`):

  Progress lines  one JSON object per line, streamed as the pass runs:
      {"done": int, "total": int, "current_frame_name": str, "current_burst_label": str}

  Final result    a single JSON object emitted as the LAST line:
      {"grouping": "time"|"similarity", "bursts": [ {id,label,time,faces,keeper_id,frames:[…]} ]}

Disambiguating the two on the wire: every line is exactly one JSON object. A progress object
always has a top-level "done"; the final result object never does — it has "grouping". A
line-by-line reader routes on those keys (see SubprocessScoringEngine.swift).

Field mapping (core -> contract):
  grouping       cfg.group_method
  burst.id       "<method-initial><burst.id>"  e.g. t0 / s3  (stable, unique within a result)
  burst.label    synthesized human label (the core has no burst names): the burst's timecode,
                 plus a "· group N" suffix when more than one burst shares that second.
  burst.time     "HH:MM:SS" of the burst's earliest dated frame; "--:--:--" when undated.
  burst.faces    any frame in the burst has a face.
  burst.keeper_id stable id of the keeper frame (verdict.bin == "keeper"); first frame as fallback.
  frame.id       STABLE per photo, derived from the rel path (so the GUI's Favourites survive a
                 regroup) — not the burst-local index. See `frame_id`.
  frame.sharpness raw Laplacian variance normalized to 0..99 for display (see `normalize_sharpness`);
                 raw scoring is unchanged internally — this is a display scale only.
  frame.eyes     eye_score as a 0..100 percent int, or null when the frame has no face.
  frame.faces    face_count.
  frame.exposure "blown" | "crushed" | "ok" — from the exposure flag + which clip dominates.
  frame.mark     the bin (keeper | maybe | rejected).
  frame.reason   the binning reason (the core's own reason string, passed through verbatim).
  frame.size_bytes / frame.rel_path  the frame's on-disk size and source-root-relative path.
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import structlog

from .binning import bin_burst

# A line-reader tells progress lines from the final doc by these top-level keys.
PROGRESS_KEY = "done"
RESULT_KEY = "grouping"


def frame_id(rel: str) -> str:
    """A stable per-photo id derived from the source-root-relative path.

    Stable across groupings (and across runs) because it depends only on the path, never on the
    burst the frame lands in — so a regroup keeps the app's frame-keyed Favourites pointing at
    the same photos. Short hex prefix of a SHA-1 of the rel path: collision-safe enough within
    one import, opaque, and filename-safe."""
    digest = hashlib.sha1(rel.encode("utf-8")).hexdigest()
    return f"p{digest[:12]}"


def normalize_sharpness(raw: float, peak: float) -> int:
    """Scale a raw Laplacian variance to a 0..99 display integer.

    Linear against the result's peak sharpness (the sharpest frame in the whole set scores 99),
    because absolute Laplacian variance is scene-dependent and meaningless as an absolute number
    — only the *relative* ordering within the set matters, and that ordering is preserved. This
    is a display scale only; the raw value still drives all binning decisions upstream."""
    if peak <= 0:
        return 0
    return max(0, min(99, round(99.0 * raw / peak)))


def exposure_label(fr) -> str:
    """Map the per-frame exposure flag to the contract's enum.

    The core records the flag plus the blown/crushed pixel fractions. When flagged, report
    whichever clip dominates; otherwise "ok". A flag is never a reject (ADR/CONTEXT: Exposure is
    a Flag, not a Gate) — this only labels it."""
    if not fr.exposure_flag:
        return "ok"
    return "blown" if fr.blown >= fr.crushed else "crushed"


def _timecode(when) -> str:
    return when.strftime("%H:%M:%S") if when else "--:--:--"


def _burst_time(burst) -> str:
    dated = [fr.when for fr in burst.frames if fr.when]
    return _timecode(min(dated)) if dated else "--:--:--"


def _labels(groups) -> "dict[int, str]":
    """A human label per burst id. The core names bursts only by integer; the contract wants a
    readable title. Use the burst's timecode, disambiguating bursts that share a second with a
    "· group N" suffix so two bursts never collide on the same label."""
    times = {g.id: _burst_time(g) for g in groups}
    by_time: "dict[str, list[int]]" = {}
    for g in groups:
        by_time.setdefault(times[g.id], []).append(g.id)
    labels = {}
    for t, ids in by_time.items():
        if len(ids) == 1:
            labels[ids[0]] = t
        else:
            for n, gid in enumerate(ids, start=1):
                labels[gid] = f"{t} · group {n}"
    return labels


def _frame_doc(fr, verdict, peak) -> dict:
    eye = None if fr.eye_score is None else round(fr.eye_score * 100)
    return {
        "id": frame_id(fr.rel),
        "filename": Path(fr.rel).name,
        "sharpness": normalize_sharpness(fr.sharpness, peak),
        "eyes": eye,
        "faces": fr.face_count,
        "exposure": exposure_label(fr),
        "mark": verdict.bin,
        "reason": verdict.reason,
        "size_bytes": fr.size,
        "rel_path": fr.rel,
    }


def build_result(groups, cfg) -> dict:
    """Turn the scored groups into the final result document (a plain dict ready for json.dumps).

    Pure: reads the groups + re-derives each burst's verdicts via `bin_burst` (the same pure
    function the manifest uses), changing nothing. Frames are emitted best -> worst: the keeper
    first, then the rest by descending sharpness — the order the app shows without re-sorting."""
    peak = max((fr.sharpness for g in groups for fr in g.frames), default=0.0)
    method = cfg.group_method
    prefix = method[0]
    labels = _labels(groups)

    bursts = []
    for g in groups:
        verdicts = bin_burst(g, cfg)
        ordered = sorted(
            g.frames,
            key=lambda fr: (verdicts[fr].bin != "keeper", -fr.sharpness),
        )
        frames = [_frame_doc(fr, verdicts[fr], peak) for fr in ordered]
        keeper = next((fr for fr in ordered if verdicts[fr].bin == "keeper"), None)
        keeper_fr = keeper if keeper is not None else (ordered[0] if ordered else None)
        bursts.append({
            "id": f"{prefix}{g.id}",
            "label": labels[g.id],
            "time": _burst_time(g),
            "faces": any(fr.face_count > 0 for fr in g.frames),
            "keeper_id": frame_id(keeper_fr.rel) if keeper_fr else "",
            "frames": frames,
        })

    return {"grouping": method, "bursts": bursts}


def progress_line(done: int, total: int, frame_name: str, burst_label: str,
                  phase: str = "scoring") -> str:
    """One JSON-lines progress object as a string (no trailing newline).

    `phase` tells the app what the pass is doing without changing the wire's
    disambiguation (the line still carries `done`, so a reader still routes it as
    progress, not the final doc):
      * "loading" — the single line emitted the instant the scan finishes, before the
        worker pool has spawned and imported the ML stack. It carries the real total
        and `done == 0`, so the app shows "0 of N · Preparing…" instead of a frozen
        0-of-0 that reads as a hang.
      * "scoring" — the per-frame ticks once frames actually start finishing.
    Older readers that don't know `phase` ignore the extra key (ADR-0008: additive)."""
    return json.dumps({
        "done": done,
        "total": total,
        "current_frame_name": frame_name,
        "current_burst_label": burst_label,
        "phase": phase,
    })


def emit_progress(groups, cfg, stream=None) -> None:
    """Stream one progress line per frame, in display order, flushing each line.

    Emitted after scoring (the model loads/decode happen first), so the bar advances steadily to
    100%; the cost of the pass is the scoring, not this replay. Frames are walked burst by burst
    in the same order `build_result` emits them, so `current_frame_name` tracks the result."""
    stream = stream or sys.stdout
    labels = _labels(groups)
    ordered_groups = []
    total = 0
    for g in groups:
        verdicts = bin_burst(g, cfg)
        ordered = sorted(
            g.frames,
            key=lambda fr: (verdicts[fr].bin != "keeper", -fr.sharpness),
        )
        ordered_groups.append((g, ordered))
        total += len(ordered)

    done = 0
    for g, ordered in ordered_groups:
        for fr in ordered:
            done += 1
            stream.write(progress_line(done, total, Path(fr.rel).name, labels[g.id]) + "\n")
            stream.flush()


def emit_result(result: dict, stream=None) -> None:
    """Emit the final result document as the last line (compact, one object, trailing newline)."""
    stream = stream or sys.stdout
    stream.write(json.dumps(result) + "\n")
    stream.flush()


def logs_to_stderr() -> None:
    """Send structlog output to stderr instead of stdout.

    `--json` owns stdout: the consumer (the app) reads it line by line and parses each line as
    JSON, so a log line on stdout would corrupt the stream. structlog defaults to a stdout
    PrintLogger; re-point its factory at stderr, preserving whatever level/processors the
    `-v` flag already configured. Call this once, before scoring, when `--json` is set."""
    cfg = structlog.get_config()
    structlog.configure(
        wrapper_class=cfg.get("wrapper_class"),
        processors=cfg.get("processors"),
        logger_factory=structlog.PrintLoggerFactory(file=sys.stderr),
        cache_logger_on_first_use=False,
    )


def score_to_json(source, cfg, manifest_path, cache_path, resume, subject_mode,
                  detector=None, stream=None) -> dict:
    """Run the scoring pass, write the human CSV manifest (ADR-0001, unchanged), and stream the
    machine JSON view to `stream` (default stdout): progress lines, then the final result doc.

    This composes the same pipeline building blocks the plain `score` uses — scan, the Scorer
    driven by the configured grouping strategy, and the identical `_emit` that writes the CSV —
    so the manifest produced under `--json` is byte-for-byte the manifest produced without it
    (the golden tests pin that). The only addition is the JSON view emitted off the same groups.
    Returns the final result dict (handy for tests)."""
    from . import pipeline  # local import: jsonout is imported by nothing in pipeline's path
    from .bursts import grouping_for
    from .detect import FaceDetector

    stream = stream or sys.stdout
    source = Path(source)
    injected = detector is not None
    detector = detector or FaceDetector(cfg)
    frames = pipeline._scan(source, subject_mode, cfg, detector)

    # The scan is done, but the process pool still has to spawn its workers and have
    # each import the ML stack + load its detection models before the first frame
    # finishes — tens of seconds on a big set (worse over a network mount). Emit one
    # "loading" line now, carrying the real total, so the app shows "0 of N · Preparing…"
    # and its elapsed clock ticks, instead of a frozen 0-of-0 bar that reads as a hang.
    stream.write(progress_line(0, len(frames), "", "", phase="loading") + "\n")
    stream.flush()

    def _on_progress(done, total, frame_name, burst_label):
        # One progress line per frame, streamed AS the Scorer decodes/measures it, so the
        # app's bar advances live through the slow pass instead of jumping at the end.
        # Flushed per line; logs go to stderr so stdout stays pure JSON.
        stream.write(progress_line(done, total, frame_name, burst_label) + "\n")
        stream.flush()

    groups = pipeline.Scorer(cfg, detector, cache_path, resume, subject_mode,
                             parallel=not injected).run(
        frames, grouping_for(cfg), on_progress=_on_progress)
    pipeline._emit(groups, cfg, manifest_path)   # the human CSV — same writer as plain score

    result = build_result(groups, cfg)
    emit_result(result, stream=stream)
    return result
