#!/usr/bin/env python3
"""工具包内部证据检查。仅用标准库；不调用模型，不读取 .env。"""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import uuid

NO_CODE = {"阶段0", "阶段1", "阶段3-0", "阶段5"}
STAGE_PATTERN = re.compile(r"阶段(?:0|1|2-[1-9][0-9]*|3-(?:0|[1-9][0-9]*)|4|5)\Z")
IGNORED_DIRS = {".git", ".venv", "venv", "node_modules", "__pycache__",
                ".pytest_cache", ".next", ".cache", ".superpowers",
                "dist", "build", "out", "data", "logs", "uploads", "coverage"}
GENERATED_DOCS = {"项目状态.md", "流程状态.txt", "流程历史.txt", "本阶段任务.md"}
RESULT_FIELDS = {"id", "run_index", "status", "schema_valid", "request_id",
                 "input_tokens", "output_tokens", "elapsed_ms", "cost", "retries"}


def _stage(stage):
    if not isinstance(stage, str) or not STAGE_PATTERN.fullmatch(stage):
        raise ValueError("阶段名无效，请让 AI 使用当前阶段重新检查。")
    return stage


def _safe(product, relative):
    product = Path(product).absolute()
    if product.is_symlink():
        raise ValueError("产品目录不能使用符号链接。")
    path = product / relative
    path.relative_to(product)
    if ".." in Path(relative).parts or Path(relative).is_absolute():
        raise ValueError("证据路径必须位于产品目录中。")
    cursor = product
    for part in Path(relative).parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise ValueError("输入或证据中存在符号链接，请让 AI 整理到产品目录后重验。")
    return path


def _evidence(product, stage, name):
    return _safe(product, Path("docs") / "evidence" / _stage(stage) / name)


def _read_json(path):
    with path.open(encoding="utf-8") as stream:
        result = json.load(stream)
    if not isinstance(result, dict):
        raise ValueError("机器记录必须是一个对象。")
    return result


