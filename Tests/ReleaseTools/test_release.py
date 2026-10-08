"""Regression coverage for build identity, failed gates, and artifact promotion."""
import argparse
import contextlib
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/release.py"
spec = importlib.util.spec_from_file_location("rack_release", SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = {"commit": "a" * 40, "hasChanges": False, "fingerprint": "b" * 64}

    def report(self, directory, architecture="arm64"):
        directory.mkdir(parents=True)
        steps = []
        evidence = {}
        for name in sorted(release.REQUIRED_STEPS):
            log = directory / f"{name}.log"
            log.write_text("✓ 10 checks passed\n")
            evidence[log.name] = release.sha256(log)
            steps.append({"name": name, "status": "passed", "checks": 10, "log": log.name})
        data = {"schemaVersion": 1, "kind": "verification", "status": "passed",
                "source": self.source, "steps": steps, "evidence": evidence,
                "platform": {"architecture": architecture}}
        path = directory / "report.json"
        release.write_json(path, data)
        return path

    def smoke(self, checksum):
        return {"archiveSha256": checksum, "tester": "Test fixture",
                "testedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
                "macOS": "15.7", "architecture": "arm64",
                "checks": {name: {"result": "passed", "notes": ""} for name in release.SMOKE_CHECKS}}

    def candidate(self, channel="preview"):
        directory = self.root / "candidate"
        package = directory / "package"
        package.mkdir(parents=True)
        archive = package / "Rack.zip"
        archive.write_bytes(b"an immutable archive fixture")
        checksum = release.sha256(archive)
        verification = []
        for architecture in ("arm64", "x86_64"):
            report = self.report(directory / "validation" / architecture, architecture)
            verification.append({"path": str(report.relative_to(directory)), "sha256": release.sha256(report)})
        manifest = {"schemaVersion": 1, "kind": "release-candidate", "status": "passed", "channel": channel,
                    "version": "0.0.1", "build": "1", "source": self.source,
                    "package": {"path": "package/Rack.zip", "sha256": checksum, "notarized": channel == "stable"},
                    "verification": verification}
        release.write_json(directory / "manifest.json", manifest)
        release.write_json(package / "release-info.json", {
            "sha256": checksum, "archive": archive.name, "version": "0.0.1", "build": "1",
            "sourceCommit": self.source["commit"], "sourceHasChanges": False, "notarized": channel == "stable"})
        (package / "SHA256SUMS").write_text(f"{checksum}  {archive.name}\n")
        (package / "release-notes.md").write_text("A fixture release.\n")
        manifest["packageFiles"] = {str(path.relative_to(directory)): release.sha256(path) for path in package.iterdir()}
        release.write_json(directory / "manifest.json", manifest)
        release.write_json(directory / "manual-smoke.json", self.smoke(checksum))
        return directory, manifest

    def test_verification_rejects_other_source_and_missing_gates(self):
        path = self.report(self.root / "verification")
        self.assertEqual(release.validate_verification(path, self.source)["status"], "passed")
        changed_source = dict(self.source, fingerprint="c" * 64)
        with self.assertRaisesRegex(release.BuildError, "different source"):
            release.validate_verification(path, changed_source)
        data = release.read_json(path)
        data["steps"] = data["steps"][:-1]
        release.write_json(path, data)
        with self.assertRaisesRegex(release.BuildError, "incomplete"):
            release.validate_verification(path, self.source)

    def test_changed_evidence_cannot_be_reused(self):
        path = self.report(self.root / "verification")
        (path.parent / "debug-tests.log").write_text("different results")
        with self.assertRaisesRegex(release.BuildError, "evidence changed"):
            release.validate_verification(path, self.source)

    def test_failed_gate_is_retained_and_stops_remaining_tests(self):
        step = {"name": "boundaries", "status": "failed", "exitCode": 1, "log": "boundaries.log"}
        with mock.patch.object(release.subprocess, "check_output", return_value="Swift fixture"), \
                mock.patch.object(release, "command_step", return_value=step) as runner:
            with self.assertRaisesRegex(release.BuildError, "boundaries failed"):
                release.verification(self.root / "failed", self.source, self.root)
        self.assertEqual(runner.call_count, 1)
        report = release.read_json(self.root / "failed/report.json")
        self.assertEqual(report["status"], "failed")
        self.assertTrue((self.root / "failed/summary.md").exists())

    def test_failed_commands_print_diagnostics_and_retain_full_logs(self):
        cases = [
            ("compiler", "import sys; print('fixture compiler error', file=sys.stderr); sys.exit(2)", 2),
            ("debug-tests", "print('fixture missing test tally')", 0),
        ]
        for name, script, exit_code in cases:
            with self.subTest(name=name):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    step = release.command_step(name, [sys.executable, "-c", script], self.root)
                self.assertEqual(step["status"], "failed")
                self.assertEqual(step["exitCode"], exit_code)
                diagnostic = (self.root / step["log"]).read_text().strip()
                self.assertIn(diagnostic, output.getvalue())
                self.assertIn(f"{name} failed", output.getvalue())

    def test_screenshot_option_preserves_other_debug_and_optimized_tests(self):
        def passed_step(name, *_args, **_kwargs):
            return {"name": name, "status": "passed", "checks": 10, "log": name + ".log"}

        for skip in (False, True):
            with self.subTest(skip=skip):
                with mock.patch.object(release.subprocess, "check_output", return_value="Swift fixture"), \
                        mock.patch.object(release, "command_step", side_effect=passed_step) as runner, \
                        mock.patch.object(release, "source_state", return_value=self.source):
                    path = release.verification(self.root / f"screenshots-{skip}", self.source, self.root,
                                                skip_theme_screenshots=skip)
                commands = {call.args[0]: call.args[1] for call in runner.call_args_list}
                debug = ["swift", "run", "RackTests"]
                if skip:
                    debug.append("--skip-theme-screenshots")
                self.assertEqual(commands["debug-tests"], debug)
                self.assertEqual(commands["optimized-tests"], [
                    "swift", "run", "-c", "release", "-Xswiftc", "-enable-testing", "RackTests", "--headless"])
                report = release.read_json(path)
                self.assertEqual(report["status"], "passed")
                self.assertEqual(report["themeScreenshots"], not skip)
                self.assertEqual(set(commands), release.REQUIRED_STEPS)

    def test_source_change_during_tests_invalidates_passes(self):
        def passed_step(name, *_args, **_kwargs):
            return {"name": name, "status": "passed", "checks": 10, "log": name + ".log"}
        with mock.patch.object(release.subprocess, "check_output", return_value="Swift fixture"), \
                mock.patch.object(release, "command_step", side_effect=passed_step), \
                mock.patch.object(release, "source_state", return_value=dict(self.source, fingerprint="changed")):
            with self.assertRaisesRegex(release.BuildError, "Source changed"):
                release.verification(self.root / "changed", self.source, self.root)
        self.assertEqual(release.read_json(self.root / "changed/report.json")["status"], "failed")

    def test_failed_verification_never_starts_packaging(self):
        args = argparse.Namespace(command="test-build", verification=None)
        with mock.patch.object(release, "source_state", return_value=self.source), \
                mock.patch.object(release, "bundle_version", return_value={"version": "0.0.1", "build": "1"}), \
                mock.patch.object(release, "collect_verification", side_effect=release.BuildError("test failed")), \
                mock.patch.object(release, "command_step") as packaging:
            with self.assertRaisesRegex(release.BuildError, "test failed"):
                release.prepare_build(args, self.root)
        packaging.assert_not_called()
        self.assertFalse((self.root / "dist/test-builds/latest.json").exists())
        manifests = list((self.root / "dist/test-builds").rglob("manifest.json"))
        self.assertEqual(len(manifests), 1)
        self.assertEqual(release.read_json(manifests[0])["status"], "failed")

    def test_dirty_work_cannot_be_a_release_candidate(self):
        args = argparse.Namespace(command="candidate", preview=True, verification=None, tag=None)
        with mock.patch.object(release, "source_state", return_value=dict(self.source, hasChanges=True)), \
                mock.patch.object(release, "bundle_version", return_value={"version": "0.0.1", "build": "1"}):
            with self.assertRaisesRegex(release.BuildError, "committed, clean"):
                release.prepare_build(args, self.root)
        self.assertFalse((self.root / "dist").exists())

    def test_existing_build_directory_cannot_be_overwritten(self):
        output = release.new_directory(self.root / "immutable")
        (output / "archive.zip").write_bytes(b"keep me")
        with self.assertRaisesRegex(release.BuildError, "immutable"):
            release.new_directory(output)
        self.assertEqual((output / "archive.zip").read_bytes(), b"keep me")

    def test_changed_archive_or_report_blocks_promotion(self):
        directory, manifest = self.candidate()
        release.validate_candidate(directory)
        archive = directory / manifest["package"]["path"]
        original = archive.read_bytes()
        archive.write_bytes(b"a different build")
        with self.assertRaisesRegex(release.BuildError, "archive changed"):
            release.validate_candidate(directory)
        archive.write_bytes(original)
        report = directory / manifest["verification"][0]["path"]
        report.write_text(report.read_text() + " ")
        with self.assertRaisesRegex(release.BuildError, "report changed"):
            release.validate_candidate(directory)

    def test_package_metadata_change_blocks_promotion(self):
        directory, _ = self.candidate()
        metadata = release.read_json(directory / "package/release-info.json")
        metadata["version"] = "9.9.9"
        release.write_json(directory / "package/release-info.json", metadata)
        with self.assertRaisesRegex(release.BuildError, "package file changed"):
            release.validate_candidate(directory)

    def test_stable_requires_notarization_and_both_architectures(self):
        directory, manifest = self.candidate("stable")
        release.validate_candidate(directory)
        manifest["verification"] = manifest["verification"][:1]
        release.write_json(directory / "manifest.json", manifest)
        with self.assertRaisesRegex(release.BuildError, "both Apple silicon and Intel"):
            release.validate_candidate(directory)
        manifest["package"]["notarized"] = False
        release.write_json(directory / "manifest.json", manifest)
        package = release.read_json(directory / "package/release-info.json")
        package["notarized"] = False
        release.write_json(directory / "package/release-info.json", package)
        manifest["packageFiles"]["package/release-info.json"] = release.sha256(directory / "package/release-info.json")
        release.write_json(directory / "manifest.json", manifest)
        with self.assertRaisesRegex(release.BuildError, "must be notarized"):
            release.validate_candidate(directory)

    def test_manual_checks_are_bound_to_archive_and_cannot_be_pending(self):
        record = self.smoke("a" * 64)
        release.validate_smoke(record, "a" * 64)
        with self.assertRaisesRegex(release.BuildError, "exact archive"):
            release.validate_smoke(record, "b" * 64)
        record["checks"]["listening_and_bypass"]["result"] = "pending"
        with self.assertRaisesRegex(release.BuildError, "listening_and_bypass"):
            release.validate_smoke(record, "a" * 64)
        record["checks"]["listening_and_bypass"]["result"] = "passed"
        record["checks"]["microphone_monitoring"] = {"result": "skipped", "notes": "No microphone available"}
        release.validate_smoke(record, "a" * 64)

    def test_mismatched_tag_never_invokes_github(self):
        directory, _ = self.candidate()
        with mock.patch.object(release, "git", return_value=b"different-commit\n"), \
                mock.patch.object(release.subprocess, "run") as github:
            with self.assertRaisesRegex(release.BuildError, "different commit"):
                release.draft_release(directory, self.root)
        github.assert_not_called()

    def test_preview_smoke_skip_preserves_archive_and_verification_gates(self):
        directory, manifest = self.candidate()
        (directory / "manual-smoke.json").unlink()
        with self.assertRaises(FileNotFoundError):
            release.validate_candidate(directory)
        release.validate_candidate(directory, skip_smoke=True)
        archive = directory / manifest["package"]["path"]
        original = archive.read_bytes()
        archive.write_bytes(b"a changed archive")
        with self.assertRaisesRegex(release.BuildError, "archive changed"):
            release.validate_candidate(directory, skip_smoke=True)
        archive.write_bytes(original)
        report = directory / manifest["verification"][0]["path"]
        report.write_text(report.read_text() + " ")
        with self.assertRaisesRegex(release.BuildError, "report changed"):
            release.validate_candidate(directory, skip_smoke=True)

    def test_stable_release_cannot_skip_smoke(self):
        directory, _ = self.candidate("stable")
        with self.assertRaisesRegex(release.BuildError, "only.*preview"):
            release.validate_candidate(directory, skip_smoke=True)

    def test_preview_draft_records_skipped_smoke_without_claiming_a_pass(self):
        directory, manifest = self.candidate()
        (directory / "manual-smoke.json").unlink()
        with mock.patch.object(release, "git", return_value=(self.source["commit"] + "\n").encode()), \
                mock.patch.object(release, "remote_tag_commit", return_value=self.source["commit"]), \
                mock.patch.object(release.subprocess, "run") as github:
            release.draft_release(directory, self.root, skip_smoke=True)
        record = release.read_json(directory / "manual-smoke-skipped.json")
        self.assertEqual(record["archiveSha256"], manifest["package"]["sha256"])
        self.assertEqual(record["status"], "skipped")
        self.assertTrue(record["checksRemainPending"])
        self.assertFalse((directory / "manual-smoke.json").exists())
        command = github.call_args.args[0]
        self.assertIn(str(directory / "manual-smoke-skipped.json"), command)
        self.assertIn(str(directory / manifest["package"]["path"]), command)
        self.assertIn("--draft", command)
        self.assertIn("--prerelease", command)

    def test_draft_uploads_existing_archive_without_rebuilding(self):
        directory, manifest = self.candidate()
        with mock.patch.object(release, "git", return_value=(self.source["commit"] + "\n").encode()), \
                mock.patch.object(release, "remote_tag_commit", return_value=self.source["commit"]), \
                mock.patch.object(release.subprocess, "run") as github:
            release.draft_release(directory, self.root)
        command = github.call_args.args[0]
        self.assertEqual(command[:3], ["gh", "release", "create"])
        self.assertIn(str(directory / manifest["package"]["path"]), command)
        self.assertIn("--draft", command)
        self.assertIn("--prerelease", command)

    def test_remote_tag_mismatch_never_creates_a_release(self):
        directory, _ = self.candidate()
        with mock.patch.object(release, "git", return_value=(self.source["commit"] + "\n").encode()), \
                mock.patch.object(release, "remote_tag_commit", return_value="different-remote-commit"), \
                mock.patch.object(release.subprocess, "run") as github:
            with self.assertRaisesRegex(release.BuildError, "GitHub's release tag"):
                release.draft_release(directory, self.root)
        github.assert_not_called()

    def test_cleanup_preserves_releases_and_latest_successful_test(self):
        latest = self.root / "dist/test-builds/0.0.1/old-success"
        failed = self.root / "dist/test-builds/0.0.1/new-failure"
        released = self.root / "dist/releases/0.0.1/released"
        for index, path in enumerate((latest, failed, released)):
            path.mkdir(parents=True)
            release.write_json(path / "manifest.json", {"createdAt": str(index)})
        release.write_json(latest.parents[1] / "latest.json", {"path": str(latest.relative_to(self.root))})
        (self.root / ".build/app/release").mkdir(parents=True)
        (self.root / ".build/cache").mkdir()
        release.cleanup(1, True, self.root)
        self.assertTrue(latest.exists())
        self.assertTrue(released.exists())
        self.assertTrue((self.root / ".build/app/release").exists())
        self.assertFalse((self.root / ".build/cache").exists())

    def test_source_fingerprint_detects_same_commit_local_edits(self):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / ".gitignore").write_text("dist/\n")
        source = self.root / "source.swift"
        source.write_text("let gain = 1\n")
        before = release.source_state(self.root)
        (self.root / "dist").mkdir()
        (self.root / "dist/report.json").write_text("generated")
        self.assertEqual(release.source_state(self.root), before)
        source.write_text("let gain = 2\n")
        after = release.source_state(self.root)
        self.assertEqual(after["commit"], before["commit"])
        self.assertNotEqual(after["fingerprint"], before["fingerprint"])

    def test_version_updates_preserve_comments_and_require_build_increment(self):
        (self.root / "Resources").mkdir()
        text = (release.ROOT / "Resources/Info.plist").read_text()
        path = self.root / "Resources/Info.plist"
        path.write_text(text)
        current = release.bundle_version(self.root)
        next_version = f"{int(current['version'].split('.')[0]) + 1}.0.0"
        with self.assertRaises(release.BuildError):
            release.set_version(current["version"], int(current["build"]), self.root)
        release.set_version(next_version, int(current["build"]) + 1, self.root)
        self.assertIn("<!--", path.read_text())
        self.assertEqual(release.bundle_version(self.root)["version"], next_version)


if __name__ == "__main__":
    unittest.main()
