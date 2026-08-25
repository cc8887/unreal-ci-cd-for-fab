from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_ROOT = SCRIPT_DIR.parent
STAGES_DIR = SCRIPT_DIR / "stages"
STATE_ROOT = SKILL_ROOT / ".run_state"
ACTIVE_RUN = STATE_ROOT / "active_run.json"
if str(STAGES_DIR) not in sys.path:
    sys.path.insert(0, str(STAGES_DIR))
from common import notify_ai, read_json, update_state, utc_now, write_json  # pyright: ignore[reportMissingImports]

DEFAULT_VERSIONS = ["4.27", "5.0", "5.1", "5.2", "5.3", "5.4", "5.5", "5.6", "5.7", "5.8"]
DEFAULT_PIPELINE = Path.cwd()
ALLOWED_ACTIONS = {"retry", "regression", "stop"}
AI_HANDOFF = 20
WORKER_STARTED = 21


def load_params(raw: str) -> dict[str, Any]:
    candidate = Path(raw).expanduser()
    if not candidate.is_file():
        raise ValueError("--params must name an existing UTF-8 JSON file; inline JSON is forbidden")
    try:
        value = json.loads(candidate.read_text(encoding="utf-8-sig"))
    except UnicodeDecodeError as exc:
        raise ValueError("--params file must be UTF-8") from exc
    if not isinstance(value, dict):
        raise ValueError("--params top level must be a JSON object")
    return value


def normalize_params(raw: dict[str, Any]) -> dict[str, Any]:
    pipeline = Path(str(raw.get("pipeline_repo", DEFAULT_PIPELINE))).expanduser().resolve()
    config = Path(str(raw.get("config_path", pipeline / "config.json"))).expanduser().resolve()
    plugin_value = raw.get("plugin_repo")
    if not plugin_value and config.is_file():
        plugin_value = read_json(config).get("PluginSourceDirectory")
    plugin = Path(str(plugin_value or pipeline)).expanduser().resolve()
    versions = raw.get("engine_versions", DEFAULT_VERSIONS)
    if not isinstance(versions, list) or not versions or not all(isinstance(item, str) and item.strip() for item in versions):
        raise ValueError("engine_versions must be a non-empty string array")
    versions = list(dict.fromkeys(item.strip() for item in versions))
    max_rounds = raw.get("max_repair_rounds", 3)
    if isinstance(max_rounds, bool) or not isinstance(max_rounds, int) or max_rounds < 0:
        raise ValueError("max_repair_rounds must be a non-negative integer")
    dry_run = raw.get("dry_run", False)
    if not isinstance(dry_run, bool):
        raise ValueError("dry_run must be boolean")
    wait_for_completion = raw.get("wait_for_completion", True)
    if not isinstance(wait_for_completion, bool):
        raise ValueError("wait_for_completion must be boolean")
    params = {"pipeline_repo": str(pipeline), "plugin_repo": str(plugin), "config_path": str(config),
              "engine_versions": versions, "max_repair_rounds": max_rounds, "dry_run": dry_run,
              "wait_for_completion": wait_for_completion}
    validate_paths(params)
    return params


def validate_paths(params: dict[str, Any]) -> None:
    pipeline = Path(params["pipeline_repo"])
    config = Path(params["config_path"])
    plugin = Path(params["plugin_repo"])
    if not pipeline.is_dir():
        raise ValueError(f"pipeline_repo does not exist: {pipeline}")
    if not (pipeline / "Tools" / "package_plugin.ps1").is_file():
        raise ValueError(f"Tools/package_plugin.ps1 is missing: {pipeline}")
    if not config.is_file():
        raise ValueError(f"config_path does not exist: {config}")
    if not plugin.is_dir():
        raise ValueError(f"plugin_repo does not exist: {plugin}")
    if not params["dry_run"] and os.name != "nt":
        raise ValueError("real Unreal builds require Windows")


