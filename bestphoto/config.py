"""Tunable thresholds, loaded from a TOML file (see config.example.toml)."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:  # pragma: no cover
    tomllib = None


@dataclass(frozen=True)
class Config:
    gap_seconds: float = 2.0
    keep_per_burst: int = 1
    downscale_long_edge: int = 1280
    max_faces: int = 6
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
        burst = data.get("burst", {})
        select = data.get("select", {})
        detect = data.get("detect", {})
        eyes = data.get("eyes", {})
        exp = data.get("exposure", {})
        rej = data.get("reject", {})
        d = cls()  # defaults
        return cls(
            gap_seconds=burst.get("gap_seconds", d.gap_seconds),
            keep_per_burst=select.get("keep_per_burst", d.keep_per_burst),
            downscale_long_edge=detect.get("downscale_long_edge", d.downscale_long_edge),
            max_faces=detect.get("max_faces", d.max_faces),
            eye_open_min=eyes.get("eye_open_min", d.eye_open_min),
            open_gate=eyes.get("open_gate", d.open_gate),
            blown_value=exp.get("blown_value", d.blown_value),
            blown_frac=exp.get("blown_frac", d.blown_frac),
            crushed_value=exp.get("crushed_value", d.crushed_value),
            crushed_frac=exp.get("crushed_frac", d.crushed_frac),
            reject_sharpness_ratio=rej.get("sharpness_ratio", d.reject_sharpness_ratio),
            single_sharpness_floor=rej.get("single_sharpness_floor", d.single_sharpness_floor),
        )
