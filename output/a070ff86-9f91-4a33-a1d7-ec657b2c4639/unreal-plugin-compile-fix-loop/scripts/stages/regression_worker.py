from __future__ import annotations

import argparse
import sys
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parents[2]
if str(SKILL_ROOT) not in sys.path:
    sys.path.insert(0, str(SKILL_ROOT))
from scripts.stages.common import build_version, notify_ai, read_json, update_state  # pyright: ignore[reportMissingImports]


def run(run_dir: Path, synchronous: bool = False) -> int:
    state = read_json(run_dir / "state.json")
    versions = list(state["params"]["engine_versions"])
    update_state(run_dir, status="running", current_stage=4, stage_status="running",
                 regression_results={})
    fatal = None
    try:
        for version in versions:
            state = read_json(run_dir / "state.json")
            results = dict(state.get("regression_results", {}))
            if state["params"].get("dry_run"):
                result = {
                    "version": version, "success": True, "simulated": True,
                    "returncode": 0, "zip_path": None,
                    "zip_validation": {"valid": True, "simulated": True, "errors": []},
                    "error_summary": {},
                }
            else:
                result = build_version(run_dir, state, version, regression=True)
            results[version] = result
            update_state(run_dir, regression_results=results)
    except Exception as exc:
        fatal = str(exc)
        update_state(run_dir, last_error=fatal)
    finally:
        state = read_json(run_dir / "state.json")
        results = state.get("regression_results", {})
        failed = [version for version in versions if not results.get(version, {}).get("success")]
        if fatal or failed:
            merged = dict(state.get("results", {}))
            merged.update(results)
            state = update_state(run_dir, status="waiting_ai", current_stage=3,
                                 stage_status="failed", results=merged, failed_versions=failed)
            notify_ai(run_dir, 3, state, synchronous=synchronous)
        else:
            state = update_state(run_dir, status="waiting_ai", current_stage=5,
                                 stage_status="done", failed_versions=[], matrix_verified=True)
            notify_ai(run_dir, 5, state, synchronous=synchronous)
    return 1 if fatal else 0


def main() -> int:
    parser = argparse.ArgumentParser(description="UE 全矩阵回归与 ZIP 核验 worker")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--synchronous", action="store_true", help="do not launch a new AI session")
    args = parser.parse_args()
    return run(Path(args.run_dir).resolve(), synchronous=args.synchronous)


if __name__ == "__main__":
    sys.exit(main())
