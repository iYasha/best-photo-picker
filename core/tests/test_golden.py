"""Characterization (golden-master) test: re-run scoring and assert the decisions are
unchanged vs the saved snapshots in tests/golden/.

This is the refactor safety net — if a change alters which photos are keeper/maybe/rejected,
how faces are counted, or how frames group, this fails. After an *intentional* behavior
change, regenerate the snapshots: BPP_REGEN=1 pytest tests/test_golden.py

Needs the real photo set (cv2 + mediapipe). Skips if the photos or models are absent. Point
it at your folder with BPP_TEST_PHOTOS=/path/to/photos.
"""
import csv
import os
from pathlib import Path

import pytest

GOLDEN = Path(__file__).parent / "golden"
PHOTOS = Path(os.environ.get("BPP_TEST_PHOTOS", Path.home() / "Desktop" / "test_photos"))
REGEN = os.environ.get("BPP_REGEN") == "1"

MODES = [("time", "manifest_time.csv"), ("similarity", "manifest_sim.csv")]

pytestmark = [
    pytest.mark.slow,
    pytest.mark.skipif(not PHOTOS.exists(), reason=f"no photos at {PHOTOS}"),
]


def _by_file(path):
    with open(path) as f:
        return {r["filename"]: r for r in csv.DictReader(f)}


def _score(group, out_manifest, tmp_path):
    from bestphoto import log, pipeline
    from bestphoto.config import Config
    log.configure(False)
    pipeline.score(PHOTOS, Config(group_method=group), out_manifest,
                   tmp_path / f"cache_{group}.csv", resume=False)


@pytest.mark.parametrize("group,golden_name", MODES)
def test_decisions_match_golden(group, golden_name, tmp_path):
    out = tmp_path / "manifest.csv"
    _score(group, out, tmp_path)

    if REGEN:
        GOLDEN.mkdir(exist_ok=True)
        (GOLDEN / golden_name).write_text(out.read_text())
        pytest.skip(f"regenerated {golden_name}")

    golden = GOLDEN / golden_name
    if not golden.exists():
        pytest.fail(f"missing snapshot {golden} — create it with BPP_REGEN=1")

    cur, gold = _by_file(out), _by_file(golden)
    assert set(cur) == set(gold), "different set of files scored"

    drift = []
    for fn, g in gold.items():
        c = cur[fn]
        for field in ("bin", "face_count", "burst_id"):
            if c[field] != g[field]:
                drift.append(f"{fn}.{field}: {g[field]!r} -> {c[field]!r}")
    assert not drift, "behavior changed vs golden:\n" + "\n".join(drift)
