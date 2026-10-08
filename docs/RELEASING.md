# Releasing Rack

The repeatable process is in [BUILD_SYSTEM.md](BUILD_SYSTEM.md). Use
`Scripts/release.py` for verification, candidate preparation, and distribution.
The original package in `dist/0.0.1/` is retained as a legacy preview; new
builds use separate directories and never overwrite it.

## Prepare a version

`Resources/Info.plist` owns the app version and numeric build number. Increment
the build number for each versioned release; test runs also receive a separate
unique build ID. For example, when moving from 0.0.1/build 1:

```sh
python3 Scripts/release.py version 0.0.2 --build 2
```

Add `docs/releases/0.0.2.md` and update `CHANGELOG.md` and `README.md` for
the actual version. Commit the source and release notes so a fresh checkout and
CI can package the same notes. A candidate requires a clean, committed tree;
work in progress belongs in `test-build`.

## Prepare a preview candidate

```sh
python3 Scripts/release.py candidate --preview
```

The command runs automated verification, builds a universal optimized app,
and writes a new `dist/releases/VERSION/BUILD-ID/` directory. It contains the
app ZIP, checksum, source/build metadata, manifest, test reports, command logs,
theme previews, and a manual-check template.

Preview candidates are ad-hoc signed, not notarized, and distributed as
GitHub prereleases. Keep that limitation in the product page and release notes.
The command refuses to reuse an existing output directory. Failed builds stay
available for diagnosis and do not replace the last successful build pointer.

## Prepare a stable candidate

Download verification reports for both architectures from the same GitHub
run, or combine reports produced by `release.py verify` on Apple silicon and
Intel from the exact same clean source. Put each complete report directory
under a common parent, then run on a signing-equipped Mac:

```sh
export RACK_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAM ID)'
export RACK_NOTARY_PROFILE='YOUR KEYCHAIN PROFILE'
python3 Scripts/release.py candidate --verification dist/verification-input
```

The command verifies both reports against the source and their retained
files. It builds, signs with a timestamp, waits for notarization acceptance,
staples and validates the ticket, and runs Gatekeeper assessment. Stable
candidates and releases require notarization and both architecture reports.
Credentials stay in the machine's keychain. Ordinary CI uses no signing secrets.

Adjust the README and release notes for stable distribution before committing
and preparing this candidate; the archive's notes are part of its checked evidence.

## Test the candidate and record results

Install from the candidate's ZIP and follow
[MANUAL_SMOKE.md](testing/MANUAL_SMOKE.md). Copy its generated template,
fill in real observations, then import the record:

```sh
python3 Scripts/release.py record-smoke CANDIDATE-DIRECTORY --file completed-smoke.json
```

Do not mark untested checks as passed. Required checks must pass. A missing
microphone can be documented as an optional skipped check with a reason.
The record is bound to the archive checksum and cannot be reused for a rebuilt ZIP.
If a problem requires a fix, commit the fix and prepare a new candidate.

## Publish the tested artifact

Configure the repository's actual URL as `origin` once. Choose its license,
push the source and workflow files, and let GitHub CI run.

Read the candidate's source commit in `manifest.json`, then tag that exact
commit and push the tag. For example:

```sh
git tag -a v0.0.1 ACTUAL_CANDIDATE_COMMIT -m 'Rack 0.0.1 preview'
git push origin main
git push origin v0.0.1
python3 Scripts/release.py draft-release CANDIDATE-DIRECTORY
```

Use the actual version and commit; do not run the placeholder literally.
`draft-release` verifies the candidate files, automated evidence, manual
record, and local tag, then requires the remote tag to exist. It uploads
that candidate's exact ZIP, checksums, metadata, manifest, manual record,
and a companion archive containing all retained evidence. It never rebuilds
or replaces the app. Preview releases are explicitly marked as prereleases.

Review the GitHub draft, then publish it. Add the actual release/download
link to the product README. Keep the candidate directory as the local record.

## Prepare candidates through GitHub

Use **Actions → Prepare preview release candidate → Run workflow** and enter
an existing `vVERSION` tag. The workflow verifies that source on Apple silicon
and Intel, then uploads an immutable candidate folder. Download it, extract
it with its directory structure intact, perform the manual checks, record
them using the local command, and create the draft release from that folder.

The release workflow uses read-only repository access and prepares artifacts;
it does not publish automatically. Main pushes produce testing artifacts
through **Tests and test builds**; pull requests run the same automated gates.
Candidate artifacts expire after 90 days, so retain a local copy before expiry.

## Verify and retain files

The checksum file is inside a candidate's `package/` directory:

```sh
cd CANDIDATE-DIRECTORY/package
shasum -a 256 -c SHA256SUMS
```

Use `python3 Scripts/release.py list` to inspect local history and
`python3 Scripts/release.py clean --apply` for routine cleanup. Cleanup keeps
release candidates, the latest successful test build, and fresh app bundles.
Do not delete `dist/` wholesale or upload an unverified low-level package as a release.