def _write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".kit-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def _locked(product, stage):
    lock = _evidence(product, stage, ".kit.lock")
    lock.parent.mkdir(parents=True, exist_ok=True)
    with lock.open("a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def fingerprint(product):
    """包含源码/需求/提示词/非秘密配置的内容摘要，包含未跟踪文件。"""
    product = Path(product).absolute()
    if not product.is_dir() or product.is_symlink():
        raise ValueError("找不到有效的产品目录。")
    digest = hashlib.sha256()

    def add(label, path):
        digest.update(label.encode("utf-8") + b"\0")
        if path.is_symlink():
            raise ValueError("源码中存在符号链接，请让 AI 整理后重新验证。")
        if not path.exists():
            digest.update(b"missing\0")
            return
        digest.update(hashlib.sha256(path.read_bytes()).digest())

    def walk(directory, parts=()):
        for path in sorted(directory.iterdir(), key=lambda p: p.name):
            rel = parts + (path.name,)
            name = path.name
            if name in IGNORED_DIRS or name == ".DS_Store":
                continue
            if name.startswith(".env") and name != ".env.example":
                continue
            if name.endswith((".log", ".pyc", ".pyo")):
                continue
            if rel[:2] == ("docs", "evidence"):
                continue
            if len(rel) == 2 and rel[0] == "docs" and name in GENERATED_DOCS:
                continue
            if path.is_symlink():
                raise ValueError("源码中存在符号链接，请让 AI 整理后重新验证。")
            if path.is_dir():
                walk(path, rel)
            elif path.is_file():
                add("product/" + "/".join(rel), path)
    walk(product)
    toolkit = product.parent.parent
    for name in ("kit.sh", "verify.sh", "scripts/kit_checks.py"):
        add("toolkit/" + name, toolkit / name)
    return digest.hexdigest()


def _requirements(product, stage):
    path = _safe(product, Path("docs") / "阶段文档" / (_stage(stage) + "-验收要求.json"))
    data = _read_json(path)
    if data.get("schema_version") != 1 or not isinstance(data.get("model"), str) or not data["model"].strip():
        raise ValueError("缺少明确的模型验收要求。")
    required = data.get("required_cases")
    if not isinstance(required, list) or not required:
        raise ValueError("AI 尚未整理本阶段必要的模型样例。")
    ids = set()
    for item in required:
        if not isinstance(item, dict):
            raise ValueError("模型样例要求格式错误。")
        name, runs = item.get("id"), item.get("runs")
        if not isinstance(name, str) or not name.strip() or name in ids or type(runs) is not int or runs < 1:
            raise ValueError("模型样例名称和执行次数需要 AI 修正。")
        ids.add(name)
    if not isinstance(data.get("parameters", {}), dict):
        raise ValueError("公开模型参数格式错误。")
    return data


def start_smoke_run(product, stage, model):
    """真实调用前执行：立即将当前批次设为待验，旧成功不再生效。"""
    _stage(stage)
    if not isinstance(model, str) or not model.strip():
        raise ValueError("需要提供实际调用的模型名称。")
    run = {"schema_version": 1, "run_id": uuid.uuid4().hex, "stage": stage,
           "model": model, "input_hash": fingerprint(product), "status": "待验",
           "started_at": datetime.now(timezone.utc).isoformat(), "cases": []}
    with _locked(product, stage):
        _write_json(_evidence(product, stage, "冒烟结果.json"), run)
    return dict(run)


def finish_smoke_run(product, run, cases):
    """由冒烟脚本传入实际结果；只保存元信息，绝不补造模型调用。"""
    stage = _stage(run.get("stage"))
    path = _evidence(product, stage, "冒烟结果.json")
    with _locked(product, stage):
        current = _read_json(path)
        if current.get("run_id") != run.get("run_id"):
            raise ValueError("已有更新的模型验证，本次结果不能覆盖新批次。")
        # 以磁盘中的开始记录为准，调用方不能在完成时改写输入版本。
        result = dict(current)
        if not isinstance(cases, list) or not all(isinstance(item, dict) for item in cases):
            cases = []
        result["cases"] = [
            {key: value for key, value in item.items() if key in RESULT_FIELDS}
            for item in cases if isinstance(item, dict)
        ]
        result["finished_at"] = datetime.now(timezone.utc).isoformat()
        result["status"] = "通过" if result["cases"] and all(
            item.get("status") == "通过" and item.get("schema_valid") is True
            for item in result["cases"]) else "失败"
        if current.get("input_hash") != fingerprint(product):
            result["status"] = "过期"
        _write_json(path, result)


def check_smoke(product, stage):
    _stage(stage)
    path = _evidence(product, stage, "冒烟结果.json")
    if not path.exists():
        old = _evidence(product, stage, "冒烟记录.md").exists()
        return False, "待验（旧记录需重新核验，请让 AI 更新冒烟脚本）" if old else "待验（尚无本阶段真实模型结果）"
    try:
        data = _read_json(path)
        requirements = _requirements(product, stage)
        if data.get("schema_version") != 1 or not isinstance(data.get("run_id"), str) or not data["run_id"]:
            return False, "待验（模型记录格式需要 AI 修正）"
        if data.get("stage") != stage or data.get("model") != requirements["model"]:
            return False, "待验（模型或阶段与验收要求不一致）"
        if data.get("status") != "通过":
            return False, "待验（最近一轮模型验证未通过或尚未完成）"
        if data.get("input_hash") != fingerprint(product):
            return False, "待验（模型验证后输入版本改变，请重新核验）"
        cases = data.get("cases")
        if not isinstance(cases, list) or not cases:
            return False, "待验（没有真实样例结果）"
        actual = {}
        for item in cases:
            if not isinstance(item, dict) or item.get("status") != "通过" or item.get("schema_valid") is not True:
                return False, "不通过（本轮模型样例存在失败或未知结果）"
            name, index = item.get("id"), item.get("run_index")
            if not isinstance(name, str) or not name or type(index) is not int or index < 1:
                return False, "待验（样例编号格式需要 AI 修正）"
            if index in actual.setdefault(name, set()):
                return False, "不通过（同一样例重复使用运行编号）"
            actual[name].add(index)
        for item in requirements["required_cases"]:
            expected = set(range(1, item["runs"] + 1))
            if not expected.issubset(actual.get(item["id"], set())):
                return False, "待验（本批次尚未覆盖已确认的样例和次数）"
        return True, "通过（当前版本的必要模型样例已通过；业务质量仍按验收标准判断）"
    except (OSError, ValueError, TypeError, KeyError):
        return False, "待验（记录或验收要求缺失/无效，请让 AI 修正后真实重验）"


def _smoke_digest(product, stage):
    path = _evidence(product, stage, "冒烟结果.json")
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def begin_verification(product, stage):
    """开始检查前原子写待验；即使进程中断也不能沿用旧成功。"""
    _stage(stage)
    before = fingerprint(product)
    result = {"schema_version": 1, "verification_id": uuid.uuid4().hex,
              "stage": stage, "status": "待验", "started_hash": before,
              "started_at": datetime.now(timezone.utc).isoformat()}
    with _locked(product, stage):
        _write_json(_evidence(product, stage, "验证结果.json"), result)
    return dict(result)


def seal(product, stage, before, overall, verification_id=None):
    _stage(stage)
    # Python 调用可自行启动一轮；CLI 必须带 begin 返回的编号。
    if verification_id is None:
        verification_id = begin_verification(product, stage)["verification_id"]
    with _locked(product, stage):
        path = _evidence(product, stage, "验证结果.json")
        current = _read_json(path)
        if current.get("verification_id") != verification_id:
            return False, "待验（已有更新的自检，本次结果不能覆盖新批次）"
        after = fingerprint(product)
        passed = (type(overall) is int and overall == 0 and before == after
                  and current.get("started_hash") == before)
        if passed and stage not in NO_CODE:
            passed = check_smoke(product, stage)[0]
        result = {**current, "status": "通过" if passed else "未通过",
                  "input_hash": after,
                  "smoke_hash": _smoke_digest(product, stage) if stage not in NO_CODE else None,
                  "verified_at": datetime.now(timezone.utc).isoformat()}
        _write_json(path, result)
    if before != after:
        return False, "不通过（自检过程中输入版本改变，请让 AI 重新自检）"
    return passed, ("通过（已保存本次验收依据）" if passed else "待验（已保存检查结果，未获得阶段通过凭据）")


def check_gate(product, stage):
    try:
        _stage(stage)
        result = _read_json(_evidence(product, stage, "验证结果.json"))
        if result.get("schema_version") != 1 or result.get("stage") != stage or result.get("status") != "通过":
            raise ValueError("没有通过凭据")
        verification = result.get("verification_id")
        if not isinstance(verification, str) or not verification:
            raise ValueError("没有验证编号")
        current = fingerprint(product)
        if result.get("input_hash") != current or result.get("started_hash") != current:
            raise ValueError("版本已改变")
        if stage not in NO_CODE:
            if result.get("smoke_hash") != _smoke_digest(product, stage) or not check_smoke(product, stage)[0]:
                raise ValueError("模型证据已改变")
        return True, verification
    except (OSError, ValueError, TypeError, KeyError):
        return False, "拒绝：当前版本尚无有效自检结果。请让 AI 重新运行本阶段自检，再验收；已有业务数据保留。"


def main(argv=None):
    parser = argparse.ArgumentParser(description="工具包内部证据检查，由 AI 调用。")
    parser.add_argument("command", choices=["fingerprint", "begin", "smoke", "seal", "gate"])
    parser.add_argument("product")
    parser.add_argument("extra", nargs="*")
    args = parser.parse_args(argv)
    try:
        if args.command == "fingerprint" and not args.extra:
            print(fingerprint(Path(args.product)))
            return 0
        if args.command == "begin" and len(args.extra) == 1:
            started = begin_verification(Path(args.product), args.extra[0])
            print(started["started_hash"] + " " + started["verification_id"])
            return 0
        if args.command in ("smoke", "gate") and len(args.extra) == 1:
            fn = check_smoke if args.command == "smoke" else check_gate
            ok, message = fn(Path(args.product), args.extra[0])
        elif args.command == "seal" and len(args.extra) == 4:
            if args.extra[2] not in ("0", "1"):
                raise ValueError("总体状态必须是0或1")
            ok, message = seal(Path(args.product), args.extra[0], args.extra[1], int(args.extra[2]), args.extra[3])
        else:
            raise ValueError("命令参数不完整")
        print(message)
        return 0 if ok else 1
    except (OSError, ValueError, TypeError, KeyError):
        print("检查未完成：输入、阶段或文件格式无效，请让 AI 修正后重新验证。")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
