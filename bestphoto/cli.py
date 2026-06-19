"""Command-line entry: `bestphoto score ...` and `bestphoto review ...`."""
from __future__ import annotations

import argparse
from dataclasses import replace
from pathlib import Path

from . import contact, log, pipeline, review
from .config import Config


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="bestphoto",
        description="Burst-aware JPEG culler. Non-destructive: never moves or deletes originals.",
    )
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("-v", "--verbose", action="store_true",
                        help="debug-level logging (per-frame / per-burst / per-bin detail)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("score", parents=[common], help="score photos into a manifest (moves nothing)")
    s.add_argument("source", type=Path, help="root folder of JPEGs (e.g. the NAS mount)")
    s.add_argument("-c", "--config", type=Path, default=None, help="TOML config (see config.example.toml)")
    s.add_argument("-m", "--manifest", type=Path, default=Path("manifest.csv"))
    s.add_argument("--group", choices=["time", "similarity"], default=None,
                   help="grouping strategy (overrides config; default time)")
    s.add_argument("--keep", type=int, default=None, help="keepers per group (overrides config; default 1)")
    s.add_argument("--subject", choices=["auto", "face", "center", "whole"], default="auto",
                   help="subject-region mode for sharpness (default auto: face->centre fallback)")
    s.add_argument("--cache", type=Path, default=Path(".bpp-cache.csv"), help="resumable measurement cache")
    s.add_argument("--no-resume", action="store_true", help="ignore the cache and rescore everything")

    r = sub.add_parser("review", parents=[common], help="stage manifest bins as symlinks for inspection")
    r.add_argument("source", type=Path, help="root the manifest paths are relative to")
    r.add_argument("-m", "--manifest", type=Path, default=Path("manifest.csv"))
    r.add_argument("-o", "--out", type=Path, default=Path("review"), help="keep-folder to stage into")
    r.add_argument("--bins", nargs="+", default=["keeper", "maybe"],
                   choices=["keeper", "maybe", "rejected"], help="which bins to stage")
    r.add_argument("--copy", action="store_true", help="copy instead of symlink")

    c = sub.add_parser("contact", parents=[common], help="build a self-contained HTML contact sheet")
    c.add_argument("source", type=Path, help="root the manifest paths are relative to")
    c.add_argument("-m", "--manifest", type=Path, default=Path("manifest.csv"))
    c.add_argument("-o", "--out", type=Path, default=Path("contact_sheet.html"))
    c.add_argument("--thumb", type=int, default=320, help="thumbnail long edge in px")

    a = ap.parse_args(argv)
    log.configure(verbose=a.verbose)
    if a.cmd == "score":
        cfg = Config.load(a.config)
        if a.keep is not None:
            cfg = replace(cfg, keep_per_burst=a.keep)
        if a.group is not None:
            cfg = replace(cfg, group_method=a.group)
        pipeline.score(a.source, cfg, a.manifest, a.cache,
                       resume=not a.no_resume, subject_mode=a.subject)
    elif a.cmd == "review":
        review.stage(a.manifest, a.source, a.out, bins=tuple(a.bins), use_copy=a.copy)
    elif a.cmd == "contact":
        out = contact.build(a.manifest, a.source, a.out, thumb_px=a.thumb)
        print(out)


if __name__ == "__main__":
    main()
