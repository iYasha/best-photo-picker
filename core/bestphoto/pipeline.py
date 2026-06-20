"""The `score` phase: scan -> group -> detect -> measure -> bin -> manifest.

A GroupingStrategy (bursts.py) decides how frames form bursts and the subject region used to
score each one. The Scorer is the engine that decodes, measures, caches, and computes
sharpness — sequenced against the strategy. Two strategies (cfg.group_method):
- "time": capture-time gap bursts with a per-burst locked subject region (single decode).
- "similarity": near-duplicate clustering by perceptual hash — camera-agnostic.

Per-frame measurement (decode + detect + exposure + sharpness) is independent across photos,
so it runs across a process pool by default — each worker owns its own detection models, which
sidesteps the model singletons being thread-unsafe (ADR 0009). The pool is bypassed when a
detector is injected (tests), when `cfg.workers == 1`, or for sets too small to amortise the
per-process model load; those fall back to the serial path. Either way the decisions are
identical — the golden characterization tests pin that.

Moves no files. Reads each new photo once; cached measurements are reused on re-run.
"""
from __future__ import annotations

import multiprocessing
import os
import threading
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

from . import decode, eyes, exposure, manifest
from . import sharpness as sharp
from .binning import bin_burst
from .bursts import Burst, Frame, Measurement, grouping_for
from .config import Config
from .detect import FaceDetector
from .exif import read_capture
from .log import get_logger
from .phash import dhash

IMG_EXT = {".jpg", ".jpeg"}
log = get_logger()

# Parallelism tuning. Below this many uncached frames the per-process model load is not worth
# the wall-clock it saves, so we stay serial. Similarity frames are independent, so they are
# dispatched in chunks of this size (a time burst is always one whole unit — see _run_parallel).
_PARALLEL_MIN_FRAMES = 16
_SIM_CHUNK = 16

# Each pool worker holds its OWN mediapipe + tensorflow + detection models resident (spawn, not
# threads — ADR 0009), measured at ~1.3 GB. So peak RAM scales with the worker count, not the
# photo count. Auto-sizing therefore caps workers by available RAM as well as CPU, so the pool
# doesn't drive a smaller Mac into swap: workers = min(cpu, _CPU_CAP, RAM budget). 0.6 of total
# RAM is the budget left for workers (the rest covers the parent, the OS, and decode buffers).
_PER_WORKER_GB = 1.3
_RAM_BUDGET_FRAC = 0.6
_CPU_CAP = 14


def _total_ram_gb():
    """Total physical RAM in GiB, or None when the platform can't report it (then auto falls
    back to the CPU-only cap)."""
    try:
        return os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE") / 1024 ** 3
    except (ValueError, AttributeError, OSError):  # pragma: no cover - platform-dependent
        return None


def auto_workers() -> int:
    """The worker count `workers = 0` resolves to: min(cpu, _CPU_CAP=14) capped by a RAM budget.

    Memory, not cores, is the binding constraint on a big set (~1.3 GB resident per worker,
    ADR 0009). On a 64 GB Mac this returns the CPU cap (up to 14, RAM permitting); on 16 GB it
    lands near 7, on 8 GB near 3 — keeping the pool off swap. The macOS app mirrors this in Swift
    to *preview* the value Auto will use (SettingsStore.autoWorkers)."""
    by_cpu = min(os.cpu_count() or 4, _CPU_CAP)
    total = _total_ram_gb()
    if total is None:
        return by_cpu
    by_ram = max(1, int(total * _RAM_BUDGET_FRAC / _PER_WORKER_GB))
    return max(1, min(by_cpu, by_ram))


def _round_box(box):
    return tuple(round(v, 3) for v in box) if box else "whole"


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


def _fill_measurement(fr, detector, cfg, rgb_down, gray):
    """The per-frame, group-independent measurement — faces, eyes, exposure — onto `fr.m`.

    The single source of truth shared by the serial Scorer and the parallel worker, so the two
    paths can never drift. Sharpness (and phash, for similarity) are the late, group-dependent
    axes, filled onto the Measurement afterwards by the caller once the subject region is known.
    """
    faces = detector.faces(rgb_down)
    fr.faces = faces
    flag, blown, crushed = exposure.flags(gray, cfg)
    fr.m = Measurement(
        face_count=len(faces),
        primary_box=max((f.box for f in faces), key=lambda b: b[2] * b[3]) if faces else None,
        eye_score=eyes.open_fraction(faces, cfg),
        exposure_flag=flag, blown=blown, crushed=crushed,
    )


