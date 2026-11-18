import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "kit_checks.py"


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(HELPER.exists(), "应提供统一的证据检查器")
        spec = importlib.util.spec_from_file_location("kit_checks", HELPER)
        self.k = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.k)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.p = self.root / "projects" / "示例"
        (self.p / "backend").mkdir(parents=True)
        self.source = self.p / "backend" / "app.py"
        self.source.write_text("print(1)")
        (self.root / "verify.sh").write_text("版本1")
        self.stage = "阶段2-1"
        self.requirements = self.p / "docs" / "阶段文档" / (self.stage + "-验收要求.json")
        self.requirements.parent.mkdir(parents=True)
        self.requirements.write_text(json.dumps({
            "schema_version": 1, "model": "示例模型", "parameters": {},
            "required_cases": [{"id": "大纲", "runs": 1}]
        }), encoding="utf-8")

    def case(self, status="通过", index=1):
        return {"id": "大纲", "run_index": index, "status": status,
                "schema_valid": True, "request_id": "示例请求"}

    def success(self):
        run = self.k.start_smoke_run(self.p, self.stage, "示例模型")
        self.k.finish_smoke_run(self.p, run, [self.case()])
        return run

    def test_malformed_extra_result_cannot_be_silently_dropped(self):
        run = self.k.start_smoke_run(self.p, self.stage, "示例模型")
        self.k.finish_smoke_run(self.p, run, [self.case(), "记录中断"])
        self.assertFalse(self.k.check_smoke(self.p, self.stage)[0])

    def test_successful_batch_is_accepted(self):
        self.success()
        self.assertTrue(self.k.check_smoke(self.p, self.stage)[0])

    def test_failed_batch_is_not_accepted(self):
        self.success()
        run = self.k.start_smoke_run(self.p, self.stage, "示例模型")
        self.k.finish_smoke_run(self.p, run, [self.case("失败")])
        self.assertFalse(self.k.check_smoke(self.p, self.stage)[0])

    def test_beginning_new_batch_invalidates_previous_success(self):
        self.success()
        self.k.start_smoke_run(self.p, self.stage, "示例模型")
        self.assertFalse(self.k.check_smoke(self.p, self.stage)[0])

    def test_legacy_markdown_is_not_upgraded_to_proof(self):
        folder = self.p / "docs" / "evidence" / self.stage
        folder.mkdir(parents=True)
        (folder / "冒烟记录.md").write_text("- 模型：示例模型\n| 2026-11-18 12:00 | 通过 |")
        ok, message = self.k.check_smoke(self.p, self.stage)
        self.assertFalse(ok)
        self.assertIn("旧", message)
        self.assertFalse((folder / "冒烟结果.json").exists())

    def test_required_repeats_cannot_be_filled_with_duplicate_indices(self):
        data = json.loads(self.requirements.read_text())
        data["required_cases"][0]["runs"] = 3
        self.requirements.write_text(json.dumps(data))
        run = self.k.start_smoke_run(self.p, self.stage, "示例模型")
        self.k.finish_smoke_run(self.p, run, [self.case(), self.case(), self.case()])
        self.assertFalse(self.k.check_smoke(self.p, self.stage)[0])

    def test_required_repeats_are_checked_in_current_batch(self):
        data = json.loads(self.requirements.read_text())
        data["required_cases"][0]["runs"] = 3
        self.requirements.write_text(json.dumps(data))
        run = self.k.start_smoke_run(self.p, self.stage, "示例模型")
        self.k.finish_smoke_run(self.p, run, [self.case(index=i) for i in (1, 2, 3)])
        self.assertTrue(self.k.check_smoke(self.p, self.stage)[0])
        run = self.k.start_smoke_run(self.p, self.stage, "示例模型")
        self.k.finish_smoke_run(self.p, run, [self.case()])
        self.assertFalse(self.k.check_smoke(self.p, self.stage)[0])

    def test_unknown_status_or_non_boolean_schema_check_fails(self):
        for value in (self.case("未知"), dict(self.case(), schema_valid="true")):
            run = self.k.start_smoke_run(self.p, self.stage, "示例模型")
            self.k.finish_smoke_run(self.p, run, [value])
            self.assertFalse(self.k.check_smoke(self.p, self.stage)[0])

    def test_model_must_match_confirmed_requirements(self):
        run = self.k.start_smoke_run(self.p, self.stage, "别的模型")
        self.k.finish_smoke_run(self.p, run, [self.case()])
        self.assertFalse(self.k.check_smoke(self.p, self.stage)[0])

    def test_late_finish_cannot_replace_newer_running_batch(self):
        old = self.k.start_smoke_run(self.p, self.stage, "示例模型")
        new = self.k.start_smoke_run(self.p, self.stage, "示例模型")
        with self.assertRaises(ValueError):
            self.k.finish_smoke_run(self.p, old, [self.case()])
        saved = json.loads((self.p / "docs/evidence" / self.stage / "冒烟结果.json").read_text())
        self.assertEqual(saved["run_id"], new["run_id"])
        self.assertFalse(self.k.check_smoke(self.p, self.stage)[0])

    def test_untracked_added_deleted_and_same_mtime_changes_invalidate(self):
        import os
        before = self.k.fingerprint(self.p)
        time = self.source.stat().st_mtime
        self.source.write_text("print(2)")
        os.utime(self.source, (time, time))
        self.assertNotEqual(before, self.k.fingerprint(self.p))
        before = self.k.fingerprint(self.p)
        added = self.p / "backend/new.py"
        added.write_text("new")
        self.assertNotEqual(before, self.k.fingerprint(self.p))
        before = self.k.fingerprint(self.p)
        added.unlink()
        self.assertNotEqual(before, self.k.fingerprint(self.p))

    def test_generated_outputs_and_secrets_do_not_change_fingerprint(self):
        before = self.k.fingerprint(self.p)
        for name in ("docs/evidence/阶段2-1/是否表.md", "docs/项目状态.md",
                     "docs/流程状态.txt", "docs/本阶段任务.md",
                     "backend/.env", "backend/.env.local", "data/records.db",
                     "frontend/node_modules/pkg/index.js", "backend/__pycache__/x.pyc"):
            p = self.p / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("临时内容")
        self.assertEqual(before, self.k.fingerprint(self.p))

    def test_prompt_requirements_and_validator_change_fingerprint(self):
        for p in (self.p / "prompts/prompt.txt", self.requirements,
                  self.root / "verify.sh"):
            before = self.k.fingerprint(self.p)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("已变更")
            self.assertNotEqual(before, self.k.fingerprint(self.p))

    def test_symbolic_source_link_is_rejected_without_reading_target(self):
        outside = self.root / "private.txt"
        outside.write_text("不会被读取")
        (self.p / "backend/external").symlink_to(outside)
        with self.assertRaises(ValueError):
            self.k.fingerprint(self.p)

    def test_seal_gate_and_source_change(self):
        self.success()
        before = self.k.fingerprint(self.p)
        self.assertTrue(self.k.seal(self.p, self.stage, before, 0)[0])
        self.assertTrue(self.k.check_gate(self.p, self.stage)[0])
        self.source.write_text("changed")
        self.assertFalse(self.k.check_gate(self.p, self.stage)[0])

    def test_change_during_verification_does_not_create_success_receipt(self):
        self.success()
        before = self.k.fingerprint(self.p)
        self.source.write_text("changed")
        self.assertFalse(self.k.seal(self.p, self.stage, before, 0)[0])
        self.assertFalse(self.k.check_gate(self.p, self.stage)[0])

    def test_failed_verification_overwrites_previous_success(self):
        self.success()
        before = self.k.fingerprint(self.p)
        self.k.seal(self.p, self.stage, before, 0)
        self.k.seal(self.p, self.stage, before, 1)
        self.assertFalse(self.k.check_gate(self.p, self.stage)[0])

    def test_changed_smoke_record_invalidates_gate(self):
        self.success()
        self.k.seal(self.p, self.stage, self.k.fingerprint(self.p), 0)
        self.k.start_smoke_run(self.p, self.stage, "示例模型")
        self.assertFalse(self.k.check_gate(self.p, self.stage)[0])

    def test_no_code_stage_can_be_sealed_without_model(self):
        self.assertTrue(self.k.seal(self.p, "阶段0", self.k.fingerprint(self.p), 0)[0])
        self.assertTrue(self.k.check_gate(self.p, "阶段0")[0])

    def test_missing_or_wrong_stage_receipt_is_rejected(self):
        self.assertFalse(self.k.check_gate(self.p, "阶段0")[0])
        self.k.seal(self.p, "阶段0", self.k.fingerprint(self.p), 0)
        self.assertFalse(self.k.check_gate(self.p, "阶段1")[0])

    def test_source_changed_during_model_run_cannot_pass(self):
        run = self.k.start_smoke_run(self.p, self.stage, "示例模型")
        self.source.write_text("changed")
        self.k.finish_smoke_run(self.p, run, [self.case()])
        self.assertFalse(self.k.check_smoke(self.p, self.stage)[0])

    def test_new_verification_immediately_invalidates_previous_success(self):
        self.seal_no_code()
        started = self.k.begin_verification(self.p, "阶段0")
        self.assertFalse(self.k.check_gate(self.p, "阶段0")[0])
        self.assertEqual(started["status"], "待验")

    def seal_no_code(self):
        self.assertTrue(self.k.seal(self.p, "阶段0", self.k.fingerprint(self.p), 0)[0])

    def test_old_verification_cannot_complete_over_newer_batch(self):
        older = self.k.begin_verification(self.p, "阶段0")
        newer = self.k.begin_verification(self.p, "阶段0")
        self.assertFalse(self.k.seal(self.p, "阶段0", older["started_hash"],
                                    0, older["verification_id"])[0])
        self.assertFalse(self.k.check_gate(self.p, "阶段0")[0])
        self.assertTrue(self.k.seal(self.p, "阶段0", newer["started_hash"],
                                   0, newer["verification_id"])[0])
        self.assertEqual(self.k.check_gate(self.p, "阶段0")[1], newer["verification_id"])



if __name__ == "__main__":
    unittest.main()
