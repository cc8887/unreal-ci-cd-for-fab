from __future__ import annotations

import copy
import hashlib
import json
import locale
import os
import re
import shutil
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parents[1]
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))
from lib.assets import load_error_rules, render_repair_prompt  # pyright: ignore[reportMissingImports]

SENSITIVE_NAME_RE = re.compile(
    r"(^|/)(\.env($|\.)|id_(rsa|dsa|ecdsa|ed25519)(\.|$)|.*\.(pem|p12|pfx|key)$|"
    r"(credentials?|secrets?|tokens?)(\.|/|$))",
    re.IGNORECASE,
)
ERROR_RE = re.compile(r"(error\s+[A-Z]?\d+|fatal error|BUILD FAILED|Exception:|Write-Error)", re.IGNORECASE)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON object required: {path}")
    return value


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def update_state(run_dir: Path, **changes: Any) -> dict[str, Any]:
    path = run_dir / "state.json"
    state = read_json(path)
    state.update(changes)
    state["updated_at"] = utc_now()
    write_json(path, state)
    return state


def classify_output(text: str) -> dict[str, Any]:
    rules = load_error_rules()
    lower = text.lower()
    matches: list[dict[str, str]] = []
    for rule in rules.get("rules", []):
        if any(str(pattern).lower() in lower for pattern in rule.get("patterns", [])):
            matches.append({
                "id": str(rule.get("id", "unknown")),
                "category": str(rule.get("category", "unknown")),
                "suggestion": str(rule.get("suggestion", "")),
            })
    lines = []
    seen = set()
    for line in text.splitlines():
        clean = line.strip()
        if clean and ERROR_RE.search(clean) and clean not in seen:
            seen.add(clean)
            lines.append(clean[:500])
        if len(lines) >= 12:
            break
    fallback = rules.get("fallback", {})
    return {
        "classifications": matches or [{
            "id": "fallback",
            "category": fallback.get("category", "unknown"),
            "suggestion": fallback.get("suggestion", "交由 AI 诊断。"),
        }],
        "error_lines": lines,
    }


def validate_zip(path: Path) -> dict[str, Any]:
    result: dict[str, Any] = {"path": str(path), "valid": False, "errors": []}
    if not path.is_file():
        result["errors"].append("ZIP 不存在")
        return result
    try:
        with zipfile.ZipFile(path, "r") as archive:
            bad = archive.testzip()
            names = [name.replace("\\", "/") for name in archive.namelist()]
            if bad:
                result["errors"].append(f"ZIP CRC 错误: {bad}")
            if not any(name.lower().endswith(".uplugin") for name in names):
                result["errors"].append("缺少 .uplugin 描述文件")
            dll_names = [name for name in names if name.lower().endswith(".dll")]
            if not any("win64" in name.lower() for name in dll_names):
                result["errors"].append("缺少 Win64 DLL")
            sensitive = [name for name in names if SENSITIVE_NAME_RE.search(name)]
            if sensitive:
                result["errors"].append("ZIP 含禁止的敏感文件名")
                result["sensitive_entries"] = sensitive[:20]
    except (OSError, zipfile.BadZipFile, RuntimeError) as exc:
        result["errors"].append(f"ZIP 无法打开: {exc}")
    result["valid"] = not result["errors"]
    return result


def find_powershell() -> str:
    for name in ("pwsh", "powershell"):
        found = shutil.which(name)
        if found:
            return found
    raise RuntimeError("未找到 pwsh 或 powershell 可执行文件")


def decode_output(data: bytes) -> str:
    for encoding in ("utf-8-sig", locale.getpreferredencoding(False), "cp936", "cp1252"):
        try:
            return data.decode(encoding)
        except (UnicodeDecodeError, LookupError):
            continue
    return data.decode("utf-8", errors="replace")


def find_zip(output_dir: Path, plugin_name: str, version: str, started_ns: int) -> Path | None:
    candidates = list(output_dir.glob(f"{plugin_name}_*_ue{version}.zip"))
    fresh = [path for path in candidates if path.stat().st_mtime_ns >= started_ns]
    return max(fresh, key=lambda path: path.stat().st_mtime_ns) if fresh else None


