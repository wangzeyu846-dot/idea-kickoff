"""verify.sh 的离线集成回归：真实 Shell 编排、文件与退出码。"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="kit-verify-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "kit"
        self.root.mkdir()
        self.product = self.root / "projects" / "样例"
        self.product.mkdir(parents=True)
        self.bin = Path(self.temp.name) / "bin"
        self.bin.mkdir()
        self.calls = Path(self.temp.name) / "commands"
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "CHECK_CALLS": str(self.calls), "PYTHONDONTWRITEBYTECODE": "1"}
        shutil.copy2(ROOT / "verify.sh", self.root / "verify.sh")
        self.put_root(".gitignore", ".venv/\nnode_modules/\n__pycache__/\n")
        self.put_root("docs/手册/说明.md", "夹具")
        self.put_root("scripts/export-clean-kit.sh", "#!/bin/sh\n")
        if (ROOT / "scripts/kit_checks.py").exists():
            shutil.copy2(ROOT / "scripts/kit_checks.py", self.root / "scripts/kit_checks.py")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True, capture_output=True)
        self.put("docs/项目状态.md", "已按当前范围完成")
        self.put("README.md", "启动与验证")
        for stage, name in [
            ("阶段0", "阶段0-PRD补全清单"),
            ("阶段1", "技术适配声明"),
            ("阶段2-1", "阶段2-1技术开发文档"),
            ("阶段3-0", "前端适配声明"),
            ("阶段3-1", "阶段3-1技术开发文档"),
            ("阶段4", "上线方案摘要"),
        ]:
            self.put("docs/阶段文档/" + name + ".md", "确认范围")
            self.put("docs/evidence/" + stage + "/是否表.md", "待填结果")
            self.put("docs/evidence/" + stage + "/照着做清单.md", "本地验收")
            self.put("docs/evidence/" + stage + "/截图.png", "离线夹具")
        self.put("docs/evidence/阶段5/是否表.md", "收尾")
        self.command("npm", """#!/bin/sh
printf '%s\\n' "npm $*" >> "$CHECK_CALLS"
if [ "${1:-}" = run ] && [ "${2:-}" = lint ] && [ -n "${CHANGE_FILE:-}" ]; then
  printf '%s\\n' '输入已改变' >> "$CHANGE_FILE"
fi
exit "${NPM_RC:-0}"
""")
        self.command("npx", """#!/bin/sh
printf '%s\\n' "npx $*" >> "$CHECK_CALLS"
exit 99
""")

    def put_root(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def put(self, relative, text):
        return self.put_root("projects/样例/" + relative, text)

    def command(self, name, text):
        path = self.bin / name
        path.write_text(text, encoding="utf-8")
        path.chmod(0o755)

    def code(self):
        self.put("backend/tests/test_app.py", "def test_placeholder(): pass\n")
        self.put("backend/app.py", "value = 1\n")
        python = self.put("backend/.venv/bin/python", """#!/bin/sh
printf '%s\\n' '5 passed in 0.01s'
exit "${BACKEND_RC:-0}"
""")
        python.chmod(0o755)
        # 这个钩子确实启动两个不同进程，并从磁盘读回随机标记。
        self.put("scripts/restart-check.sh", """#!/bin/bash
case "$1" in
  start) sleep 60 > /dev/null 2>&1 & echo "$!" ;;
  write) printf '%s' "$2" > "$RESTART_CHECK_DIR/value"; echo record ;;
  read) cat "$RESTART_CHECK_DIR/value" ;;
  stop) : ;;
esac
""")

    def frontend(self, scripts=None, ts=False):
        if scripts is None:
            scripts = {"test": "test", "lint": "lint", "build": "build"}
        self.put("frontend/package.json", json.dumps({"scripts": scripts}))
        if ts:
            self.put("frontend/tsconfig.json", "{}")
            tsc = self.put("frontend/node_modules/.bin/tsc", """#!/bin/sh
