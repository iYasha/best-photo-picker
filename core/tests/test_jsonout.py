"""The `score --json` machine contract (ADR 0008): shape, key/type discipline, and the
core->wire field mapping. Deterministic — no photos, no mediapipe (synthetic JPEGs + a fake
detector at score()'s seam, the same pattern as test_logic.py), so it runs in the fast suite.

Pins the wire so the Swift Codable side (Core/ScoreContract.swift) keeps decoding it: every
key is snake_case, marks/exposure use the exact lowercase raw strings, sharpness is a 0..99
int, eyes is an int-percent-or-null, and the final doc is distinguishable from progress lines.
"""
import io
import json
from datetime import datetime

from PIL import Image

from bestphoto import jsonout, manifest
from bestphoto.binning import Verdict
from bestphoto.bursts import Burst, Frame, Measurement
from bestphoto.config import Config
from bestphoto.detect import Face

# Reuse the synthetic-photo + fake-detector seam the logic tests use.
from tests.test_logic import FakeDetector, _make_jpeg


def mk(rel, when=None, faces=0, eye=None, sharp=0.0, exp=False, blown=0.0, crushed=0.0, size=0):
    return Frame(path=rel, rel=rel, when=when, mtime=0.0, size=size,
                 m=Measurement(face_count=faces, eye_score=eye, sharpness=sharp,
                               exposure_flag=exp, blown=blown, crushed=crushed))


# ---- pure field-mapping units (no I/O) -----------------------------------

def test_frame_id_is_stable_and_path_derived():
    # Same rel path -> same id, regardless of which burst it lands in (survives a regroup).
    assert jsonout.frame_id("DCIM/a/IMG_1.jpg") == jsonout.frame_id("DCIM/a/IMG_1.jpg")
    assert jsonout.frame_id("DCIM/a/IMG_1.jpg") != jsonout.frame_id("DCIM/a/IMG_2.jpg")


def test_normalize_sharpness_scales_peak_to_99_and_floor_to_zero():
    assert jsonout.normalize_sharpness(300.0, peak=300.0) == 99
    assert jsonout.normalize_sharpness(0.0, peak=300.0) == 0
    assert jsonout.normalize_sharpness(150.0, peak=300.0) == 50  # round(99*0.5)=50
    assert jsonout.normalize_sharpness(10.0, peak=0.0) == 0      # no div-by-zero


def test_exposure_label_picks_dominant_clip_only_when_flagged():
    assert jsonout.exposure_label(mk("a", exp=False, blown=0.9)) == "ok"   # not flagged -> ok
    assert jsonout.exposure_label(mk("a", exp=True, blown=0.3, crushed=0.1)) == "blown"
    assert jsonout.exposure_label(mk("a", exp=True, blown=0.05, crushed=0.4)) == "crushed"


# ---- build_result: structure + ordering ----------------------------------

def _result_from_frames(frames, cfg=None, gid=0, method="similarity"):
    cfg = cfg or Config(group_method=method)
    return jsonout.build_result([Burst(gid, frames)], cfg)


def test_build_result_top_level_shape():
    r = _result_from_frames([mk("a.jpg", faces=0, sharp=100.0)])
    assert set(r) == {"grouping", "bursts"}
    assert r["grouping"] == "similarity"
    b = r["bursts"][0]
    assert set(b) == {"id", "label", "time", "faces", "keeper_id", "frames"}


def test_build_result_burst_id_prefixed_by_method():
    assert _result_from_frames([mk("a.jpg")], method="time", gid=3)["bursts"][0]["id"] == "t3"
    assert _result_from_frames([mk("a.jpg")], method="similarity", gid=3)["bursts"][0]["id"] == "s3"


def test_build_result_frames_sorted_keeper_first_then_desc_sharpness():
    soft = mk("soft.jpg", faces=0, sharp=50.0)
    sharp = mk("sharp.jpg", faces=0, sharp=300.0)
    mid = mk("mid.jpg", faces=0, sharp=200.0)
    r = _result_from_frames([soft, sharp, mid])
    b = r["bursts"][0]
    order = [f["filename"] for f in b["frames"]]
    assert order == ["sharp.jpg", "mid.jpg", "soft.jpg"]   # keeper (sharpest) first
    assert b["frames"][0]["mark"] == "keeper"
    assert b["keeper_id"] == b["frames"][0]["id"]
    # sharpness normalized: sharpest -> 99
    assert b["frames"][0]["sharpness"] == 99


def test_build_result_frame_field_keys_and_types():
    f = mk("DCIM/x/IMG_9.jpg", faces=1, eye=0.97, sharp=300.0, exp=True, crushed=0.4, size=1234)
    fr = _result_from_frames([f])["bursts"][0]["frames"][0]
    assert set(fr) == {"id", "filename", "sharpness", "eyes", "faces", "exposure",
                       "mark", "reason", "size_bytes", "rel_path"}
    assert fr["filename"] == "IMG_9.jpg"
    assert fr["rel_path"] == "DCIM/x/IMG_9.jpg"
    assert fr["id"] == jsonout.frame_id("DCIM/x/IMG_9.jpg")
    assert fr["eyes"] == 97 and isinstance(fr["eyes"], int)
    assert fr["faces"] == 1
    assert fr["exposure"] == "crushed"
    assert fr["size_bytes"] == 1234
    assert isinstance(fr["sharpness"], int) and 0 <= fr["sharpness"] <= 99
    assert fr["mark"] in ("keeper", "maybe", "rejected")


