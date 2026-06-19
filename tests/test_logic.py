"""Deterministic unit tests — no photos, no mediapipe. The portable safety net for refactors.

These pin the *logic*: grouping (time + similarity), gate+rank binning, the bias-to-maybe
rule, and manifest/cache behavior. They run anywhere numpy+Pillow are installed.
"""
from datetime import datetime, timedelta

from bestphoto import manifest
from bestphoto.binning import bin_burst
from bestphoto.bursts import Burst, Frame, group_by_similarity, group_into_bursts
from bestphoto.config import Config

T0 = datetime(2026, 6, 19, 12, 0, 0)


def mk(name, t=None, phash=0, faces=0, eye=None, sharp=0.0, exp=False):
    return Frame(path=name, rel=name, when=t, mtime=0.0, size=0,
                 face_count=faces, eye_score=eye, sharpness=sharp, exposure_flag=exp, phash=phash)


# ---- grouping ------------------------------------------------------------

def test_time_grouping_splits_on_gap():
    frames = [mk(f"{i}.jpg", T0 + timedelta(seconds=s)) for i, s in
              enumerate([0.0, 0.07, 0.14, 5.0, 5.07])]
    groups = group_into_bursts(frames, gap_seconds=2.0)
    assert [len(g.frames) for g in groups] == [3, 2]


def test_time_grouping_isolated_singles():
    frames = [mk("a.jpg", T0), mk("b.jpg", T0 + timedelta(seconds=10))]
    groups = group_into_bursts(frames, 2.0)
    assert len(groups) == 2 and all(g.is_single for g in groups)


def test_similarity_groups_near_duplicates():
    frames = [mk("a.jpg", T0, phash=0), mk("b.jpg", T0, phash=1),       # hamming 1 -> same
              mk("c.jpg", T0, phash=(1 << 64) - 1)]                       # far -> split
    groups = group_by_similarity(frames, max_distance=10, time_ceiling=30.0)
    assert [len(g.frames) for g in groups] == [2, 1]


def test_similarity_time_ceiling_splits_identical_look():
    frames = [mk("a.jpg", T0, phash=0), mk("b.jpg", T0 + timedelta(seconds=60), phash=0)]
    groups = group_by_similarity(frames, max_distance=10, time_ceiling=30.0)
    assert len(groups) == 2


# ---- gate + rank ---------------------------------------------------------

def test_portrait_eyes_closed_rejected_even_if_sharper():
    f_open = mk("open.jpg", faces=1, eye=1.0, sharp=100)
    f_shut = mk("shut.jpg", faces=1, eye=0.0, sharp=300)
    bin_burst(Burst(0, [f_open, f_shut]), Config())
    assert f_shut.bin == "rejected" and "eyes" in f_shut.reason
    assert f_open.bin == "keeper"


def test_group_never_hard_gated_on_eyes():
    a = mk("a.jpg", faces=2, eye=1.0, sharp=100)
    b = mk("b.jpg", faces=2, eye=1.0, sharp=200)
    c = mk("c.jpg", faces=2, eye=0.0, sharp=300)   # sharpest but blinking
    bin_burst(Burst(0, [a, b, c]), Config())
    assert b.bin == "keeper"          # best eyes + sharpness
    assert c.bin != "rejected"        # group blink is not a hard reject


def test_single_below_floor_goes_to_maybe_not_rejected():
    f = mk("s.jpg", faces=0, eye=None, sharp=10.0)   # below single_sharpness_floor (50)
    bin_burst(Burst(0, [f]), Config())
    assert f.bin == "maybe"           # uncertain -> surfaced, never buried


def test_clean_single_is_keeper():
    f = mk("s.jpg", faces=1, eye=1.0, sharp=200)
    bin_burst(Burst(0, [f]), Config())
    assert f.bin == "keeper"


def test_much_softer_than_peak_rejected():
    sharp = mk("a.jpg", faces=0, sharp=300)
    soft = mk("b.jpg", faces=0, sharp=50)            # < 0.3 * 300
    bin_burst(Burst(0, [sharp, soft]), Config())
    assert sharp.bin == "keeper" and soft.bin == "rejected"


def test_keep_n_widens_keepers():
    a = mk("a.jpg", faces=0, sharp=300)
    b = mk("b.jpg", faces=0, sharp=250)
    c = mk("c.jpg", faces=0, sharp=240)
    bin_burst(Burst(0, [a, b, c]), Config(keep_per_burst=2))
    assert a.bin == "keeper" and b.bin == "keeper" and c.bin == "maybe"


# ---- manifest / cache ----------------------------------------------------

def test_manifest_roundtrip(tmp_path):
    p = tmp_path / "m.csv"
    manifest.write_manifest(p, [{"rel": "a.jpg", "filename": "a.jpg", "burst_id": 0,
                                 "bin": "keeper", "reason": "x", "sharpness": "1.0"}])
    back = manifest.read_manifest_rows(p)
    assert back[0]["bin"] == "keeper" and back[0]["filename"] == "a.jpg"


def test_cache_tag_isolates_time_and_similarity(tmp_path):
    p = tmp_path / "c.csv"
    w = manifest.CacheWriter(p, resume=False)
    w.append({"rel": "a.jpg", "mtime": 1.0, "size": 10, "gap": "2.0", "sharpness": "5"})
    w.append({"rel": "a.jpg", "mtime": 1.0, "size": 10, "gap": "sim", "sharpness": "9"})
    w.close()
    assert manifest.load_cache(p, "2.0")[("a.jpg", 1.0, 10)]["sharpness"] == "5"
    assert manifest.load_cache(p, "sim")[("a.jpg", 1.0, 10)]["sharpness"] == "9"