# ---- process-pool worker (one per CPU core; own detection models per process) -------------

_W_DETECTOR = None
_W_CFG = None
_W_QUEUE = None


def _init_worker(cfg, progress_queue=None):
    """Pool initializer: build this process's own FaceDetector once, reused across its units.

    Each worker owns its models (loaded lazily on the first detect), so concurrent detection
    never shares a model object — the segfault the thread-shared singletons hit (ADR 0009).
    `progress_queue` (a Manager queue) carries one message per frame back to the parent so its
    progress bar advances per frame, not in a lump when each whole unit's future resolves."""
    global _W_DETECTOR, _W_CFG, _W_QUEUE
    _W_CFG = cfg
    _W_DETECTOR = FaceDetector(cfg)
    _W_QUEUE = progress_queue


def _frame_spec(fr, cached: bool) -> dict:
    """The picklable slice of a Frame a worker needs. `cached` frames carry their restored
    Measurement so the worker can fold their face box into a time burst's locked region (and
    skip re-decoding them); fresh frames carry `None` and the worker decodes + measures them."""
    return {
        "path": str(fr.path), "rel": fr.rel, "when": fr.when,
        "mtime": fr.mtime, "size": fr.size, "has_subsec": fr.has_subsec,
        "cached": fr.m if cached else None,
    }


def _measure_unit(specs, subject_mode):
    """Worker: measure one unit of frames in a separate process; return {rel: Measurement} for
    the freshly-decoded frames only (cached frames already live in the parent).

    A unit is one whole time burst (so the locked consensus region sees every frame's box) or an
    arbitrary chunk of similarity frames (each scored on its own box, so chunking is free). This
    mirrors the serial _group_then_score / _score_then_group exactly, reusing the same strategy
    resolver and _fill_measurement, so a parallel run scores identically to a serial one."""
    cfg, detector = _W_CFG, _W_DETECTOR
    strategy = grouping_for(cfg)
    method = strategy.method
    frames, grays = [], {}
    for s in specs:
        fr = Frame(path=Path(s["path"]), rel=s["rel"], when=s["when"],
                   mtime=s["mtime"], size=s["size"], has_subsec=s["has_subsec"])
        if s["cached"] is not None:          # carried only for its box; parent already ticked it
            fr.m = s["cached"]
            frames.append((fr, False))
            continue
        gray, rgb_down = decode.load_image(fr.path, cfg.downscale_long_edge)
        if gray is None:
            fr.m = Measurement()
        else:
            _fill_measurement(fr, detector, cfg, rgb_down, gray)
            if method == "similarity":
                fr.m.phash = dhash(gray, cfg.phash_size)
            grays[fr.rel] = gray
        frames.append((fr, True))
        if _W_QUEUE is not None:             # one tick per fresh frame, streamed as it finishes
            _W_QUEUE.put(Path(fr.rel).name)

    all_frames = [fr for fr, _ in frames]
    if method == "similarity":
        resolve = strategy.subject_region(subject_mode)
    else:
        resolve = strategy.subject_region(subject_mode, burst=Burst(0, all_frames))

    out = {}
    for fr, fresh in frames:
        if not fresh:
            continue
        gray = grays.get(fr.rel)
        fr.m.sharpness = sharp.laplacian_variance(gray, resolve(fr)) if gray is not None else 0.0
        out[fr.rel] = fr.m
    return out


def _chunks(items, n):
    for i in range(0, len(items), n):
        yield items[i:i + n]


@dataclass
class _Run:
    """The mutable state of one `Scorer.run`: the open measurement cache and a tally of frames
    freshly decoded this run. Passed explicitly to every step so each method's interface names
    what it touches — the Scorer itself holds only configuration and stays reusable across runs.
    """
    cache: "manifest.MeasurementCache"
    decoded: int = 0


