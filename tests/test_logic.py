"""Deterministic unit tests — no photos, no mediapipe. The portable safety net for refactors.

These pin the *logic*: grouping (time + similarity), gate+rank binning, the bias-to-maybe
rule, and manifest/cache behavior. They run anywhere numpy+Pillow are installed.
"""
from datetime import datetime, timedelta

from PIL import Image

from bestphoto import manifest
from bestphoto.binning import bin_burst
from bestphoto.bursts import Burst, Frame, SimilarityGrouping, TimeGrouping
from bestphoto.config import Config
from bestphoto.detect import Face
from bestphoto.pipeline import score

T0 = datetime(2026, 6, 19, 12, 0, 0)


def mk(name, t=None, phash=0, faces=0, eye=None, sharp=0.0, exp=False):
    return Frame(path=name, rel=name, when=t, mtime=0.0, size=0,
                 face_count=faces, eye_score=eye, sharpness=sharp, exposure_flag=exp, phash=phash)


class FakeDetector:
    """Stands in for a real FaceDetector at score()'s seam — returns canned faces for every
    frame, no models. The seam is what makes this possible: no monkeypatching, no mediapipe."""

    available = True
    eyes_available = True

    def __init__(self, faces):
        self._faces = faces

    def faces(self, rgb):
        return list(self._faces)


def _make_jpeg(path):
    Image.new("RGB", (64, 64), (128, 128, 128)).save(path, "JPEG")  # flat mid-grey: no exposure flag


# ---- grouping (through the strategy seam) --------------------------------

def test_time_grouping_splits_on_gap():
    frames = [mk(f"{i}.jpg", T0 + timedelta(seconds=s)) for i, s in
              enumerate([0.0, 0.07, 0.14, 5.0, 5.07])]
    groups = TimeGrouping(Config(gap_seconds=2.0)).group(frames)
    assert [len(g.frames) for g in groups] == [3, 2]


def test_time_grouping_isolated_singles():
    frames = [mk("a.jpg", T0), mk("b.jpg", T0 + timedelta(seconds=10))]
    groups = TimeGrouping(Config(gap_seconds=2.0)).group(frames)
    assert len(groups) == 2 and all(g.is_single for g in groups)


def test_similarity_groups_near_duplicates():
    frames = [mk("a.jpg", T0, phash=0), mk("b.jpg", T0, phash=1),       # hamming 1 -> same
              mk("c.jpg", T0, phash=(1 << 64) - 1)]                       # far -> split
    groups = SimilarityGrouping(Config(sim_max_distance=10, sim_time_ceiling=30.0)).group(frames)
    assert [len(g.frames) for g in groups] == [2, 1]


def test_similarity_time_ceiling_splits_identical_look():
    frames = [mk("a.jpg", T0, phash=0), mk("b.jpg", T0 + timedelta(seconds=60), phash=0)]
    groups = SimilarityGrouping(Config(sim_max_distance=10, sim_time_ceiling=30.0)).group(frames)
    assert len(groups) == 2


# ---- gate + rank ---------------------------------------------------------

def test_portrait_eyes_closed_rejected_even_if_sharper():
    f_open = mk("open.jpg", faces=1, eye=1.0, sharp=100)
    f_shut = mk("shut.jpg", faces=1, eye=0.0, sharp=300)
    v = bin_burst(Burst(0, [f_open, f_shut]), Config())
    assert v[f_shut].bin == "rejected" and "eyes" in v[f_shut].reason
    assert v[f_open].bin == "keeper"


def test_group_never_hard_gated_on_eyes():
    a = mk("a.jpg", faces=2, eye=1.0, sharp=100)
    b = mk("b.jpg", faces=2, eye=1.0, sharp=200)
    c = mk("c.jpg", faces=2, eye=0.0, sharp=300)   # sharpest but blinking
    v = bin_burst(Burst(0, [a, b, c]), Config())
    assert v[b].bin == "keeper"          # best eyes + sharpness
    assert v[c].bin != "rejected"        # group blink is not a hard reject


def test_single_below_floor_goes_to_maybe_not_rejected():
    f = mk("s.jpg", faces=0, eye=None, sharp=10.0)   # below single_sharpness_floor (50)
    v = bin_burst(Burst(0, [f]), Config())
    assert v[f].bin == "maybe"           # uncertain -> surfaced, never buried


def test_clean_single_is_keeper():
    f = mk("s.jpg", faces=1, eye=1.0, sharp=200)
    v = bin_burst(Burst(0, [f]), Config())
    assert v[f].bin == "keeper"


