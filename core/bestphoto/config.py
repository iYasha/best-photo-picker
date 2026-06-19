"""Tunable thresholds, loaded from a TOML file (see config.example.toml).

A pydantic-settings model: defaults live here, a TOML file overrides them
(``Config.load``), and any field can also be overridden from the environment
with the ``BPP_`` prefix (e.g. ``BPP_GAP_SECONDS=3``). Frozen — replace a field
with ``cfg.model_copy(update={...})``.
"""
from __future__ import annotations

from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:  # pragma: no cover
    tomllib = None


class Config(BaseSettings):
    model_config = SettingsConfigDict(frozen=True, env_prefix="BPP_")

    group_method: str = "time"      # "time" (capture-gap bursts) or "similarity" (near-duplicate)
    gap_seconds: float = 2.0
    sim_max_distance: int = 10      # similarity: max perceptual-hash Hamming distance within a group
    sim_time_ceiling: float = 30.0  # similarity: always split across gaps larger than this (seconds)
    phash_size: int = 8             # similarity: dHash grid (8 -> 64-bit hash)
    keep_per_burst: int = 1
    downscale_long_edge: int = 1280
    max_faces: int = 6
    min_face_frac: float = 0.005   # absolute floor: ignore faces below this fraction of the frame
    foreground_ratio: float = 0.6  # keep faces >= this fraction of the largest face's area
    yunet_score: float = 0.6       # YuNet detection confidence threshold
    eye_open_min: float = 0.50   # per-face open_prob (1 - blink) at/above this counts as open
    open_gate: float = 0.50      # size-weighted open fraction below this fails the portrait gate
    blown_value: int = 250
    blown_frac: float = 0.10
    crushed_value: int = 5
    crushed_frac: float = 0.20
    reject_sharpness_ratio: float = 0.30
    single_sharpness_floor: float = 50.0

    @classmethod
    def load(cls, path: "Path | None") -> "Config":
        if path is None:
            return cls()
        if tomllib is None:
            raise RuntimeError("Need Python 3.11+ (tomllib) to read a config file.")
        data = tomllib.loads(Path(path).read_text())
        group = data.get("group", {})
        burst = data.get("burst", {})
        select = data.get("select", {})
        detect = data.get("detect", {})
        eyes = data.get("eyes", {})
        exp = data.get("exposure", {})
        rej = data.get("reject", {})
        # Flatten the TOML sections onto the flat field set; omit absent keys so
        # field defaults (and any BPP_ env overrides) still apply.
        flat = {
            "group_method": group.get("method"),
            "gap_seconds": burst.get("gap_seconds"),
            "sim_max_distance": group.get("sim_max_distance"),
            "sim_time_ceiling": group.get("sim_time_ceiling"),
            "phash_size": group.get("phash_size"),
            "keep_per_burst": select.get("keep_per_burst"),
            "downscale_long_edge": detect.get("downscale_long_edge"),
            "max_faces": detect.get("max_faces"),
            "min_face_frac": detect.get("min_face_frac"),
            "foreground_ratio": detect.get("foreground_ratio"),
            "yunet_score": detect.get("yunet_score"),
            "eye_open_min": eyes.get("eye_open_min"),
            "open_gate": eyes.get("open_gate"),
            "blown_value": exp.get("blown_value"),
            "blown_frac": exp.get("blown_frac"),
            "crushed_value": exp.get("crushed_value"),
            "crushed_frac": exp.get("crushed_frac"),
            "reject_sharpness_ratio": rej.get("sharpness_ratio"),
            "single_sharpness_floor": rej.get("single_sharpness_floor"),
        }
        return cls(**{k: v for k, v in flat.items() if v is not None})