def test_build_result_eyes_null_when_no_face():
    fr = _result_from_frames([mk("a.jpg", faces=0, sharp=100.0)])["bursts"][0]["frames"][0]
    assert fr["eyes"] is None
    assert _result_from_frames([mk("a.jpg", faces=0)])["bursts"][0]["faces"] is False


def test_build_result_faces_true_when_any_frame_has_a_face():
    r = _result_from_frames([mk("a.jpg", faces=1, eye=0.9, sharp=200.0)])
    assert r["bursts"][0]["faces"] is True


def test_labels_disambiguate_bursts_sharing_a_second():
    when = datetime(2026, 6, 19, 7, 42, 11)
    g0 = Burst(0, [mk("a.jpg", when=when, sharp=10.0)])
    g1 = Burst(1, [mk("b.jpg", when=when, sharp=10.0)])
    r = jsonout.build_result([g0, g1], Config(group_method="similarity"))
    labels = [b["label"] for b in r["bursts"]]
    assert labels == ["07:42:11 · group 1", "07:42:11 · group 2"]
    assert r["bursts"][0]["time"] == "07:42:11"


def test_undated_burst_time_is_placeholder():
    r = _result_from_frames([mk("a.jpg", when=None, sharp=10.0)])
    assert r["bursts"][0]["time"] == "--:--:--"


# ---- progress lines + wire disambiguation --------------------------------

def test_progress_line_keys():
    line = json.loads(jsonout.progress_line(3, 10, "IMG_1.jpg", "Heron"))
    assert set(line) == {"done", "total", "current_frame_name", "current_burst_label"}
    assert line == {"done": 3, "total": 10, "current_frame_name": "IMG_1.jpg",
                    "current_burst_label": "Heron"}


def test_progress_and_result_are_distinguishable_on_the_wire():
    # The contract: progress objects carry "done"; the final doc carries "grouping", not "done".
    prog = json.loads(jsonout.progress_line(1, 2, "a.jpg", "L"))
    result = _result_from_frames([mk("a.jpg", sharp=10.0)])
    assert jsonout.PROGRESS_KEY in prog and jsonout.RESULT_KEY not in prog
    assert jsonout.RESULT_KEY in result and jsonout.PROGRESS_KEY not in result


def test_emit_streams_progress_then_result_as_jsonlines():
    frames = [mk("a.jpg", faces=0, sharp=300.0), mk("b.jpg", faces=0, sharp=50.0)]
    groups = [Burst(0, frames)]
    cfg = Config(group_method="similarity")
    buf = io.StringIO()
    jsonout.emit_progress(groups, cfg, stream=buf)
    jsonout.emit_result(jsonout.build_result(groups, cfg), stream=buf)

    lines = [json.loads(ln) for ln in buf.getvalue().splitlines() if ln.strip()]
    progress = [ln for ln in lines if jsonout.PROGRESS_KEY in ln]
    final = [ln for ln in lines if jsonout.RESULT_KEY in ln]
    assert len(progress) == 2                      # one per frame
    assert progress[-1]["done"] == progress[-1]["total"] == 2
    assert len(final) == 1 and final[0] is lines[-1]   # final doc is the LAST line


# ---- end-to-end through score_to_json (synthetic photo + fake detector) ---

def test_score_to_json_streams_one_progress_line_per_frame(tmp_path):
    # Live progress: Scorer.run fires on_progress per frame, so score_to_json emits one
    # progress line per frame (ending at done==total) BEFORE the final result doc — not a
    # post-hoc replay. Regression for the "bar stuck at 0% then jumps to 100%" bug.
    for i in range(3):
        _make_jpeg(tmp_path / f"p{i}.jpg")
    buf = io.StringIO()
    jsonout.score_to_json(
        tmp_path, Config(group_method="similarity"), tmp_path / "m.csv",
        tmp_path / "cache.csv", resume=False, subject_mode="auto",
        detector=FakeDetector([]), stream=buf,
    )
    lines = [json.loads(ln) for ln in buf.getvalue().splitlines() if ln.strip()]
    progress = [ln for ln in lines if jsonout.PROGRESS_KEY in ln]
    assert len(progress) == 3                          # one per frame, via the live callback
    assert progress[-1]["done"] == progress[-1]["total"] == 3
    assert jsonout.RESULT_KEY in lines[-1]             # final doc still emitted last


def test_score_to_json_writes_manifest_and_emits_contract(tmp_path):
    _make_jpeg(tmp_path / "p.jpg")
    m = tmp_path / "manifest.csv"
    buf = io.StringIO()
    result = jsonout.score_to_json(
        tmp_path, Config(group_method="time"), m, tmp_path / "cache.csv",
        resume=False, subject_mode="auto",
        detector=FakeDetector([Face(box=(0.25, 0.25, 0.5, 0.5), area=0.25, open_prob=1.0)]),
        stream=buf,
    )
    # CSV manifest still written and readable (ADR 0001).
    rows = manifest.read_manifest(m)
    assert len(rows) == 1 and rows[0].filename == "p.jpg"

    # stdout carried valid JSON-lines ending in the final result doc.
    lines = [json.loads(ln) for ln in buf.getvalue().splitlines() if ln.strip()]
    assert jsonout.RESULT_KEY in lines[-1]
    assert lines[-1] == result
    assert result["grouping"] == "time"
    fr = result["bursts"][0]["frames"][0]
    assert fr["filename"] == "p.jpg" and fr["faces"] == 1 and fr["eyes"] == 100
