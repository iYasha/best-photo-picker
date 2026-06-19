"""structlog setup. INFO by default; verbose flips to DEBUG (per-frame/burst/bin detail)."""
from __future__ import annotations

import logging

import structlog


def configure(verbose: bool = False) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    structlog.configure(
        wrapper_class=structlog.make_filtering_bound_logger(level),
        processors=[
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="%H:%M:%S"),
            structlog.dev.ConsoleRenderer(),
        ],
        cache_logger_on_first_use=True,
    )


def get_logger(name: str = "bestphoto"):
    return structlog.get_logger(name)