class Scorer:
    """Decode + measure + cache + sharpness — the engine a GroupingStrategy drives.

    Per-frame measurements (faces, eyes, exposure) are identical across strategies and live
    here. What the strategy decides: the grouping order (`groups_before_decode`), the cache
    tag, and the subject region used for sharpness. The one branch in `run` is that order —
    irreducible, because time can group on timestamps before decoding (and so decodes one
    burst at a time) while similarity must decode every frame to get its perceptual hash.

    `parallel` enables the process pool; the parent stays the single cache reader/writer and
    only the per-frame measure fans out (ADR 0009). It is off when a detector is injected (the
    pool builds its own per process and could not honour the injected one).
    """

    def __init__(self, cfg, detector, cache_path, resume, subject_mode, parallel=False):
        self.cfg = cfg
        self.detector = detector
        self.cache_path = cache_path
        self.resume = resume
        self.subject_mode = subject_mode
        self.parallel = parallel

    def _workers(self) -> int:
        """Resolve the worker count: an explicit `cfg.workers` (>0) verbatim, else the RAM-aware
        auto (`auto_workers`: min(cpu, 8) capped by available memory — see ADR 0009)."""
        n = self.cfg.workers
        if n and n > 0:
            return n
        return auto_workers()

    def run(self, frames, strategy, on_progress=None):
        total = len(frames)
        done = 0

        def tick(name):
            """Tick one frame as processed. Fires live as the Scorer decodes/measures (not
            after), so a `--json` consumer's progress bar advances through the slow pass. No-op
            when `on_progress` is None (the plain `score` path)."""
            nonlocal done
            done += 1
            if on_progress is not None:
                on_progress(done, total, name, "")

        def report(fr):
            tick(Path(fr.rel).name)

        with manifest.MeasurementCache(self.cache_path, strategy.tag, self.resume) as cache:
            run = _Run(cache=cache)
            if self._should_parallelize(frames, cache):
                groups = self._run_parallel(run, frames, strategy, tick)
            elif strategy.groups_before_decode:
                groups = self._group_then_score(run, frames, strategy, report)
            else:
                groups = self._score_then_group(run, frames, strategy, report)
        log.info("decoded", new=run.decoded, from_cache=len(frames) - run.decoded)
        return groups

    def _should_parallelize(self, frames, cache) -> bool:
        if not self.parallel or self._workers() <= 1:
            return False
        uncached = sum(1 for fr in frames if not cache.has(fr))
        return uncached >= _PARALLEL_MIN_FRAMES

    # ---- parallel path (process pool) -------------------------------------

    def _run_parallel(self, run, frames, strategy, tick):
        """Fan the per-frame measure across a process pool, keeping the parent the single cache
        reader/writer. Time dispatches one unit per burst (so the worker sees a whole burst and
        can lock its consensus region); similarity dispatches chunks of frames, then groups on
        the phashes the workers filled in. Cached frames are restored here and never dispatched."""
        cached = set()
        for fr in frames:
            if run.cache.fill(fr):
                cached.add(fr.rel)
                tick(Path(fr.rel).name)

        if strategy.groups_before_decode:           # time: a unit is one whole burst
            groups = strategy.group(frames)
            strategy.log_grouped(groups)
            units = []
            for burst in groups:
                fresh = [fr for fr in burst.frames if fr.rel not in cached]
                if fresh:
                    specs = [_frame_spec(fr, fr.rel in cached) for fr in burst.frames]
                    units.append((specs, fresh))
            self._dispatch(run, units, tick)
            return groups

        # similarity: every frame is independent (own-box sharpness), so chunk the fresh ones,
        # then group on the phashes the workers computed.
        fresh_all = [fr for fr in frames if fr.rel not in cached]
        units = [([_frame_spec(fr, False) for fr in chunk], chunk)
                 for chunk in _chunks(fresh_all, _SIM_CHUNK)]
        self._dispatch(run, units, tick)
        groups = strategy.group(frames)
        strategy.log_grouped(groups)
        return groups

    def _dispatch(self, run, units, tick):
        """Run the units across the pool. Progress and caching are split so the bar stays smooth:
        workers stream one message per frame to a queue that a background thread drains into
        `tick` live, while this thread folds each finished unit's measurements onto its frames
        and appends them to the cache (parent = sole writer). Ticking only off the queue — never
        per finished unit — is what stops the bar lurching to 100% when several units land at once.
        """
        if not units:
            return
        ctx = multiprocessing.get_context("spawn")
        mgr = ctx.Manager()
        q = mgr.Queue()
        fresh_total = sum(len(fresh) for _, fresh in units)

        def drain():
            for _ in range(fresh_total):
                tick(q.get())

        drainer = threading.Thread(target=drain, daemon=True)
        drainer.start()
        try:
            with ProcessPoolExecutor(max_workers=self._workers(), mp_context=ctx,
                                     initializer=_init_worker, initargs=(self.cfg, q)) as ex:
                futs = {ex.submit(_measure_unit, specs, self.subject_mode): fresh
                        for specs, fresh in units}
                for fut in as_completed(futs):
                    results = fut.result()
                    for fr in futs[fut]:
                        m = results.get(fr.rel)
                        if m is not None:
                            fr.m = m
                        run.decoded += 1
                        run.cache.put(fr)
        finally:
            drainer.join(timeout=5)
            mgr.shutdown()

    # ---- serial path (injected detector / tiny sets / workers=1) ----------

    def _group_then_score(self, run, frames, strategy, report):
        """Time: group on timestamps, then decode each burst and score it on one locked region."""
        groups = strategy.group(frames)
        strategy.log_grouped(groups)
        for burst in groups:
            held = {}  # id(frame) -> full-res gray for frames decoded this run
            for fr in burst.frames:
                if self._fill_if_cached(run, fr):
                    report(fr)
                    continue
                gray, rgb_down = decode.load_image(fr.path, self.cfg.downscale_long_edge)
                held[id(fr)] = gray
                if gray is None:
                    log.warning("decode_failed", rel=fr.rel)
                    report(fr)
                    continue
                self._measure(run, fr, gray, rgb_down)
                report(fr)
            resolve = strategy.subject_region(self.subject_mode, burst=burst)
            log.debug("burst", id=burst.id, frames=len(burst.frames), region=_round_box(resolve(None)))
            for fr in burst.frames:
                if run.cache.has(fr):
                    continue
                gray = held.get(id(fr))
                fr.m.sharpness = sharp.laplacian_variance(gray, resolve(fr)) if gray is not None else 0.0
                run.cache.put(fr)
            held.clear()
        return groups

    def _score_then_group(self, run, frames, strategy, report):
        """Similarity: decode every frame (phash + own-box sharpness), then group on phash."""
        resolve = strategy.subject_region(self.subject_mode)   # per-frame, no burst yet
        for fr in frames:
            if self._fill_if_cached(run, fr):
                report(fr)
                continue
            gray, rgb_down = decode.load_image(fr.path, self.cfg.downscale_long_edge)
            if gray is None:
                log.warning("decode_failed", rel=fr.rel)
                run.cache.put(fr)
                report(fr)
                continue
            self._measure(run, fr, gray, rgb_down)   # replaces fr.m, so phash + sharpness go on after
            fr.m.phash = dhash(gray, self.cfg.phash_size)
            fr.m.sharpness = sharp.laplacian_variance(gray, resolve(fr))
            run.cache.put(fr)
            report(fr)
        groups = strategy.group(frames)
        strategy.log_grouped(groups)
        return groups

    def _fill_if_cached(self, run, fr) -> bool:
        if not run.cache.fill(fr):
            return False
        log.debug("cached", rel=fr.rel, faces=fr.face_count, sharpness=round(fr.sharpness, 1))
        return True

    def _measure(self, run, fr, gray, rgb_down):
        """Per-frame, group-independent measurements: faces, eyes, exposure. Replaces the frame's
        Measurement; sharpness (and phash, for similarity) are filled onto it afterwards."""
        _fill_measurement(fr, self.detector, self.cfg, rgb_down, gray)
        run.decoded += 1
        log.debug("measured", rel=fr.rel, faces=fr.face_count,
                  eye_score=None if fr.eye_score is None else round(fr.eye_score, 3),
                  exposure_flag=fr.exposure_flag)


def score(source_root, cfg: Config, manifest_path, cache_path, resume: bool = True,
          subject_mode: str = "auto", detector=None):
    source_root = Path(source_root)
    injected = detector is not None
    detector = detector or FaceDetector(cfg)
    frames = _scan(source_root, subject_mode, cfg, detector)
    groups = Scorer(cfg, detector, cache_path, resume, subject_mode,
                    parallel=not injected).run(frames, grouping_for(cfg))
    return _emit(groups, cfg, manifest_path)


def _emit(groups, cfg, manifest_path):
    rows, counts = [], {}
    for g in groups:
        verdicts = bin_burst(g, cfg)
        for fr in g.frames:
            v = verdicts[fr]
            counts[v.bin] = counts.get(v.bin, 0) + 1
            log.debug("binned", rel=fr.rel, group=g.id, bin=v.bin,
                      rank=v.rank, sharpness=round(fr.sharpness, 1), reason=v.reason)
            rows.append(manifest.manifest_row(fr, g.id, v))
    manifest.write_manifest(manifest_path, rows)
    log.info("scored", manifest=str(manifest_path), bins=counts)
    return counts
