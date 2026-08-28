#!/usr/bin/env python3
from __future__ import annotations

import asyncio
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from ringer import (  # noqa: E402
    AppConfig,
    Manifest,
    TaskSpec,
    Verifier,
    lint_manifest,
    main,
)


LONG_SPEC = (
    "Create the requested artifact in the current working directory, keep the change scoped, "
    "and make the check command able to explain any failure clearly."
)

GOOD_CHECK = (
    "test -s output.txt && grep -q 'ready' output.txt || "
    "{ echo 'FAIL: output.txt missing or does not contain ready'; exit 1; }"
)


class LintManifestTests(unittest.TestCase):
    def manifest(
        self,
        tasks: list[dict[str, object]],
        *,
        worktrees: bool = False,
        max_parallel: int = 1,
    ) -> Manifest:
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)
        obj: dict[str, object] = {
            "run_name": "lint-test",
            "workdir": str(Path(temp_dir.name) / "work"),
            "max_parallel": max_parallel,
            "worktrees": worktrees,
            "tasks": tasks,
        }
        if worktrees:
            obj["repo"] = temp_dir.name
        return Manifest.from_obj(obj)

    def task(
        self,
        key: str = "one",
        *,
        spec: str = LONG_SPEC,
        check: str = GOOD_CHECK,
        expect_files: list[str] | None = None,
    ) -> dict[str, object]:
        return {
            "key": key,
            "spec": spec,
            "check": check,
            "expect_files": ["output.txt"] if expect_files is None else expect_files,
            "verified": "the output file exists and contains the expected content",
        }

    def assertHasFinding(self, findings: list[str], expected: str) -> None:
        self.assertIn(expected, findings, f"expected lint finding not found: {expected}\nfindings: {findings}")

    def test_task_fields_must_be_strings(self) -> None:
        with self.assertRaisesRegex(ValueError, r"task one: check must be a string"):
            self.manifest([self.task(check=["cmd1", "cmd2"])])  # type: ignore[arg-type]

        with self.assertRaisesRegex(ValueError, r"task one: spec must be a string"):
            self.manifest([self.task(spec=["write it"])])  # type: ignore[arg-type]

        task = self.task()
        task["key"] = 123
        with self.assertRaisesRegex(ValueError, r"task key must be a string"):
            self.manifest([task])

    def test_worktrees_requires_repo(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            manifest = {
                "run_name": "worktrees-requires-repo",
                "workdir": str(Path(root) / "work"),
                "worktrees": True,
                "tasks": [self.task()],
            }
            with self.assertRaisesRegex(
                ValueError,
                r"worktrees requires repo; without repo, no worktrees would be created",
            ):
                Manifest.from_obj(manifest)

    def test_worktrees_with_repo_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            manifest = {
                "run_name": "worktrees-with-repo",
                "workdir": str(Path(root) / "work"),
                "worktrees": True,
                "repo": root,
                "tasks": [self.task()],
            }
            parsed = Manifest.from_obj(manifest)
        self.assertTrue(parsed.worktrees)
        self.assertEqual(Path(root).resolve(), parsed.repo)

    def test_w1_unverifiable_check(self) -> None:
        manifest = self.manifest([self.task(check="echo ok && echo done")])
        self.assertHasFinding(
            lint_manifest(manifest),
            "one: check cannot fail, so the task cannot be verified.",
        )

        commented_manifest = self.manifest([self.task(check="true # worker left the placeholder check")])
        self.assertHasFinding(
            lint_manifest(commented_manifest),
            "one: check cannot fail, so the task cannot be verified.",
        )

        quoted_hash_manifest = self.manifest(
            [
                self.task(
                    check=(
                        "test -s '#artifact' || "
                        "{ echo 'FAIL: #artifact missing'; exit 1; }"
                    )
                )
            ]
        )
        self.assertNotIn(
            "one: check cannot fail, so the task cannot be verified.",
            lint_manifest(quoted_hash_manifest),
        )

    def test_w2_silent_check(self) -> None:
        manifest = self.manifest([self.task(check="test -f output.txt && [ -s report.md ]")])
        self.assertHasFinding(
            lint_manifest(manifest),
            "one: check may fail without printing why; retry prompt and eval log depend on failure output.",
        )

        diff_manifest = self.manifest([self.task(check="diff -q expected.txt actual.txt")])
        self.assertHasFinding(
            lint_manifest(diff_manifest),
            "one: check may fail without printing why; retry prompt and eval log depend on failure output.",
        )

        diff_with_output = self.manifest(
            [self.task(check="diff -q a b || { echo FAIL; diff a b; exit 1; }")]
        )
        self.assertNotIn(
            "one: check may fail without printing why; retry prompt and eval log depend on failure output.",
            lint_manifest(diff_with_output),
        )

        grep_manifest = self.manifest([self.task(check="grep -q x file")])
        self.assertHasFinding(
            lint_manifest(grep_manifest),
            "one: check may fail without printing why; retry prompt and eval log depend on failure output.",
        )

        probe_chain_manifest = self.manifest([self.task(check="grep -q x file && test -s output.txt")])
        self.assertHasFinding(
            lint_manifest(probe_chain_manifest),
            "one: check may fail without printing why; retry prompt and eval log depend on failure output.",
        )

    def test_w3_worktree_deliverable_loss(self) -> None:
        manifest = self.manifest(
            [self.task(expect_files=["report.md"])],
            worktrees=True,
        )
        self.assertHasFinding(
            lint_manifest(manifest),
            "one: deliverable would be deleted with the worktree; write it outside the worktree or export it in the check.",
        )

    def test_w4_worktree_commit_loss(self) -> None:
        spec = LONG_SPEC + " After the file is correct, run git commit with a concise message."
        manifest = self.manifest(
            [self.task(spec=spec, expect_files=[])],
            worktrees=True,
        )
        self.assertHasFinding(
            lint_manifest(manifest),
            "one: worker commits die with the worktree; have the worker leave changes uncommitted and export the diff in the check.",
        )

        negated_spec = LONG_SPEC + " Do NOT run `git commit`; leave the worktree uncommitted."
        negated_manifest = self.manifest(
            [self.task(spec=negated_spec, expect_files=[])],
            worktrees=True,
        )
        self.assertNotIn(
            "one: worker commits die with the worktree; have the worker leave changes uncommitted and export the diff in the check.",
            lint_manifest(negated_manifest),
        )

    def test_w5_serial_fan_out(self) -> None:
        manifest = self.manifest(
            [
                self.task("one", expect_files=["one.txt"]),
                self.task("two", expect_files=["two.txt"]),
                self.task("three", expect_files=["three.txt"]),
            ],
            max_parallel=1,
        )
        self.assertHasFinding(
            lint_manifest(manifest),
            "manifest: tasks will run serially; set max_parallel.",
        )

    def test_w6_write_collision(self) -> None:
        manifest = self.manifest(
            [
                self.task("one", expect_files=["/tmp/shared-deliverable.txt"]),
                self.task("two", expect_files=["/tmp/shared-deliverable.txt"]),
            ],
            worktrees=False,
        )
        self.assertHasFinding(
            lint_manifest(manifest),
            "manifest: write collision on /tmp/shared-deliverable.txt: listed by one, two.",
        )

    def test_w6_relative_paths_do_not_collide(self) -> None:
        # Relative expect_files resolve inside each task's own directory —
        # many tasks emitting report.md/extraction.json is the NORMAL swarm
        # shape, not a collision (first field use caught this false positive).
        manifest = self.manifest(
            [
                self.task("one", expect_files=["report.md"]),
                self.task("two", expect_files=["report.md"]),
                self.task("three", expect_files=["report.md"]),
            ],
            worktrees=False,
            max_parallel=3,
        )
        self.assertEqual([], lint_manifest(manifest))

    def test_verifier_expands_user_expect_files(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            taskdir = Path(root) / "task"
            home = Path(root) / "home"
            taskdir.mkdir()
            home.mkdir()
            (home / "report.md").write_text("done\n", encoding="utf-8")
            previous_home = os.environ.get("HOME")
            os.environ["HOME"] = str(home)
            try:
                task = TaskSpec(
                    key="one",
                    spec=LONG_SPEC,
                    check="true",
                    expect_files=("~/report.md",),
                )
                result = asyncio.run(Verifier().verify(task, taskdir))
            finally:
                if previous_home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = previous_home
        self.assertTrue(result.ok, result.raw_output_excerpt)
        self.assertEqual((), result.missing_files)

    def test_w7_underspecified_spec(self) -> None:
        manifest = self.manifest([self.task(spec="Do it.")])
        self.assertHasFinding(
            lint_manifest(manifest),
            "one: spec is probably underspecified; workers are stateless and cannot ask questions.",
        )

    def test_w8_file_pointer_spec(self) -> None:
        findings = lint_manifest(
            self.manifest(
                [self.task(spec="Read the instructions at /tmp/brief.md and do exactly what it says in there.")]
            )
        )
        self.assertTrue(
            any("pointer to an instruction file" in item for item in findings),
            f"expected pointer-spec finding, got: {findings}",
        )

        # A long spec that references files as source material is fine.
        long_spec = (
            "You are a read-only reviewer. Study the code bundle at /tmp/bundle.txt as your "
            "source material, then write ./review.md with sections VERDICT, BLOCKERS, and "
            "EVIDENCE. For every blocker cite file and line from the bundle. Do not modify "
            "any file other than ./review.md. The review must judge correctness, security, "
            "and migration safety, and each claim needs a quoted line of code as evidence. "
            "If a concern cannot be verified from the bundle alone, list it under an "
            "UNCERTAIN heading instead of asserting it. Keep the verdict to one sentence. "
            "Write plainly; the reader is a busy maintainer deciding whether to merge today."
        )
        findings = lint_manifest(self.manifest([self.task(spec=long_spec, expect_files=["review.md"])]))
        self.assertFalse(
            any("pointer to an instruction file" in item for item in findings),
            f"long contextual spec should not be flagged: {findings}",
        )

    def test_w9_missing_expect_files(self) -> None:
        findings = lint_manifest(self.manifest([self.task(expect_files=[])]))
        self.assertTrue(
            any("no expect_files" in item for item in findings),
            f"expected missing-expect_files finding, got: {findings}",
        )

        # Worktrees mode legitimately exports deliverables outside the
        # taskdir (patch export), so the finding must not fire there.
        findings = lint_manifest(
            self.manifest([self.task(expect_files=[])], worktrees=True)
        )
        self.assertFalse(
            any("no expect_files" in item for item in findings),
            f"worktrees manifest should not be flagged for expect_files: {findings}",
        )

    def test_task_type_canonical_is_clean(self) -> None:
        task = self.task()
        task["task_type"] = "code-review"
        findings = lint_manifest(self.manifest([task]), include_model_log_nudges=True)
        self.assertFalse(
            any("task_type" in item for item in findings),
            f"canonical task_type should not be flagged, got: {findings}",
        )

    def test_task_type_typo_suggests_nearest_canonical(self) -> None:
        task = self.task()
        task["task_type"] = "review"
        findings = lint_manifest(self.manifest([task]), include_model_log_nudges=True)
        self.assertTrue(
            any("code-review" in item for item in findings),
            f"expected a code-review suggestion finding, got: {findings}",
        )

    def test_task_type_unrelated_lists_full_vocabulary(self) -> None:
        task = self.task()
        task["task_type"] = "zzz-totally-unrelated-nonsense"
        findings = lint_manifest(self.manifest([task]), include_model_log_nudges=True)
        self.assertTrue(
            any(
                "not in the canonical vocabulary" in item and "did you mean" not in item
                for item in findings
            ),
            f"expected a full-vocabulary finding with no suggestion, got: {findings}",
        )

    def test_task_type_empty_keeps_original_nudge_only(self) -> None:
        task = self.task()
        task["task_type"] = ""
        findings = lint_manifest(self.manifest([task]), include_model_log_nudges=True)
        self.assertHasFinding(
            findings,
            "one: no task_type; the model log buckets this as (untyped) — "
            "name one (e.g. code-feature, research, image-gen) so './ringer.py models' can guide routing.",
        )
        self.assertFalse(
            any("not in the canonical vocabulary" in item for item in findings),
            f"empty task_type should not trigger the canonical-vocabulary finding, got: {findings}",
        )

    def test_compliant_manifest_is_clean(self) -> None:
        manifest = self.manifest(
            [
                self.task("one", expect_files=["one.txt"]),
                self.task("two", expect_files=["two.txt"]),
                self.task("three", expect_files=["three.txt"]),
            ],
            max_parallel=2,
        )
        self.assertEqual([], lint_manifest(manifest), "compliant manifest should have no lint findings")

    def test_templates_are_clean(self) -> None:
        # Every kit ships one or more manifest skeletons (manifest.json plus
        # optional manifest-round*.json for multi-round kits).
        template_paths = sorted((ROOT / "templates").glob("*/manifest*.json"))
        self.assertTrue(template_paths, "expected templates/*/manifest*.json files to exist")
        for path in template_paths:
            with self.subTest(template=path.name):
                manifest = Manifest.from_path(path)
                findings = lint_manifest(manifest)
                self.assertEqual([], findings, f"{path} should lint clean, got: {findings}")


CONFIG_TOML = (
    '[engines.mock]\n'
    'bin = "python3"\n'
    'args_template = ["-c", "print(1)", "{spec}"]\n'
)


class ConfiguredEngineLintTests(unittest.TestCase):
    LONG_SPEC = (
        "Create the requested artifact in the current working directory, keep the change scoped, "
        "and make the check command able to explain any failure clearly."
    )

    GOOD_CHECK = (
        "test -s output.txt && grep -q 'ready' output.txt || "
        "{ echo 'FAIL: output.txt missing or does not contain ready'; exit 1; }"
    )

    def manifest_obj(self, engine: str, root: str) -> dict[str, object]:
        return {
            "run_name": "configured-engine-lint",
            "workdir": str(Path(root) / "work"),
            "tasks": [
                {
                    "key": "one",
                    "engine": engine,
                    "spec": self.LONG_SPEC,
                    "check": self.GOOD_CHECK,
                    "expect_files": ["output.txt"],
                    "verified": "the output file exists and contains the expected content",
                }
            ],
        }

    def write_config(self, root: str) -> Path:
        config_path = Path(root) / "config.toml"
        config_path.write_text(CONFIG_TOML, encoding="utf-8")
        return config_path

    def run_lint_cli(
        self,
        manifest_path: Path,
        config_path: Path | None,
    ) -> tuple[int, str, str]:
        old = os.environ.get("RINGER_NO_SELF_UPDATE")
        os.environ["RINGER_NO_SELF_UPDATE"] = "1"
        stdout = io.StringIO()
        stderr = io.StringIO()
        try:
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                try:
                    argv = ["lint", str(manifest_path)]
                    if config_path is not None:
                        argv.extend(["--config", str(config_path)])
                    result = main(argv)
                except SystemExit as exc:
                    result = int(exc.code) if isinstance(exc.code, int) else 1
        finally:
            if old is None:
                os.environ.pop("RINGER_NO_SELF_UPDATE", None)
            else:
                os.environ["RINGER_NO_SELF_UPDATE"] = old
        return result, stdout.getvalue(), stderr.getvalue()

    def test_opt_in_api_rejects_unknown_engine(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            config = AppConfig.load(self.write_config(root))
            manifest = Manifest.from_obj(self.manifest_obj("no-such-engine", root))
            findings = lint_manifest(
                manifest,
                config=config,
                check_configured_engines=True,
            )
        self.assertTrue(
            any(
                "not configured" in item and "no-such-engine" in item
                for item in findings
            ),
            f"expected an unknown-engine finding, got: {findings}",
        )

    def test_opt_in_api_accepts_configured_engine(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            config = AppConfig.load(self.write_config(root))
            manifest = Manifest.from_obj(self.manifest_obj("mock", root))
            findings = lint_manifest(
                manifest,
                config=config,
                check_configured_engines=True,
            )
        self.assertFalse(
            any("not configured" in item for item in findings),
            f"configured engine should lint clean, got: {findings}",
        )

    def test_default_api_remains_config_free(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            manifest = Manifest.from_obj(self.manifest_obj("no-such-engine", root))
            findings = lint_manifest(manifest)
        self.assertFalse(
            any("not configured" in item for item in findings),
            "default lint must not validate engines without a config",
        )

    def test_opt_in_api_without_config_raises(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            manifest = Manifest.from_obj(self.manifest_obj("no-such-engine", root))
        with self.assertRaisesRegex(ValueError, r"check_configured_engines=True requires a config"):
            lint_manifest(manifest, check_configured_engines=True)

    def test_cli_explicit_config_rejects_unknown_engine(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            config_path = self.write_config(root)
            manifest_path = Path(root) / "manifest.json"
            manifest_path.write_text(
                json.dumps(self.manifest_obj("no-such-engine", root)),
                encoding="utf-8",
            )
            code, output, _ = self.run_lint_cli(manifest_path, config_path)
        self.assertEqual(1, code)
        self.assertIn("no-such-engine", output)
        self.assertIn("not configured", output)

    def test_cli_explicit_config_accepts_configured_engine(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            config_path = self.write_config(root)
            manifest_path = Path(root) / "manifest.json"
            manifest_path.write_text(
                json.dumps(self.manifest_obj("mock", root)),
                encoding="utf-8",
            )
            code, output, _ = self.run_lint_cli(manifest_path, config_path)
        self.assertEqual(0, code)
        self.assertIn("lint: clean", output)

    def test_cli_without_config_stays_clean_for_unknown_engine(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            manifest_path = Path(root) / "manifest.json"
            manifest_path.write_text(
                json.dumps(self.manifest_obj("no-such-engine", root)),
                encoding="utf-8",
            )
            code, output, _ = self.run_lint_cli(manifest_path, None)
        self.assertEqual(0, code)
        self.assertIn("lint: clean", output)

    def test_cli_config_load_failure_is_error(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            manifest_path = Path(root) / "manifest.json"
            manifest_path.write_text(
                json.dumps(self.manifest_obj("mock", root)),
                encoding="utf-8",
            )
            missing_config = Path(root) / "does-not-exist.toml"
            code, output, stderr = self.run_lint_cli(manifest_path, missing_config)
        self.assertNotEqual(0, code)
        self.assertIn("config file not found", stderr)
        self.assertNotIn("lint: clean", output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