def build_version(run_dir: Path, state: dict[str, Any], version: str, regression: bool) -> dict[str, Any]:
    params = state["params"]
    if os.name != "nt":
        raise RuntimeError("真实 Unreal 插件构建仅支持 Windows")
    pipeline_repo = Path(params["pipeline_repo"])
    package_script = pipeline_repo / "Tools" / "package_plugin.ps1"
    if not package_script.is_file():
        raise FileNotFoundError(f"打包脚本不存在: {package_script}")
    base_config = copy.deepcopy(read_json(Path(params["config_path"])))
    plugin_repo = Path(params["plugin_repo"])
    base_config["PluginSourceDirectory"] = str(plugin_repo)
    base_config["EngineVersions"] = [version]
    roots = base_config.get("UnrealEngineBasePath", [])
    if isinstance(roots, str):
        roots = [roots]
    program_files = os.environ.get("ProgramFiles")
    defaults = [str(Path(program_files) / "Epic Games")] if program_files else []
    base_config["UnrealEngineBasePath"] = list(dict.fromkeys([str(item) for item in roots] + defaults))
    base_config.setdefault("CloudUpload", {})["Enable"] = False
    base_config.setdefault("ExampleProject", {})["Generate"] = False

    configs_dir = run_dir / "configs"
    logs_dir = run_dir / "logs"
    run_id = str(state["run_id"])
    short_run_id = hashlib.sha256(run_id.encode("utf-8")).hexdigest()[:12]
    drive_root = Path(pipeline_repo.anchor or pipeline_repo.resolve().anchor)
    output_dir = drive_root / "_ufab" / short_run_id / ("r" if regression else "b")
    config_path = configs_dir / f"config_ue_{version.replace('.', '_')}.json"
    log_path = logs_dir / f"{'regression' if regression else 'build'}_ue_{version.replace('.', '_')}.log"
    write_json(config_path, base_config)
    output_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)
    started_ns = int(datetime.now().timestamp() * 1_000_000_000)
    command = [
        find_powershell(), "-NoLogo", "-NoProfile", "-NonInteractive",
        "-ExecutionPolicy", "Bypass", "-File", str(package_script),
        "-EngineVersion", version, "-ConfigPath", str(config_path),
        "-OutputDirectory", str(output_dir),
    ]
    completed = subprocess.run(command, cwd=str(pipeline_repo), stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, shell=False, check=False)
    output = decode_output(completed.stdout)
    log_path.write_text(output, encoding="utf-8", errors="replace")
    zip_path = find_zip(output_dir, str(base_config.get("PluginName", "")), version, started_ns)
    zip_check = validate_zip(zip_path) if zip_path else {"path": None, "valid": False, "errors": ["本轮未生成 ZIP"]}
    success = completed.returncode == 0 and bool(zip_check["valid"])
    return {
        "version": version,
        "success": success,
        "returncode": completed.returncode,
        "log_path": str(log_path),
        "zip_path": str(zip_path) if zip_path else None,
        "zip_validation": zip_check,
        "error_summary": {} if success else classify_output(output),
        "completed_at": utc_now(),
    }


def find_box_cli() -> Path | None:
    candidates = [
        Path(sys.executable).resolve().parent / "box_cli.py",
        Path(sys.executable).resolve().parent.parent / "box_cli.py",
        Path.home() / ".box" / "box_cli.py",
        Path.home() / "AppData" / "Roaming" / "Box" / "box_cli.py",
    ]
    for base in (Path.home() / "AppData" / "Roaming" / "Box", Path.home() / ".box"):
        if base.is_dir():
            candidates.extend(base.glob("**/box_cli.py"))
    return next((path.resolve() for path in candidates if path.is_file()), None)


def notify_ai(run_dir: Path, stage: int, state: dict[str, Any], synchronous: bool = False) -> bool:
    results = state.get("results", {})
    failed = [version for version, item in results.items() if not item.get("success")]
    summaries = []
    for version in failed:
        item = results[version]
        lines = item.get("error_summary", {}).get("error_lines", [])
        summaries.append(f"UE {version}: " + (" | ".join(lines[:3]) or "No extracted error; inspect the log"))
    values = {
        "run_id": str(state["run_id"]),
        "stage": str(stage),
        "failed_versions": ", ".join(failed) or "none",
        "error_summary": "\n".join(summaries) or "The automatic matrix stage reported no build failure.",
        "state_path": str(run_dir / "state.json"),
    }
    prompt_path = run_dir / f"stage_{stage:02d}_prompt.md"
    input_path = run_dir / f"stage_{stage:02d}_input.json"
    prompt_path.write_text(render_repair_prompt(values), encoding="utf-8")
    write_json(input_path, {"stage": stage, "state_path": values["state_path"], "failed_versions": failed})
    box_cli = None if synchronous or state.get("params", {}).get("dry_run") else find_box_cli()
    notified = False
    if box_cli:
        query = prompt_path.read_text(encoding="utf-8")
        try:
            completed = subprocess.run(
                [sys.executable, str(box_cli), "send", "-w", str(SCRIPT_DIR.parent), query],
                cwd=str(SCRIPT_DIR.parent), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, shell=False, check=False, timeout=30,
            )
            notified = completed.returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            notified = False
    marker = run_dir / "RESUME_READY.txt"
    if not notified:
        marker.write_text(
            f"AI stage {stage} is ready. Read {prompt_path.name}, write stage_{stage:02d}_output.json, then run --resume.\n",
            encoding="utf-8",
        )
    elif marker.exists():
        marker.unlink()
    return notified
