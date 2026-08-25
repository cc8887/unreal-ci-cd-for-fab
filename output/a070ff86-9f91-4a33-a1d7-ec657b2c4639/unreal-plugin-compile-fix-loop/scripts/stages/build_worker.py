from __future__ import annotations

import argparse
import sys
from pathlib import Path

from common import build_version, notify_ai, read_json, update_state  # pyright: ignore[reportMissingImports]


def run(run_dir: Path, synchronous: bool = False) -> int:
    state = read_json(run_dir / "state.json")
    versions = list(state["params"]["engine_versions"])
    pending = [version for version in versions if not state.get("results", {}).get(version, {}).get("success")]
    update_state(run_dir, status="running", current_stage=2, stage_status="running")
    fatal = None
    try:
        for version in pending:
            state = read_json(run_dir / "state.json")
            results = dict(state.get("results", {}))
            if state["params"].get("dry_run"):
                result = {
                    "version": version, "success": True, "simulated": True,
                    "returncode": 0, "zip_path": None,
                    "zip_validation": {"valid": True, "simulated": True, "errors": []},
                    "error_summary": {},
                }
            else:
                result = build_version(run_dir, state, version, regression=False)
            results[version] = result
            update_state(run_dir, results=results)
    except Exception as exc:
        fatal = str(exc)
        update_state(run_dir, last_error=fatal)
    finally:
        state = read_json(run_dir / "state.json")
        failed = [version for version in versions if not state.get("results", {}).get(version, {}).get("success")]
        if fatal or failed:
            state = update_state(run_dir, status="waiting_ai", current_stage=3,
                                 stage_status="failed" if fatal else "done", failed_versions=failed)
            notify_ai(run_dir, 3, state, synchronous=synchronous)
        else:
            state = update_state(run_dir, status="waiting_ai", current_stage=3,
                                 stage_status="done", failed_versions=[])
            notify_ai(run_dir, 3, state, synchronous=synchronous)
    return 1 if fatal else 0


def main() -> int:
    parser = argparse.ArgumentParser(description="UE 失败版本构建与分类 worker")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--synchronous", action="store_true", help="do not launch a new AI session")
    args = parser.parse_args()
    return run(Path(args.run_dir).resolve(), synchronous=args.synchronous)


if __name__ == "__main__":
    sys.exit(main())
