import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("kit.sh", "scripts/kit_checks.py"):
            dest = self.root / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, dest)
        self.p = self.root / "projects/示例"
        (self.p / "docs").mkdir(parents=True)
        self.state = self.p / "docs/流程状态.txt"
        self.set_state()
        spec = importlib.util.spec_from_file_location("flow_checks", self.root / "scripts/kit_checks.py")
        self.k = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.k)

    def set_state(self, stage="阶段0"):
        self.state.write_text(f"阶段={stage}\n状态=等验收\n工具=other\n", encoding="utf-8")

    def run_kit(self, *args, input=""):
        return subprocess.run(["bash", "kit.sh", *args], cwd=self.root, input=input,
                              text=True, capture_output=True, timeout=10)

    def seal(self, stage="阶段0"):
        self.assertTrue(self.k.seal(self.p, stage, self.k.fingerprint(self.p), 0)[0])

    def test_chat_cannot_advance_with_only_legacy_status(self):
        result = self.run_kit("通过", "示例")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("阶段=阶段0", self.state.read_text())

    def test_chat_cannot_reuse_receipt_after_source_change(self):
        self.seal()
        (self.p / "prompt.txt").write_text("新的提示词")
        result = self.run_kit("通过", "示例")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("阶段=阶段0", self.state.read_text())

    def test_chat_advances_current_receipt_and_records_id(self):
        self.seal()
        _, identifier = self.k.check_gate(self.p, "阶段0")
        result = self.run_kit("通过", "示例")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("阶段=阶段1", self.state.read_text())
        self.assertIn(identifier, (self.p / "docs/流程历史.txt").read_text())

    def test_window_cannot_advance_without_receipt(self):
        result = self.run_kit(input="y\nn\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("阶段=阶段0", self.state.read_text())

    def test_window_cannot_reuse_outdated_receipt(self):
        self.seal()
        (self.p / "README.md").write_text("更新后的产品说明")
        result = self.run_kit(input="y\nn\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("阶段=阶段0", self.state.read_text())

    def test_window_advances_current_receipt(self):
        self.seal()
        result = self.run_kit(input="y\nn\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("阶段=阶段1", self.state.read_text())

    def test_status_does_not_report_outdated_verification_as_current(self):
        self.seal()
        (self.p / "prompt.txt").write_text("变更")
        result = self.run_kit("状态", "示例")
        self.assertEqual(result.returncode, 0)
        self.assertNotIn("状态=等验收", self.state.read_text())
        for phrase in ("已完成", "待验", "可继续", "下一步"):
            self.assertIn(phrase, result.stdout)

    def test_window_branch_uses_numbered_business_choices(self):
        import json
        self.set_state("阶段2-1")
        required = self.p / "docs/阶段文档/阶段2-1-验收要求.json"
        required.parent.mkdir(parents=True)
        required.write_text(json.dumps({"schema_version": 1, "model": "示例模型",
            "required_cases": [{"id": "大纲", "runs": 1}]}))
        run = self.k.start_smoke_run(self.p, "阶段2-1", "示例模型")
        self.k.finish_smoke_run(self.p, run, [
            {"id": "大纲", "run_index": 1, "status": "通过", "schema_valid": True}])
        self.seal("阶段2-1")
        result = self.run_kit(input="y\n2\nn\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("阶段=阶段3-0", self.state.read_text())
        self.assertNotIn("输入阶段名", result.stdout)

    def test_legacy_project_gets_ai_recovery_task(self):
        self.state.unlink()
        (self.p / "docs/项目状态.md").write_text("当前在阶段2-2，已有需求与决策")
        result = self.run_kit("任务", "示例")
        self.assertEqual(result.returncode, 0)
        self.assertIn("待恢复=是", self.state.read_text())
        task = (self.p / "docs/本阶段任务.md").read_text()
        self.assertIn("先恢复已有进度", task)
        self.assertIn("回到", task)
        self.assertIn("不重填", task)

    def test_recovery_must_finish_before_verification(self):
        (self.p / "docs/项目状态.md").write_text("当前在阶段2-2")
        self.state.write_text("阶段=阶段0\n状态=待开工\n待恢复=是\n")
        # 若误调用 verify，这个替身会成功；待恢复时须在调用前阻止。
        (self.root / "verify.sh").write_text("#!/bin/sh\nexit 0\n")
        result = self.run_kit("自检", "示例")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("恢复", result.stdout)
        result = self.run_kit("回到", "示例", "阶段2-2")
        self.assertEqual(result.returncode, 0)
        self.assertNotIn("待恢复=是", self.state.read_text())

    def test_closing_stage_does_not_require_model(self):
        self.set_state("阶段5")
        self.seal("阶段5")
        result = self.run_kit("通过", "示例")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("阶段=完成", self.state.read_text())

    def window_with_stub(self, body, verify_exit=0):
        import os
        tools = self.root / "tools"
        tools.mkdir()
        codex = tools / "codex"
        codex.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8")
        codex.chmod(0o755)
        self.state.write_text("阶段=阶段0\n状态=待开工\n工具=codex\n", encoding="utf-8")
        (self.root / "verify.sh").write_text(
            '#!/bin/sh\nprintf "%s\\n" "$*" > verify-args.txt\nexit ' + str(verify_exit) + "\n")
        return subprocess.run(["bash", "kit.sh"], cwd=self.root, text=True,
            input="", capture_output=True, timeout=10,
            env={**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"]})

    def test_window_follows_product_renamed_by_ai(self):
        result = self.window_with_stub("mv projects/示例 projects/报告助手")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "verify-args.txt").read_text().strip(), "报告助手 阶段0")
        self.assertFalse(self.p.exists())
        self.assertIn("状态=等验收", (self.root / "projects/报告助手/docs/流程状态.txt").read_text())
        self.assertNotIn("No such file", result.stderr)

    def test_window_does_not_guess_between_duplicate_product_ids(self):
        result = self.window_with_stub(
            "cp -R projects/示例 projects/另一个\nmv projects/示例 projects/报告助手")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "verify-args.txt").exists())
        self.assertIn("唯一", result.stdout)

    def test_window_returns_verification_failure(self):
        result = self.window_with_stub(":", verify_exit=1)
        self.assertNotEqual(result.returncode, 0)



if __name__ == "__main__":
    unittest.main()
