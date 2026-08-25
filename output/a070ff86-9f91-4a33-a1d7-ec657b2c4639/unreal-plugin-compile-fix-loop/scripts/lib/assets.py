from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def skill_root() -> Path:
    return Path(__file__).resolve().parents[2]


def load_error_rules() -> dict[str, Any]:
    path = skill_root() / "assets" / "error-rules.json"
    return json.loads(path.read_text(encoding="utf-8-sig"))


def render_repair_prompt(values: dict[str, str]) -> str:
    path = skill_root() / "assets" / "repair_prompt.md"
    text = path.read_text(encoding="utf-8-sig")
    for key, value in values.items():
        text = text.replace("${" + key + "}", value)
    return text