printf '%s\\n' "本地类型检查 $*" >> "$CHECK_CALLS"
exit 0
""")
            tsc.chmod(0o755)

    def smoke(self, stage="阶段2-1", status="通过"):
        self.put("docs/阶段文档/" + stage + "-验收要求.json", json.dumps({
            "schema_version": 1, "model": "离线测试模型",
            "required_cases": [{"id": "核心任务", "runs": 1}], "parameters": {}
        }, ensure_ascii=False))
        helper = self.root / "scripts/kit_checks.py"
        input_hash = "0" * 64
        if helper.exists():
            hashed = subprocess.run(["python3", str(helper), "fingerprint", str(self.product)],
                                    check=True, capture_output=True, text=True, env=self.env)
            input_hash = hashed.stdout.strip()
        self.put("docs/evidence/" + stage + "/冒烟结果.json", json.dumps({
            "schema_version": 1, "run_id": "离线夹具运行", "stage": stage,
            "model": "离线测试模型", "input_hash": input_hash, "status": status,
            "cases": [{"id": "核心任务", "run_index": 1, "status": status,
                       "schema_valid": status == "通过"}]
        }, ensure_ascii=False))
        self.put("docs/evidence/" + stage + "/冒烟记录.md",
                 "- 模型：离线测试模型\n| 2099-01-01 00:00:00 | 核心任务 | " + status + " |\n")

    def run_verify(self, *args, **environment):
        return subprocess.run(["bash", str(self.root / "verify.sh"), *args],
                              cwd=self.root, env={**self.env, **environment},
                              capture_output=True, text=True, timeout=20)

    def result(self, run, item):
        prefix = "是否表第 " + str(item) + " 项"
        return next((line for line in run.stdout.splitlines() if line.startswith(prefix)), "")

    def assert_passed(self, run):
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_missing_stage_rejected_before_checks(self):
        self.code()
        (self.root / "scripts/kit_checks.py").unlink(missing_ok=True)
        run = self.run_verify("样例")
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertIn("阶段", run.stdout)

    def test_invalid_stage_rejected_without_evidence_directory(self):
        for stage in ("阶段2", "阶段2-0", "阶段2-01", "阶段3-坏", "阶段6"):
            with self.subTest(stage=stage):
                run = self.run_verify("样例", stage)
                self.assertNotEqual(run.returncode, 0, run.stdout)
                self.assertFalse((self.product / "docs/evidence" / stage).exists())

    def test_no_code_and_wrap_up_skip_product_commands(self):
        self.code()
        self.frontend()
        for stage in ("阶段0", "阶段1", "阶段3-0", "阶段5"):
            with self.subTest(stage=stage):
                run = self.run_verify("样例", stage, NPM_RC="37", BACKEND_RC="37")
                self.assert_passed(run)
                for item in (2, 3, 4, 6):
                    self.assertIn("N/A", self.result(run, item))
        self.assertFalse(self.calls.exists())

    def test_formal_frontend_stage_requires_project(self):
        self.code()
        self.smoke("阶段3-1")
        run = self.run_verify("样例", "阶段3-1")
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertRegex(self.result(run, 4), "未配置|不通过")

    def test_frontend_requires_each_script(self):
        self.code()
        for missing in ("test", "lint", "build"):
            with self.subTest(missing=missing):
                self.frontend({key: "命令" for key in ("test", "lint", "build") if key != missing})
                self.smoke()
                run = self.run_verify("样例", "阶段2-1")
                self.assertNotEqual(run.returncode, 0, run.stdout)
                self.assertRegex(self.result(run, 2 if missing == "test" else 4), "未配置|不通过")
                self.assertIn(missing, run.stdout)

    def test_strings_outside_scripts_do_not_configure_commands(self):
        self.code()
        self.put("frontend/package.json", json.dumps({"test": "", "lint": "", "build": "", "scripts": {}}))
        self.smoke()
        run = self.run_verify("样例", "阶段2-1")
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertRegex(self.result(run, 4), "未配置|不通过")

    def test_malformed_package_is_not_a_pass(self):
        self.code()
        self.put("frontend/package.json", '{"test": "test", "lint": "lint", "build": "build"')
        self.smoke()
        run = self.run_verify("样例", "阶段2-1")
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertRegex(self.result(run, 4), "未配置|不通过")

    def test_typescript_runs_local_compiler_without_npx(self):
        self.code()
        self.frontend(ts=True)
        self.smoke()
        run = self.run_verify("样例", "阶段2-1")
        self.assert_passed(run)
        calls = self.calls.read_text(encoding="utf-8")
        self.assertNotIn("npx", calls)
        self.assertIn("本地类型检查 --noEmit", calls)

    def test_typescript_requires_available_typecheck(self):
        self.code()
        self.frontend(ts=True)
        (self.product / "frontend/node_modules/.bin/tsc").unlink()
        self.smoke()
        run = self.run_verify("样例", "阶段2-1")
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertRegex(self.result(run, 4), "未配置|不通过")
        self.assertNotIn("npx", self.calls.read_text(encoding="utf-8"))

    def test_typescript_accepts_explicit_typecheck_script(self):
        self.code()
        self.frontend({"test": "test", "lint": "lint", "build": "build", "typecheck": "tsc --noEmit"}, ts=True)
        (self.product / "frontend/node_modules/.bin/tsc").unlink()
        self.smoke()
        run = self.run_verify("样例", "阶段2-1")
        self.assert_passed(run)
        self.assertIn("npm run typecheck", self.calls.read_text(encoding="utf-8"))

    def test_failed_smoke_cannot_pass_using_markdown_history(self):
        self.code()
        self.smoke(status="失败")
        run = self.run_verify("样例", "阶段2-1")
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertRegex(self.result(run, 3), "待验|不通过")

    def test_old_markdown_without_structured_result_is_pending(self):
        self.code()
        self.smoke()
        (self.product / "docs/evidence/阶段2-1/冒烟结果.json").unlink()
        run = self.run_verify("样例", "阶段2-1")
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertIn("待验", self.result(run, 3))

    def test_success_writes_text_then_sealed_result(self):
        self.code()
        self.frontend()
        self.smoke()
        run = self.run_verify("样例", "阶段2-1")
        self.assert_passed(run)
        evidence = self.product / "docs/evidence/阶段2-1"
        self.assertTrue((evidence / "verify-输出.txt").is_file())
        self.assertTrue((evidence / "验证结果.json").is_file())
        gate = subprocess.run(["python3", str(self.root / "scripts/kit_checks.py"), "gate",
                               str(self.product), "阶段2-1"], capture_output=True, text=True)
        self.assertEqual(gate.returncode, 0, gate.stdout + gate.stderr)

    def test_input_change_during_verification_fails_seal(self):
        self.code()
        self.frontend()
        self.smoke()
        run = self.run_verify("样例", "阶段2-1", CHANGE_FILE=str(self.product / "backend/app.py"))
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertRegex(run.stdout, "变化|改变|重验")

    def test_interrupted_verification_invalidates_previous_success(self):
        self.code()
        backend = self.put("backend/.venv/bin/python", """#!/bin/sh
