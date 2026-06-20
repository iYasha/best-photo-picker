"""auto_workers (ADR 0009): the count `workers = 0` resolves to. Memory, not cores, is the
binding constraint on a big set (~1.3 GB resident per worker), so auto caps by RAM as well as
CPU: min(cpu, 8, ⌊0.6·RAM/1.3⌋). Pure arithmetic over two probes (cpu_count, total RAM), so it
is driven deterministically here by monkeypatching both — no real pool, fast suite."""
import bestphoto.pipeline as pipeline


def _patch(monkeypatch, cpu, ram_gb):
    monkeypatch.setattr(pipeline.os, "cpu_count", lambda: cpu)
    monkeypatch.setattr(pipeline, "_total_ram_gb", lambda: ram_gb)


def test_auto_caps_at_cpu_cap_when_cpu_and_ram_are_plentiful(monkeypatch):
    # 64 GB / 1.3 ≈ 29 by RAM, 16 cores → the CPU cap (_CPU_CAP=14) binds.
    _patch(monkeypatch, cpu=16, ram_gb=64)
    assert pipeline.auto_workers() == 14
    assert pipeline.auto_workers() == pipeline._CPU_CAP


def test_auto_is_ram_bound_on_a_smaller_mac(monkeypatch):
    # 16 GB: ⌊0.6·16/1.3⌋ = 7 by RAM, well under the CPU cap (14) → RAM binds at 7.
    # 8 GB: ⌊0.6·8/1.3⌋ = 3.
    _patch(monkeypatch, cpu=16, ram_gb=16)
    assert pipeline.auto_workers() == 7
    _patch(monkeypatch, cpu=16, ram_gb=8)
    assert pipeline.auto_workers() == 3


def test_auto_is_cpu_bound_when_cores_are_few(monkeypatch):
    _patch(monkeypatch, cpu=4, ram_gb=64)
    assert pipeline.auto_workers() == 4


def test_auto_never_drops_below_one(monkeypatch):
    # A tiny-RAM box still gets a (serial-ish) single worker, never 0.
    _patch(monkeypatch, cpu=8, ram_gb=1)
    assert pipeline.auto_workers() == 1


def test_auto_falls_back_to_cpu_cap_when_ram_unknown(monkeypatch):
    _patch(monkeypatch, cpu=16, ram_gb=None)
    assert pipeline.auto_workers() == 14


def test_explicit_workers_bypasses_auto(monkeypatch):
    # cfg.workers > 0 is honoured verbatim (power-user escape hatch), not RAM-capped.
    _patch(monkeypatch, cpu=2, ram_gb=2)
    cfg = pipeline.Config(workers=12)
    scorer = pipeline.Scorer(cfg, detector=None, cache_path=None, resume=False,
                             subject_mode="auto", parallel=True)
    assert scorer._workers() == 12
