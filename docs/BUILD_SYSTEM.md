# Rack build and distribution system

Use `python3 Scripts/release.py` from the source directory. The tool uses the
Python standard library and the existing Swift build scripts. It gives every
run a unique UTC timestamp, source revision, and suffix. Previous builds stay intact.

## Build stages

| Stage | Command | Use and location |
| --- | --- | --- |
| Development | `sh Scripts/build-app.sh --run` | Fast local iteration; `.build/app/debug/Rack.app` |
| Verification | `python3 Scripts/release.py verify` | Retained automated results in `dist/verification/BUILD-ID/` |
| Test build | `python3 Scripts/release.py test-build` | Verified universal preview in `dist/test-builds/VERSION/BUILD-ID/` |
| Preview candidate | `python3 Scripts/release.py candidate --preview` | Verified prerelease candidate in `dist/releases/VERSION/BUILD-ID/` |
| Stable candidate | `python3 Scripts/release.py candidate` | Developer ID signed, notarized candidate in the same release lane |
| Distribution | `python3 Scripts/release.py draft-release CANDIDATE-DIRECTORY` | Upload the tested candidate as a draft GitHub release |

Test builds may come from a work in progress. Release candidates require a
committed source tree with no local changes. Preview candidates use ad-hoc
signing and become GitHub prereleases. Stable candidates require Developer ID
signing and notarization, plus automated results from both Apple silicon and
Intel before packaging and distribution.

`test-build` and `candidate` run verification automatically. They stop before
packaging if a check fails. `--verification DIRECTORY` can reuse retained
reports from the exact same source; the tool checks the source fingerprint,
commit, completed suites, report hashes, and every retained evidence file.

## Automated verification

Every verification run checks:

1. Module boundaries and test registration.
2. The build/distribution tool's own regression suite.
3. Full debug audio/model tests, theme contrast, and theme rendering.
4. Optimized headless audio/model tests.

`verify --skip-theme-screenshots` omits only SwiftUI screenshot rendering;
theme contrast and texture cache checks still run. The report records this
choice. CI uses this option on the Intel runner, where Metal initialization
aborts rendering. Apple silicon CI renders all normal and reduced-transparency
theme screenshots. Local verification renders screenshots by default.

Packaging then checks the universal executable, code signature, audio
entitlement, absence of the debugger entitlement, ZIP integrity, and checksum.
Stable packaging also waits for notarization, staples the ticket, and runs
Gatekeeper assessment.

Each verification run stores `report.json`, `summary.md`, command logs, and
theme previews. The report records test counts, timing, host architecture,
macOS/toolchain version, source commit, and a fingerprint of the source files.
Failed runs retain their report and available evidence. Source edits during
verification or packaging invalidate the run.

Organized runs put theme screenshots in their report directory using
`RACK_THEME_SCREENSHOT_DIR`, so testing does not change committed screenshots.
Use a normal `swift run RackTests` only when deliberately refreshing the
repository's visual review assets.

## What a retained build contains

```text
dist/test-builds/0.0.1/BUILD-ID/    # or dist/releases/0.0.1/BUILD-ID/
  manifest.json                  # identity, source, stage, result, archive hash
  summary.md
  package.log
  manual-smoke-template.json      # initially pending, bound to the archive
  package/
    Rack-...zip
    SHA256SUMS
    release-info.json
    release-notes.md
  validation/
    report.json                  # local verification
    summary.md
    *.log
    theme-screenshots/*.png
```

When reusing results from GitHub, `validation/arm64/` and
`validation/x86_64/` contain the reports for each machine.

Test ZIP names include the build ID so downloaded builds remain distinguishable.
`manifest.json` is the identity to include in bug reports. The app's version
and numeric build number come from `Resources/Info.plist`; increment them
when preparing a new release. A failed attempt cannot update `latest.json`.

```sh
python3 Scripts/release.py list
```

The list shows retained build IDs and whether each run passed or failed.
`dist/test-builds/latest.json` and `dist/releases/latest.json` locate the last
successfully prepared build in their lane; these pointers do not replace history.

## Manual checks and promotion

Install the candidate from its ZIP and perform the checks in
[MANUAL_SMOKE.md](testing/MANUAL_SMOKE.md). Copy its generated
`manual-smoke-template.json`, record actual observations, then import it:

```sh
python3 Scripts/release.py record-smoke CANDIDATE-DIRECTORY --file completed-smoke.json
```

The record identifies the exact archive checksum, tester, date/time with
timezone, macOS version, and architecture. Required checks must pass.
Microphone monitoring may be skipped with a reason when no suitable input is
available. Keep failures and untested checks pending and fix them in a new build.

Create and push the version tag at the candidate's recorded source commit.
`draft-release` rejects a tag pointing elsewhere, a changed archive or report,
incomplete manual checks, or an unnotarized stable build. It uploads the existing
ZIP, checksum, metadata, build manifest, and manual record without rebuilding.
Review the GitHub draft and publish when ready. See [RELEASING.md](RELEASING.md).

## GitHub distribution

Once the repository is created and pushed:

- **Tests and test builds** runs on pull requests and pushes to `main`.
  It verifies on `macos-15` (Apple silicon) and `macos-15-intel`. Both must
  pass; theme screenshots are rendered on Apple silicon. Main pushes and
  manual runs also produce a universal testing ZIP
  and complete evidence as a GitHub Actions artifact.
- **Prepare preview release candidate** runs manually for an existing
  `vVERSION` tag. It verifies that tagged source on both architectures,
  packages a candidate, and uploads its complete folder for download and
  manual checks. It does not publish a release automatically.
- Stable candidates are prepared on a signing-equipped Mac using the same
  command and both retained verification reports. Credentials stay in the
  machine's keychain; ordinary CI and pull requests use no signing secrets.

Verification/test artifacts are retained for 14 days; candidate artifacts for
90 days. Download candidates you intend to keep, since Actions artifacts
expire. Published GitHub releases hold the distributed files. Local release
candidate history is retained until deliberately archived outside routine cleanup.

Runner labels follow the [GitHub runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
The hosted workflows take effect when these files are committed and pushed
to the connected repository. Local validation does not confirm a hosted run.

## Cleanup

```sh
python3 Scripts/release.py clean             # show proposed removals
python3 Scripts/release.py clean --apply     # apply; keep 10 newest test runs
python3 Scripts/release.py clean --keep 20 --apply
```

Cleanup removes old test runs and compiler caches while preserving the last
successful test build, fresh app bundles, and all release candidates. It also
preserves the legacy `dist/0.0.1/` package from initial preparation. Standalone
verification folders can be archived or deleted after their reports have been
retained in a test build or candidate.

All `dist/` and `.build/` output is ignored by Git. Avoid deleting `dist/`
wholesale: it is now the local build and release history.