if [ -n "${CHECK_PAUSE:-}" ]; then
    printf '已进入测试' > "$CHECK_PAUSE"
    sleep 60
fi
printf '%s\\n' '5 passed in 0.01s'
""")
        backend.chmod(0o755)
        self.smoke()
        self.assert_passed(self.run_verify("样例", "阶段2-1"))
        marker = Path(self.temp.name) / "检查已开始"
        process = subprocess.Popen(
            ["bash", str(self.root / "verify.sh"), "样例", "阶段2-1"],
            cwd=self.root, env={**self.env, "CHECK_PAUSE": str(marker)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
        try:
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline and process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(marker.exists(), "第二次自检应实际进入后端测试")
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=5)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)
        gate = subprocess.run(
            ["python3", str(self.root / "scripts/kit_checks.py"), "gate",
             str(self.product), "阶段2-1"],
            capture_output=True, text=True, env=self.env,
        )
        self.assertNotEqual(gate.returncode, 0, "中断后不应沿用旧成功凭据：" + gate.stdout)

    def test_backend_failure_remains_failure_after_frontend_success(self):
        self.code()
        self.frontend()
        self.smoke()
        run = self.run_verify("样例", "阶段2-1", BACKEND_RC="19")
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertIn("不通过", self.result(run, 2))

    def test_toolkit_whitelist_is_precise(self):
        for name in ("test_kit_checks.py", "test_verify.py", "test_kit_flow.py"):
            self.put_root("tests/" + name, "# 工具包回归\n")
        run = self.run_verify("样例", "阶段0")
        self.assert_passed(run)
        self.put_root("tests/test_product.py", "# 产品文件不可放在根目录\n")
        run = self.run_verify("样例", "阶段0")
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertIn("tests/test_product.py", run.stdout)

    def test_unknown_smoke_output_cannot_enter_success_summary(self):
        self.code()
        self.smoke()
        helper = self.root / "scripts/kit_checks.py"
        helper.write_text("""import sys
if sys.argv[1] == 'begin':
    print('0' * 64 + ' offline-verification')
elif sys.argv[1] == 'smoke':
    print('尚未识别的结果')
elif sys.argv[1] == 'seal':
    raise SystemExit(int(sys.argv[-2]))
""", encoding="utf-8")
        run = self.run_verify("样例", "阶段2-1")
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertRegex(self.result(run, 3), "不通过|待验")


if __name__ == "__main__":
    unittest.main()
