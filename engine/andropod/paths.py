"""Project paths. Single source of truth for where things live."""

from __future__ import annotations

from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
RUNTIME_DIR = PROJECT_ROOT / "runtime"
IMAGES_DIR = RUNTIME_DIR / "images"
INSTANCES_DIR = RUNTIME_DIR / "instances"
LOGS_DIR = RUNTIME_DIR / "logs"


def instance_dir(name: str) -> Path:
    return INSTANCES_DIR / name


def ensure_dirs() -> None:
    for path in (RUNTIME_DIR, IMAGES_DIR, INSTANCES_DIR, LOGS_DIR):
        path.mkdir(parents=True, exist_ok=True)
