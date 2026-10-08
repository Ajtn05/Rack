# Rack project workflow

Use the build and distribution system in [docs/BUILD_SYSTEM.md](docs/BUILD_SYSTEM.md)
for future testing and release work.

- For automated validation, run `python3 Scripts/release.py verify`.
- For an installable testing build, run `python3 Scripts/release.py test-build`.
- For a release candidate, use `candidate --preview` or the notarized `candidate`
  path. Candidates require a committed, clean source tree.
- Keep generated archives, logs, reports, and build-specific screenshots in
  `dist/`. Do not overwrite an existing build directory or release artifact.
- Development-only builds may use `Scripts/build-app.sh --run`.
- Record manual listening/device checks only when they were actually performed.
  Keep untested checks pending. Do not infer a manual pass from unit tests.
- Distribute the exact candidate that was tested. `draft-release` verifies its
  archive, source tag, automated evidence, and manual check record; it never
  rebuilds the candidate. Honor the user's publishing instructions.
- Use `release.py clean` to preview retention and `clean --apply` to remove old
  test builds and compiler caches. Keep release candidates and the last good
  test build. Do not manually remove release history during routine cleanup.
- Update `Resources/Info.plist`, the changelog, and the matching release notes
  for a new version. `release.py version VERSION --build NUMBER` validates
  increasing version/build numbers and preserves plist comments.

Read the architecture and audio guides before changing the audio render path.
Run targeted tests as needed while developing; use the organized verification
command when declaring a build verified or preparing distribution.