def test_much_softer_than_peak_rejected():
    sharp = mk("a.jpg", faces=0, sharp=300)
    soft = mk("b.jpg", faces=0, sharp=50)            # < 0.3 * 300
    v = bin_burst(Burst(0, [sharp, soft]), Config())
    assert v[sharp].bin == "keeper" and v[soft].bin == "rejected"


def test_keep_n_widens_keepers():
    a = mk("a.jpg", faces=0, sharp=300)
    b = mk("b.jpg", faces=0, sharp=250)
    c = mk("c.jpg", faces=0, sharp=240)
    v = bin_burst(Burst(0, [a, b, c]), Config(keep_per_burst=2))
    assert v[a].bin == "keeper" and v[b].bin == "keeper" and v[c].bin == "maybe"


# ---- manifest / cache ----------------------------------------------------

def test_manifest_roundtrip(tmp_path):
    p = tmp_path / "m.csv"
    manifest.write_manifest(p, [{"rel": "a.jpg", "filename": "a.jpg", "burst_id": 0,
                                 "bin": "keeper", "reason": "x", "sharpness": "1.0"}])
    back = manifest.read_manifest_rows(p)
    assert back[0]["bin"] == "keeper" and back[0]["filename"] == "a.jpg"


# ---- score seam (FaceDetector injection) --------------------------------

def _score_one(tmp_path, face):
    """Score a single synthetic photo through score() with an injected FakeDetector;
    return that photo's manifest row."""
    _make_jpeg(tmp_path / "p.jpg")
    m = tmp_path / "manifest.csv"
    score(tmp_path, Config(), m, tmp_path / "cache.csv",
          resume=False, detector=FakeDetector([face]))
    return {r["filename"]: r for r in manifest.read_manifest_rows(m)}["p.jpg"]


def test_facedetector_composes_locator_and_eyes():
    """The facade pairs each located box with the eye-reader's open_prob. The split seam lets
    us exercise composition (and eye-reading) with no YuNet, no mediapipe, no photo."""
    from bestphoto.detect import FaceDetector

    class FakeLocator:
        available = True
        def locate(self, rgb):
            return [((0.1, 0.1, 0.2, 0.2), 0.04, (10, 10, 20, 20))]

    class FakeEyes:
        available = True
        def open_prob(self, rgb, box_px):
            assert box_px == (10, 10, 20, 20)   # facade hands the pixel box straight through
            return 0.25

    det = FaceDetector(Config(), locator=FakeLocator(), eyes=FakeEyes())
    faces = det.faces(rgb=None)
    assert det.available and det.eyes_available
    assert len(faces) == 1
    assert faces[0].box == (0.1, 0.1, 0.2, 0.2)
    assert faces[0].area == 0.04
    assert faces[0].open_prob == 0.25


def test_score_gates_closed_eye_portrait(tmp_path):
    row = _score_one(tmp_path, Face(box=(0.25, 0.25, 0.5, 0.5), area=0.25, open_prob=0.0))
    assert row["bin"] == "rejected" and "eyes" in row["reason"]
    assert row["face_count"] == "1"


def test_score_open_eye_portrait_not_rejected(tmp_path):
    row = _score_one(tmp_path, Face(box=(0.25, 0.25, 0.5, 0.5), area=0.25, open_prob=1.0))
    assert row["bin"] != "rejected"     # eyes open -> gate passes; injected open_prob flows through


def _cache_frame(sharp):
    f = mk("a.jpg", T0, sharp=sharp)
    f.mtime, f.size = 1.0, 10
    return f


def test_cache_tag_isolates_time_and_similarity(tmp_path):
    """Same key, two grouping tags -> two independent rows; each tag's view restores only its
    own measurement. Drives the MeasurementCache round-trip end to end."""
    p = tmp_path / "c.csv"
    with manifest.MeasurementCache(p, tag="2.0", resume=False) as c:
        c.put(_cache_frame(5.0))
    with manifest.MeasurementCache(p, tag="sim", resume=True) as c:    # appends, shares the file
        c.put(_cache_frame(9.0))

    t = _cache_frame(0.0)
    with manifest.MeasurementCache(p, tag="2.0", resume=True) as c:
        assert c.fill(t) and c.has(t)
    assert t.sharpness == 5.0

    s = _cache_frame(0.0)
    with manifest.MeasurementCache(p, tag="sim", resume=True) as c:
        assert c.fill(s)
    assert s.sharpness == 9.0
