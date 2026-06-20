# Parallelise scoring across a process pool (not threads)

`score` was serial: one photo decoded and measured at a time. Profiling a 103-photo set
(~24MP Nikon JPEGs) put **decode at 69%** of wall-time, sharpness at 16%, and detection
(YuNet + MediaPipe) at only ~10%. The work is embarrassingly parallel — each photo's
measurement is independent — so the fix is concurrency, not a faster per-photo path (full-res
JPEG decode is an irreducible cost, and sharpness needs full resolution by ADR-0003/decode.py).

**Why processes, not threads.** Decode (libjpeg) and sharpness (numpy/cv2) release the GIL, so
a thread pool gave a real ~7.5× on those alone. But the detection models are loaded once and
cached process-wide (`_load_yunet` / `_load_landmarker`, `lru_cache` by path), and calling a
*shared* `cv2.FaceDetectorYN` / MediaPipe `FaceLandmarker` from multiple threads **segfaults**
(verified). Per-thread instances would still share the cached object. A process pool sidesteps
this entirely: each worker process owns its own models, so detection — the ~10% threads could
not safely cover — parallelises too, for near-linear scaling on all cores.

**The unit of work mirrors the grouping strategy.** Time mode dispatches one whole burst per
task, so the worker sees every frame in the burst and can lock the consensus subject region
exactly as the serial path does. Similarity mode dispatches arbitrary chunks of frames (each is
scored on its own box, so chunk boundaries don't affect results), then groups on the phashes
the workers filled in. The worker reuses the same `GroupingStrategy` resolver and
`_fill_measurement` as the serial path, so a parallel run scores **identically** — the golden
characterization tests (both modes) pin this and stay green.

**The parent stays the single cache owner.** `MeasurementCache` is read and written only in the
parent: it restores cached frames before dispatch and appends fresh measurements as units
complete. Partially-cached time bursts still ship their cached frames' boxes to the worker (so
the locked region is computed over the whole burst), and only the uncached frames are
re-decoded. This keeps the resumable cache (and its single-writer flush-per-row crash safety)
unchanged.

## Consequences

- Default on. `cfg.workers` (TOML `[run] workers`, env `BPP_WORKERS`) controls it: `0` = auto,
  `1` = serial, `N>0` = exactly N (honoured verbatim, not capped — a power-user escape hatch).
  Measured end-to-end on 103 photos: 16.9s → 5.7s (~3×, held back by per-worker model load); the
  fixed startup amortises on large sets (the 3.5K target: ~9min → ~1.5min).

- **Memory scales with workers, not photos — auto is RAM-aware.** Each worker holds its own
  mediapipe + tensorflow + models resident, **measured ~1.3 GB** (`spawn`, so nothing is shared
  COW with the parent). 8 workers ≈ 10 GB regardless of set size — a 350-photo run peaks the same
  as a 3.5K run, just shorter. So `auto_workers()` (what `0` resolves to) caps by memory as well
  as cores: `min(cpu, _CPU_CAP=14, ⌊0.6 · total_RAM / 1.3 GB⌋)`. 64 GB Mac → up to 14 (~19 GB,
  RAM permitting); 16 GB → ~7; 8 GB → ~3, keeping the pool off swap. Platforms that can't report
  RAM fall back to the CPU-only cap. (`_CPU_CAP` was raised 8→14 to use more cores on high-RAM
  machines; the RAM term keeps smaller Macs from following it up.)
  The macOS Settings screen surfaces this as a **Workers** control defaulting to *Auto*, and
  mirrors the formula in Swift (`SettingsStore.autoWorkers`, `physicalMemory`/`activeProcessor
  Count`) purely to *preview* the value Auto will pick + a rough peak-RAM estimate — the core
  remains the single source of truth (an unset/`0` value omits `[run] workers`, so the core
  decides).
- The pool is **bypassed** — falling back to the serial path — when a detector is injected (the
  pool builds its own per process and can't honour an injected fake, so tests stay serial and
  deterministic), when `workers == 1`, or for sets below `_PARALLEL_MIN_FRAMES` uncached frames
  (the per-process model load isn't worth it for a handful of photos).
- `score(..., detector=None)` and `score_to_json(..., detector=None)` parallelise; passing a
  detector forces serial. **Progress is streamed per frame, not per unit:** each worker puts one
  message on a Manager queue as it finishes a frame, and a parent drain thread ticks
  `on_progress` live while the main thread folds finished units into the cache. Ticking off
  finished units instead (the obvious first cut) made the `--json` bar stall then lurch to 100%
  — several units complete near the end together, so half the ticks arrived in the last second.
  Streaming per frame keeps the bar smooth (regression: `test_measure_unit_streams_one_progress_
  message_per_fresh_frame`).
- Uses the `spawn` start method (macOS default) — workers re-import `bestphoto.pipeline`, which
  is cheap (mediapipe/cv2 model loads stay lazy, per process, on first detect).
