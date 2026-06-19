"""Command-line entry: `bestphoto score | review | contact` (click)."""
from __future__ import annotations

from pathlib import Path

import click

from . import contact, log, pipeline, review
from .config import Config

_PATH = click.Path(path_type=Path)


def _verbose(f):
    """Shared -v/--verbose flag + logging setup, applied per subcommand."""
    return click.option(
        "-v", "--verbose", is_flag=True,
        help="debug-level logging (per-frame / per-burst / per-bin detail)",
        callback=lambda ctx, param, value: log.configure(verbose=value),
        expose_value=False,
    )(f)


@click.group(help="Burst-aware JPEG culler. Non-destructive: never moves or deletes originals.")
def main():
    pass


@main.command(help="score photos into a manifest (moves nothing)")
@click.argument("source", type=_PATH)
@click.option("-c", "--config", "config_path", type=_PATH, default=None,
              help="TOML config (see config.example.toml)")
@click.option("-m", "--manifest", type=_PATH, default=Path("manifest.csv"))
@click.option("--group", type=click.Choice(["time", "similarity"]), default=None,
              help="grouping strategy (overrides config; default time)")
@click.option("--keep", type=int, default=None, help="keepers per group (overrides config; default 1)")
@click.option("--subject", type=click.Choice(["auto", "face", "center", "whole"]), default="auto",
              help="subject-region mode for sharpness (default auto: face->centre fallback)")
@click.option("--cache", type=_PATH, default=Path(".bpp-cache.csv"), help="resumable measurement cache")
@click.option("--no-resume", is_flag=True, help="ignore the cache and rescore everything")
@_verbose
def score(source, config_path, manifest, group, keep, subject, cache, no_resume):
    cfg = Config.load(config_path)
    overrides = {}
    if keep is not None:
        overrides["keep_per_burst"] = keep
    if group is not None:
        overrides["group_method"] = group
    if overrides:
        cfg = cfg.model_copy(update=overrides)
    pipeline.score(source, cfg, manifest, cache, resume=not no_resume, subject_mode=subject)


@main.command("review", help="stage manifest bins as symlinks for inspection")
@click.argument("source", type=_PATH)
@click.option("-m", "--manifest", type=_PATH, default=Path("manifest.csv"))
@click.option("-o", "--out", type=_PATH, default=Path("review"), help="keep-folder to stage into")
@click.option("--bins", multiple=True, default=("keeper", "maybe"),
              type=click.Choice(["keeper", "maybe", "rejected"]), help="which bins to stage")
@click.option("--copy", "use_copy", is_flag=True, help="copy instead of symlink")
@_verbose
def review_cmd(source, manifest, out, bins, use_copy):
    review.stage(manifest, source, out, bins=tuple(bins), use_copy=use_copy)


@main.command("contact", help="build a self-contained HTML contact sheet")
@click.argument("source", type=_PATH)
@click.option("-m", "--manifest", type=_PATH, default=Path("manifest.csv"))
@click.option("-o", "--out", type=_PATH, default=Path("contact_sheet.html"))
@click.option("--thumb", type=int, default=320, help="thumbnail long edge in px")
@_verbose
def contact_cmd(source, manifest, out, thumb):
    click.echo(contact.build(manifest, source, out, thumb_px=thumb))


if __name__ == "__main__":
    main()