def params_fingerprint(params: dict[str, Any]) -> str:
    stable = json.dumps(params, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(stable.encode("utf-8")).hexdigest()[:12]


def assert_safe_run_dir(run_dir: Path) -> Path:
    root = STATE_ROOT.resolve()
    resolved = run_dir.resolve()
    if resolved == root or root not in resolved.parents:
        raise RuntimeError("run directory must be below this skill's .run_state")
    return resolved


def set_active_run(run_dir: Path) -> None:
    safe = assert_safe_run_dir(run_dir)
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    write_json(ACTIVE_RUN, {"run_dir": str(safe.relative_to(STATE_ROOT.resolve()))})


def get_active_run() -> Path:
    if not ACTIVE_RUN.is_file():
        raise FileNotFoundError("no active run; first invocation requires --params")
    pointer = read_json(ACTIVE_RUN).get("run_dir")
    if not isinstance(pointer, str) or not pointer.strip():
        raise ValueError("active_run.json has no safe run_dir pointer")
    candidate = Path(pointer)
    safe = assert_safe_run_dir(candidate if candidate.is_absolute() else STATE_ROOT / candidate)
    if not (safe / "state.json").is_file():
        raise FileNotFoundError(f"active state does not exist: {safe}")
    return safe


def new_run_directory(params: dict[str, Any]) -> Path:
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    prefix = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    return assert_safe_run_dir(STATE_ROOT / f"{prefix}-{params_fingerprint(params)}")


def initialize(run_dir: Path, params: dict[str, Any]) -> dict[str, Any]:
    run_dir.mkdir(parents=True, exist_ok=False)
    state = {"schema_version": 2, "run_id": run_dir.name, "status": "waiting_ai", "current_stage": 1,
             "stage_status": "ready", "repair_round": 0, "matrix_verified": False, "params": params,
             "results": {}, "regression_results": {}, "created_at": utc_now(), "updated_at": utc_now(),
             "git_actions": {"commit": False, "push": False}}
    write_json(run_dir / "state.json", state)
    set_active_run(run_dir)
    notify_ai(run_dir, 1, state)
    return state


def consume_ai_output(run_dir: Path, state: dict[str, Any]) -> dict[str, Any] | None:
    stage = int(state["current_stage"])
    if stage not in (1, 3, 5):
        return state
    output_path = run_dir / f"stage_{stage:02d}_output.json"
    if not output_path.is_file():
        return None
    output = read_json(output_path)
    action = output.get("action")
    if action not in ALLOWED_ACTIONS:
        raise ValueError(f"AI action must be one of {sorted(ALLOWED_ACTIONS)}")
    summary = output.get("summary")
    if not isinstance(summary, str) or not summary.strip():
        raise ValueError("AI output requires a non-empty summary")
    changed = output.get("changed_files", [])
    if not isinstance(changed, list) or not all(isinstance(item, str) for item in changed):
        raise ValueError("changed_files must be a string array")
    consumed_dir = run_dir / "consumed"
    consumed_dir.mkdir(exist_ok=True)
    archive = consumed_dir / f"stage_{stage:02d}_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')}.json"
    shutil.move(str(output_path), archive)
    history = list(state.get("ai_history", []))
    history.append({"stage": stage, "action": action, "summary": summary, "changed_files": changed,
                    "verdict": output.get("verdict"), "consumed_at": utc_now(), "archive": str(archive)})
    return update_state(run_dir, ai_history=history, stage_status="done")


def invoke_worker(run_dir: Path, filename: str, dry_run: bool, wait_for_completion: bool | None = None) -> int:
    state = read_json(run_dir / "state.json")
    wait = state["params"].get("wait_for_completion", True) if wait_for_completion is None else wait_for_completion
    command = [sys.executable, str(STAGES_DIR / filename), "--run-dir", str(run_dir)]
    if wait:
        command.append("--synchronous")
        print(json.dumps({"status": "worker_running", "worker": filename, "run_dir": str(run_dir)}, ensure_ascii=False))
        completed = subprocess.run(command, cwd=str(SKILL_ROOT), shell=False, check=False)
        current = read_json(run_dir / "state.json")
        print(json.dumps({"status": current.get("status"), "stage": current.get("current_stage"),
                          "worker": filename, "worker_returncode": completed.returncode,
                          "run_dir": str(run_dir)}, ensure_ascii=False))
        if completed.returncode == 0 and current.get("status") == "waiting_ai":
            return AI_HANDOFF
        return completed.returncode or 2
    logs_dir = run_dir / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    log = open(logs_dir / f"{Path(filename).stem}_launcher.log", "ab", buffering=0)
    kwargs: dict[str, Any] = {"cwd": str(SKILL_ROOT), "stdin": subprocess.DEVNULL, "stdout": log,
                              "stderr": subprocess.STDOUT, "shell": False, "close_fds": True}
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
    else:
        kwargs["start_new_session"] = True
    try:
        child = subprocess.Popen(command, **kwargs)
        time.sleep(0.25)
        if child.poll() is not None:
            update_state(run_dir, status="worker_failed", stage_status="launch_failed", worker_returncode=child.returncode)
            return 2
        update_state(run_dir, status="running", stage_status="dispatched", worker_pid=child.pid)
        return WORKER_STARTED
    finally:
        log.close()


def advance(run_dir: Path, state: dict[str, Any]) -> int:
    stage = int(state["current_stage"])
    dry_run = bool(state["params"].get("dry_run"))
    if stage == 1:
        update_state(run_dir, status="ready", current_stage=2, stage_status="ready")
        return invoke_worker(run_dir, "build_worker.py", dry_run)
    if stage == 2:
        return invoke_worker(run_dir, "build_worker.py", dry_run)
    if stage == 3:
        latest = state.get("ai_history", [])[-1]
        action = latest["action"]
        if action == "stop":
            update_state(run_dir, status="stopped", stage_status="done", stop_reason=latest["summary"])
            return 2
        if action == "retry":
            round_number = int(state.get("repair_round", 0)) + 1
            if round_number > int(state["params"]["max_repair_rounds"]):
                update_state(run_dir, status="stopped", stage_status="limit_reached", stop_reason="max_repair_rounds reached")
                return 2
            update_state(run_dir, status="ready", current_stage=2, stage_status="ready",
                         repair_round=round_number, matrix_verified=False)
            return invoke_worker(run_dir, "build_worker.py", dry_run)
        update_state(run_dir, status="ready", current_stage=4, stage_status="ready", matrix_verified=False)
        return invoke_worker(run_dir, "regression_worker.py", dry_run)
    if stage == 4:
        return invoke_worker(run_dir, "regression_worker.py", dry_run)
    if stage == 5:
        latest = state.get("ai_history", [])[-1]
        approved = str(latest.get("verdict", "")).lower() in {"approve", "approved", "pass"}
        current = read_json(run_dir / "state.json")
        versions = current["params"]["engine_versions"]
        regression = current.get("regression_results", {})
        all_green = current.get("matrix_verified") and all(regression.get(v, {}).get("success") for v in versions)
        if latest["action"] == "stop" and approved and all_green:
            update_state(run_dir, status="completed", stage_status="done", completed_at=utc_now())
            return 0
        update_state(run_dir, status="stopped", stage_status="review_rejected",
                     stop_reason="final review rejected or matrix incomplete")
        return 2
    raise ValueError(f"unknown stage: {stage}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Unreal plugin compile/fix loop; --params accepts only a UTF-8 JSON file.")
    parser.add_argument("--params", help="existing UTF-8 JSON file path (required for a new run)")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--resume", action="store_true", help="resume the run selected by active_run.json")
    group.add_argument("--reset", action="store_true", help="safely reset the active run")
    args = parser.parse_args()
    try:
        if args.resume and args.params:
            raise ValueError("--resume does not accept --params")
        if not args.params and not (args.resume or args.reset):
            parser.error("a new run requires --params")
        if args.reset:
            old_run = get_active_run()
            old_params = read_json(old_run / "state.json")["params"]
            shutil.rmtree(assert_safe_run_dir(old_run))
            if ACTIVE_RUN.is_file():
                ACTIVE_RUN.unlink()
            params = normalize_params(load_params(args.params)) if args.params else old_params
            run_dir = new_run_directory(params)
            state = initialize(run_dir, params)
            print(json.dumps({"status": state["status"], "run_dir": str(run_dir)}, ensure_ascii=False))
            return AI_HANDOFF
        if args.resume:
            run_dir = get_active_run()
            state = read_json(run_dir / "state.json")
            if state.get("status") in {"completed", "stopped"}:
                print(json.dumps({"status": state["status"], "run_dir": str(run_dir)}, ensure_ascii=False))
                return 0 if state["status"] == "completed" else 2
            if int(state["current_stage"]) in (1, 3, 5):
                consumed = consume_ai_output(run_dir, state)
                if consumed is None:
                    print(json.dumps({"status": "waiting_ai", "stage": state["current_stage"], "run_dir": str(run_dir)}, ensure_ascii=False))
                    return AI_HANDOFF
                state = consumed
            return advance(run_dir, state)
        params = normalize_params(load_params(args.params))
        run_dir = new_run_directory(params)
        state = initialize(run_dir, params)
        print(json.dumps({"status": state["status"], "run_dir": str(run_dir)}, ensure_ascii=False))
        return AI_HANDOFF
    except (ValueError, OSError, json.JSONDecodeError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
