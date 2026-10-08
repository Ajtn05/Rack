#!/usr/bin/env python3
"""Rack's dependency-free build, verification, and release entry point."""
import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
VERSION_PATTERN = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+\Z")
REQUIRED_STEPS = {"boundaries", "registration", "release-tools", "debug-tests", "optimized-tests"}
SMOKE_CHECKS = {
    "install_and_launch", "system_audio_permission", "listening_and_bypass",
    "app_volume_and_mute", "output_device_switch", "presets_and_restore",
    "menu_bar_and_quit", "microphone_monitoring",
}


class BuildError(Exception):
    pass


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, data):
    path = Path(path)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git(*args, root=ROOT, optional=False):
    result = subprocess.run(["git", "-c", "core.fsmonitor=false", *args], cwd=root,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode and not optional:
        raise BuildError(result.stderr.decode(errors="replace").strip())
    return result.stdout if result.returncode == 0 else b""


def source_state(root=ROOT):
    digest = hashlib.sha256()
    paths = git("ls-files", "-z", "--cached", "--others", "--exclude-standard", root=root)
    for raw in sorted(set(paths.split(b"\0")) - {b""}):
        path = root / os.fsdecode(raw)
        digest.update(raw + b"\0")
        if path.is_symlink():
            digest.update(b"link\0" + os.fsencode(os.readlink(path)))
        elif path.is_file():
            digest.update(bytes.fromhex(sha256(path)))
        else:
            digest.update(b"missing\0")
    return {
        "commit": git("rev-parse", "--verify", "HEAD", root=root, optional=True).decode().strip() or None,
        "hasChanges": bool(git("status", "--porcelain", "--untracked-files=all", root=root)),
        "fingerprint": digest.hexdigest(),
    }


def bundle_version(root=ROOT):
    with (root / "Resources/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    if not VERSION_PATTERN.fullmatch(version) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise BuildError("Use a three-part app version and a positive integer build number.")
    return {"version": version, "build": build, "minimumMacOS": info["LSMinimumSystemVersion"]}


def build_id(source):
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    revision = (source["commit"] or "working")[:12]
    return f"{stamp}-{revision}-{uuid.uuid4().hex[:6]}"


def new_directory(path):
    path = Path(path).resolve()
    if path.exists():
        raise BuildError(f"Output already exists; builds are immutable: {path}")
    path.mkdir(parents=True)
    return path


def child_path(directory, relative):
    path = (directory / relative).resolve()
    if not path.is_relative_to(directory.resolve()) or path == directory.resolve():
        raise BuildError(f"Invalid artifact path: {relative}")
    return path


@contextlib.contextmanager
def build_lock(root=ROOT):
    (root / ".build").mkdir(exist_ok=True)
    with (root / ".build/release-system.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise BuildError("Another organized build is running. Wait for it to finish.") from error
        yield


def command_step(name, command, directory, env=None, root=ROOT):
    log = directory / f"{name}.log"
    print(f"→ {name} (log: {log})", flush=True)
    started = time.monotonic()
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=root, env=env, stdout=stream, stderr=subprocess.STDOUT)
    step = {"name": name, "command": command, "log": log.name,
            "exitCode": result.returncode, "durationSeconds": round(time.monotonic() - started, 2),
            "status": "passed" if result.returncode == 0 else "failed"}
    if name in {"debug-tests", "optimized-tests"}:
        tally = re.search(r"✓ ([0-9]+) checks passed", log.read_text(errors="replace"))
        if tally:
            step["checks"] = int(tally.group(1))
        if not tally or step.get("checks", 0) == 0:
            step["status"] = "failed"
    if step["status"] == "failed":
        print(f"→ {name} failed (exit code {result.returncode}); last 120 log lines:", flush=True)
        print("\n".join(log.read_text(errors="replace").splitlines()[-120:]), flush=True)
    return step


def verification(directory, source, root=ROOT, *, skip_theme_screenshots=False):
    directory = new_directory(directory)
    report = {"schemaVersion": 1, "kind": "verification", "status": "running",
              "startedAt": utc_now(), "source": source, "steps": [],
              "themeScreenshots": not skip_theme_screenshots,
              "platform": {"architecture": platform.machine(), "macOS": platform.mac_ver()[0]}}
    try:
        report["platform"]["swift"] = subprocess.check_output(
            ["swift", "--version"], cwd=root, text=True, stderr=subprocess.STDOUT).strip()
        env = os.environ.copy()
        env["RACK_THEME_SCREENSHOT_DIR"] = str(directory / "theme-screenshots")
        debug_command = ["swift", "run", "RackTests"]
        if skip_theme_screenshots:
            debug_command.append("--skip-theme-screenshots")
        commands = [
            ("boundaries", ["sh", "Scripts/check-boundaries.sh"]),
            ("registration", ["sh", "Scripts/check-test-registration.sh"]),
            ("release-tools", [sys.executable, "-m", "unittest", "discover", "-s", "Tests/ReleaseTools", "-v"]),
            ("debug-tests", debug_command),
            ("optimized-tests", ["swift", "run", "-c", "release", "-Xswiftc", "-enable-testing", "RackTests", "--headless"]),
        ]
        for name, command in commands:
            step = command_step(name, command, directory, env=env, root=root)
            report["steps"].append(step)
            write_json(directory / "report.json", report)
            if step["status"] != "passed":
                raise BuildError(f"{name} failed. Inspect {directory / step['log']}.")
        if source_state(root) != source:
            raise BuildError("Source changed during verification. Run verification again.")
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        raise
    finally:
        report["finishedAt"] = utc_now()
        report["evidence"] = {
            str(path.relative_to(directory)): sha256(path)
            for path in sorted(directory.rglob("*"))
            if path.is_file() and path.name not in {"report.json", "summary.md"}
        }
        write_json(directory / "report.json", report)
        lines = ["# Automated verification", "", f"Result: **{report['status']}**", "",
                 f"Source: `{source['commit'] or 'uncommitted working tree'}`", "",
                 f"Theme screenshots: {'skipped' if skip_theme_screenshots else 'enabled'}", "",
                 "| Check | Result | Checks |", "| --- | --- | --- |"]
        for step in report["steps"]:
            lines.append(f"| {step['name']} | {step['status']} | {step.get('checks', '—')} |")
        if "error" in report:
            lines += ["", report["error"]]
        (directory / "summary.md").write_text("\n".join(lines) + "\n")
    return directory / "report.json"


def validate_verification(path, source):
    report = read_json(path)
    steps = {step["name"]: step for step in report.get("steps", [])}
    if report.get("schemaVersion") != 1 or report.get("kind") != "verification" or report.get("status") != "passed":
        raise BuildError(f"Verification has not passed: {path}")
    if report.get("source") != source:
        raise BuildError(f"Verification belongs to different source: {path}")
    if not REQUIRED_STEPS.issubset(steps) or any(step.get("status") != "passed" for step in steps.values()):
        raise BuildError(f"Verification is incomplete: {path}")
    if any(steps[name].get("checks", 0) <= 0 for name in ("debug-tests", "optimized-tests")):
        raise BuildError(f"Verification has no successful test tally: {path}")
    evidence = report.get("evidence", {})
    if not evidence or any(step.get("log") not in evidence for step in steps.values()):
        raise BuildError(f"Verification logs are missing: {path}")
    for relative, expected in evidence.items():
        file = child_path(Path(path).parent, relative)
        if not file.is_file() or sha256(file) != expected:
            raise BuildError(f"Verification evidence changed: {file}")
    return report


def collect_verification(destination, source, supplied, root=ROOT):
    if not supplied:
        return [verification(destination / "validation", source, root)]
    paths = sorted(Path(supplied).resolve().rglob("report.json"))
    if not paths:
        raise BuildError(f"No verification reports found in {supplied}.")
    retained = []
    seen = set()
    for path in paths:
        report = validate_verification(path, source)
        architecture = report["platform"]["architecture"]
        if architecture not in {"arm64", "x86_64"} or architecture in seen:
            raise BuildError("Supply one verification report for each tested architecture.")
        seen.add(architecture)
        target = destination / "validation" / architecture
        shutil.copytree(path.parent, target)
        retained.append(target / "report.json")
    return retained


def prepare_build(args, root=ROOT):
    source = source_state(root)
    info = bundle_version(root)
    is_candidate = args.command == "candidate"
    if is_candidate and (not source["commit"] or source["hasChanges"]):
        raise BuildError("Release candidates require a committed, clean source tree. Use test-build for work in progress.")
    if is_candidate and args.tag:
        expected = f"v{info['version']}"
        if args.tag != expected or git("rev-parse", "--verify", f"{expected}^{{commit}}", root=root).decode().strip() != source["commit"]:
            raise BuildError("Candidate tag must match the bundle version and current source commit.")
    preview = not is_candidate or args.preview
    if not preview:
        if not os.environ.get("RACK_SIGN_IDENTITY", "").startswith("Developer ID Application:") or not os.environ.get("RACK_NOTARY_PROFILE"):
            raise BuildError("Stable candidates require RACK_SIGN_IDENTITY and RACK_NOTARY_PROFILE for notarization.")
    identity = build_id(source)
    channel = "test" if not is_candidate else "preview" if preview else "stable"
    lane = "test-builds" if not is_candidate else "releases"
    directory = new_directory(root / "dist" / lane / info["version"] / identity)
    manifest = {"schemaVersion": 1, "id": identity, "kind": "release-candidate" if is_candidate else "test-build",
                "channel": channel, "status": "preparing", "createdAt": utc_now(), "source": source, **info}
    write_json(directory / "manifest.json", manifest)
    try:
        reports = collect_verification(directory, source, args.verification, root)
        for path in reports:
            validate_verification(path, source)
        if not preview and {read_json(path)["platform"]["architecture"] for path in reports} != {"arm64", "x86_64"}:
            raise BuildError("Stable candidates require verification reports from both Apple silicon and Intel.")
        env = os.environ.copy()
        env["RACK_PACKAGE_OUTPUT"] = str(directory / "package")
        if not is_candidate:
            env["RACK_PACKAGE_LABEL"] = f"test-{identity}"
        if preview:
            env.pop("RACK_SIGN_IDENTITY", None)
            env.pop("RACK_NOTARY_PROFILE", None)
        command = ["sh", "Scripts/package-release.sh"] + ([] if preview else ["--notarize"])
        step = command_step("package", command, directory, env=env, root=root)
        if step["status"] != "passed":
            raise BuildError(f"Packaging failed. Inspect {directory / 'package.log'}.")
        if source_state(root) != source:
            raise BuildError("Source changed during packaging. This build cannot be distributed.")
        package = read_json(directory / "package/release-info.json")
        archive = child_path(directory / "package", package["archive"])
        if sha256(archive) != package["sha256"] or package["notarized"] != (not preview):
            raise BuildError("Package checksum or notarization status does not match the build.")
        manifest["verification"] = [{"path": str(path.relative_to(directory)), "sha256": sha256(path)} for path in reports]
        manifest["package"] = {"path": str(archive.relative_to(directory)), "sha256": package["sha256"],
                               "notarized": package["notarized"], "signing": package["signing"]}
        manifest["packageFiles"] = {
            str(path.relative_to(directory)): sha256(path)
            for path in sorted((directory / "package").iterdir()) if path.is_file()
        }
        template = read_json(root / "docs/testing/manual-smoke-template.json")
        template["archiveSha256"] = package["sha256"]
        (directory / "manual-smoke-template.json").write_text(json.dumps(template, indent=2) + "\n")
        manifest["status"] = "passed"
    except Exception as error:
        manifest["status"] = "failed"
        manifest["error"] = str(error)
        raise
    finally:
        manifest["finishedAt"] = utc_now()
        write_json(directory / "manifest.json", manifest)
    (directory / "summary.md").write_text(
        f"# Rack {info['version']} — {channel}\n\nBuild: `{identity}`\n\n"
        f"Source: `{source['commit'] or 'uncommitted working tree'}`\n\n"
        f"Archive: [{archive.name}]({manifest['package']['path']})\n\n"
        f"SHA-256: `{package['sha256']}`\n\n"
        "Automated verification passed. Manual listening and device checks remain pending.\n"
    )
    write_json(root / "dist" / lane / "latest.json", {"id": identity, "path": str(directory.relative_to(root))})
    print(f"Prepared {channel} build: {directory}", flush=True)
    return directory


def validate_smoke(data, archive_sha):
    if data.get("archiveSha256") != archive_sha:
        raise BuildError("The manual check must identify the exact archive checksum.")
    for field in ("tester", "testedAt", "macOS"):
        if not isinstance(data.get(field), str) or not data[field].strip():
            raise BuildError(f"Manual check is missing {field}.")
    try:
        tested_at = dt.datetime.fromisoformat(data["testedAt"].replace("Z", "+00:00"))
    except ValueError as error:
        raise BuildError("Use an ISO 8601 date and time with a timezone for testedAt.") from error
    if tested_at.tzinfo is None or tested_at > dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=5):
        raise BuildError("Manual check time must include a timezone and cannot be in the future.")
    if data.get("architecture") not in {"arm64", "x86_64"}:
        raise BuildError("Manual check architecture must be arm64 or x86_64.")
    checks = data.get("checks", {})
    if set(checks) != SMOKE_CHECKS:
        raise BuildError("Complete every check from manual-smoke-template.json.")
    for name, result in checks.items():
        passed = result.get("result") == "passed"
        skipped = name == "microphone_monitoring" and result.get("result") == "skipped" and bool(result.get("notes", "").strip())
        if not (passed or skipped):
            raise BuildError(f"Manual check has not passed: {name}.")


def validate_candidate(directory, *, skip_smoke=False):
    directory = Path(directory).resolve()
    manifest = read_json(directory / "manifest.json")
    if manifest.get("schemaVersion") != 1 or manifest.get("kind") != "release-candidate" or manifest.get("status") != "passed":
        raise BuildError("Only a successfully verified release candidate can become a GitHub release.")
    if skip_smoke and manifest.get("channel") != "preview":
        raise BuildError("Manual smoke testing can only be skipped for a preview release.")
    source = manifest["source"]
    if not source.get("commit") or source.get("hasChanges"):
        raise BuildError("Release source must be committed and clean.")
    archive = child_path(directory, manifest["package"]["path"])
    if sha256(archive) != manifest["package"]["sha256"]:
        raise BuildError("Candidate archive changed after testing.")
    files = manifest.get("packageFiles", {})
    required = {str(archive.relative_to(directory)), "package/SHA256SUMS",
                "package/release-info.json", "package/release-notes.md"}
    if not required.issubset(files):
        raise BuildError("Candidate package evidence is incomplete.")
    for relative, expected in files.items():
        file = child_path(directory, relative)
        if not file.is_file() or sha256(file) != expected:
            raise BuildError(f"Candidate package file changed: {file}.")
    package = read_json(directory / "package/release-info.json")
    if (package.get("sha256") != manifest["package"]["sha256"]
            or package.get("archive") != archive.name
            or package.get("version") != manifest["version"]
            or package.get("build") != manifest["build"]
            or package.get("sourceCommit") != source["commit"]
            or package.get("sourceHasChanges") is not False
            or package.get("notarized") != manifest["package"]["notarized"]):
        raise BuildError("Package metadata does not match the tested candidate.")
    if (directory / "package/SHA256SUMS").read_text().strip() != f"{package['sha256']}  {archive.name}":
        raise BuildError("Candidate checksum file changed.")
    reports = []
    for item in manifest.get("verification", []):
        path = child_path(directory, item["path"])
        if sha256(path) != item["sha256"]:
            raise BuildError("Candidate verification report changed.")
        reports.append(validate_verification(path, source))
    if not reports:
        raise BuildError("Candidate has no automated verification.")
    if manifest["channel"] == "stable":
        if not manifest["package"].get("notarized"):
            raise BuildError("Stable releases must be notarized.")
        if {report["platform"]["architecture"] for report in reports} != {"arm64", "x86_64"}:
            raise BuildError("Stable releases require automated verification on both Apple silicon and Intel.")
    elif manifest["channel"] != "preview":
        raise BuildError("Unsupported release channel.")
    if not skip_smoke:
        validate_smoke(read_json(directory / "manual-smoke.json"), manifest["package"]["sha256"])
    return manifest, archive


def draft_release(directory, root=ROOT, *, skip_smoke=False):
    manifest, archive = validate_candidate(directory, skip_smoke=skip_smoke)
    tag = f"v{manifest['version']}"
    tagged_commit = git("rev-parse", "--verify", f"{tag}^{{commit}}", root=root).decode().strip()
    if tagged_commit != manifest["source"]["commit"]:
        raise BuildError("Release tag points to a different commit than the tested candidate.")
    if remote_tag_commit(tag, root) != manifest["source"]["commit"]:
        raise BuildError("GitHub's release tag points to a different commit than the tested candidate.")
    directory = Path(directory).resolve()
    manual_record = directory / "manual-smoke.json"
    if skip_smoke:
        manual_record = directory / "manual-smoke-skipped.json"
        if manual_record.exists():
            record = read_json(manual_record)
            if record.get("archiveSha256") != manifest["package"]["sha256"] or record.get("status") != "skipped":
                raise BuildError("Existing manual smoke skip record does not match this candidate.")
        else:
            write_json(manual_record, {
                "schemaVersion": 1, "archiveSha256": manifest["package"]["sha256"],
                "sourceCommit": manifest["source"]["commit"], "recordedAt": utc_now(),
                "status": "skipped", "checksRemainPending": True,
                "reason": "Manual smoke testing omitted at the user's explicit request.",
            })
        print("Manual smoke testing skipped by request; manual checks remain pending.", flush=True)
    command = ["gh", "release", "create", tag, str(archive),
               str(directory / "package/SHA256SUMS"), str(directory / "package/release-info.json"),
               str(directory / "manifest.json"), str(manual_record),
               "--verify-tag", "--draft", "--title", f"Rack {manifest['version']}",
               "--notes-file", str(directory / "package/release-notes.md")]
    if manifest["channel"] == "preview":
        command.append("--prerelease")
    # Export the full evidence as one companion archive while retaining the
    # candidate's original application ZIP unchanged.
    with tempfile.TemporaryDirectory(prefix="rack-release-") as temporary:
        evidence = Path(shutil.make_archive(str(Path(temporary) / "Rack-build-evidence"), "zip", directory))
        command.insert(4, str(evidence))
        subprocess.run(command, cwd=root, check=True)


def remote_tag_commit(tag, root=ROOT):
    repository = subprocess.check_output(
        ["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
        cwd=root, text=True).strip()
    return subprocess.check_output(
        ["gh", "api", f"repos/{repository}/commits/{tag}", "--jq", ".sha"],
        cwd=root, text=True).strip()


def set_version(version, number, root=ROOT):
    current = bundle_version(root)
    if not VERSION_PATTERN.fullmatch(version) or number <= int(current["build"]):
        raise BuildError("Use a three-part version and a build number higher than the current one.")
    if tuple(map(int, version.split("."))) < tuple(map(int, current["version"].split("."))):
        raise BuildError("The app version cannot go backwards.")
    path = root / "Resources/Info.plist"
    text = path.read_text()
    for key, value in (("CFBundleShortVersionString", version), ("CFBundleVersion", str(number))):
        pattern = rf"(<key>{key}</key>\s*<string>)[^<]*(</string>)"
        text, count = re.subn(pattern, lambda match: match[1] + value + match[2], text)
        if count != 1:
            raise BuildError(f"Expected one {key} in Info.plist.")
    temporary = path.with_suffix(".plist.tmp")
    temporary.write_text(text)
    temporary.chmod(path.stat().st_mode & 0o777)
    temporary.replace(path)
    print(f"Set version {version}, build {number}. Update changelog/release notes and commit before creating a candidate.")


def cleanup(keep, apply, root=ROOT):
    candidates = []
    for path in (root / "dist/test-builds").glob("*/*/manifest.json"):
        manifest = read_json(path)
        candidates.append((manifest["createdAt"], path.parent))
    candidates.sort(reverse=True)
    latest = root / "dist/test-builds/latest.json"
    protected = (root / read_json(latest)["path"]).resolve() if latest.exists() else None
    for _, path in candidates[keep:]:
        if path.resolve() == protected:
            continue
        print(f"{'Removing' if apply else 'Would remove'} test build: {path}")
        if apply:
            shutil.rmtree(path)
    for path in (root / ".build").iterdir():
        if path.name in {"app", "release-system.lock"}:
            continue
        print(f"{'Removing' if apply else 'Would remove'} compiler output: {path}")
        if apply:
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()
    print("Release candidates and legacy release packages are retained.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    verify = commands.add_parser("verify", help="Run every automated gate and retain its evidence")
    verify.add_argument("--output", type=Path)
    verify.add_argument("--skip-theme-screenshots", action="store_true",
                        help="Keep contrast and texture checks, but omit SwiftUI rendering on hosts without usable Metal")
    for name in ("test-build", "candidate"):
        command = commands.add_parser(name, help="Prepare an immutable universal build")
        command.add_argument("--verification", type=Path, help="Reuse retained verification for the exact same source")
        if name == "candidate":
            command.add_argument("--preview", action="store_true", help="Prepare an ad-hoc signed prerelease candidate")
            command.add_argument("--tag", help="Require an existing version tag to identify this candidate's source")
    record = commands.add_parser("record-smoke", help="Record completed manual checks for an exact candidate")
    record.add_argument("directory", type=Path)
    record.add_argument("--file", type=Path, required=True)
    draft = commands.add_parser("draft-release", help="Upload a tested candidate as a draft GitHub release")
    draft.add_argument("directory", type=Path)
    draft.add_argument("--skip-smoke", action="store_true",
                       help="Publish a preview without manual smoke testing when explicitly requested; keep checks pending")
    version = commands.add_parser("version", help="Update the app version and increment its build number")
    version.add_argument("version")
    version.add_argument("--build", type=int, required=True)
    commands.add_parser("list", help="List retained builds and their results")
    clean = commands.add_parser("clean", help="Preview or apply test-build/cache retention; preserve releases")
    clean.add_argument("--keep", type=int, default=10)
    clean.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "list":
            for path in sorted((ROOT / "dist").glob("*/*/*/manifest.json")):
                item = read_json(path)
                print(f"{item['status']:8} {item['channel']:7} {item['version']:8} {item['id']}  {path.parent}")
            return 0
        if args.command == "draft-release":
            draft_release(args.directory, skip_smoke=args.skip_smoke)
            return 0
        with build_lock():
            if args.command == "verify":
                source = source_state()
                output = args.output or ROOT / "dist/verification" / build_id(source)
                print(f"Verification report: {verification(output, source, skip_theme_screenshots=args.skip_theme_screenshots)}")
            elif args.command in {"test-build", "candidate"}:
                prepare_build(args)
            elif args.command == "record-smoke":
                directory = args.directory.resolve()
                manifest = read_json(directory / "manifest.json")
                if manifest.get("kind") != "release-candidate" or manifest.get("status") != "passed":
                    raise BuildError("Record smoke checks against a successful release candidate.")
                data = read_json(args.file)
                validate_smoke(data, manifest["package"]["sha256"])
                destination = directory / "manual-smoke.json"
                if destination.exists():
                    raise BuildError("Smoke checks have already been recorded for this candidate.")
                write_json(destination, data)
                print(f"Recorded manual checks: {destination}")
            elif args.command == "version":
                set_version(args.version, args.build)
            elif args.command == "clean":
                if args.keep < 1:
                    raise BuildError("Keep at least one test build.")
                cleanup(args.keep, args.apply)
        return 0
    except (BuildError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"Build system: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
