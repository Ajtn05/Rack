# Releasing Rack

The current version is **0.0.1**, build **1**, in `Resources/Info.plist`.
The prepared release is a preview. No GitHub repository or release has been
created by this preparation work.

## Prepare the files

Run the verification commands in [DEVELOPMENT.md](DEVELOPMENT.md), then:

```sh
sh Scripts/package-release.sh
```

The script builds an optimized universal app, applies an ad-hoc signature,
verifies the signature and architectures, checks that the debugger entitlement
is absent, tests the ZIP, and writes:

```text
dist/0.0.1/
  Rack-0.0.1-macOS-universal-preview.zip
  SHA256SUMS
  release-info.json
  release-notes.md
```

`release-info.json` records the version, architectures, signing status,
notarization status, source commit, uncommitted-change flag, build time, and
archive checksum. Check the archive with:

```sh
cd dist/0.0.1
shasum -a 256 -c SHA256SUMS
```

Ad-hoc signed previews are not notarized. Keep that fact in the release notes
and publish them as prereleases. The local development signing certificate
is never selected automatically by the package script.

## Developer ID signing and notarization

For a notarized build, install your **Developer ID Application** certificate
and configure a `notarytool` keychain profile. Supply both explicitly:

```sh
export RACK_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAM ID)'
export RACK_NOTARY_PROFILE='YOUR KEYCHAIN PROFILE'
sh Scripts/package-release.sh --notarize
```

The script waits for acceptance, staples and validates the ticket, and runs
Gatekeeper assessment before producing `Rack-0.0.1-macOS-universal.zip`.
Signing credentials belong in your keychain, outside this repository.
Adjust the README and release notes to reflect successful notarization
before publishing that variant.

## Publish when the repository exists

1. Create the GitHub repository and add its actual URL as `origin`.
2. Choose the repository's license; this preparation does not select one.
3. Commit the release source, run CI, and do a live launch/listening check.
   Check permission prompts, output switching, microphone monitoring,
   bypass, menu bar controls, and quit behavior on real devices.
4. Change the changelog entry from prepared to the publication date.
5. Commit that update, rebuild the package from the committed source,
   and confirm `sourceHasChanges` is `false` in `release-info.json`.
6. Tag the exact tested commit and push the branch and tag:

```sh
git tag -a v0.0.1 -m 'Rack 0.0.1 preview'
git push origin main
git push origin v0.0.1
```

Create a draft GitHub prerelease from the repository directory:

```sh
gh release create v0.0.1 \
  dist/0.0.1/Rack-0.0.1-macOS-universal-preview.zip \
  dist/0.0.1/SHA256SUMS \
  dist/0.0.1/release-info.json \
  --verify-tag --draft --prerelease \
  --title 'Rack 0.0.1 — First Preview' \
  --notes-file dist/0.0.1/release-notes.md
```

Review the draft's files and installation instructions, then publish it.
Update the README's prepared-release paragraph with a direct download link
after the release is live. Build archives stay out of source control.

## Subsequent versions

Update `CFBundleShortVersionString` and increment `CFBundleVersion` in
`Resources/Info.plist`. Add `docs/releases/VERSION.md`, update `CHANGELOG.md`
and the README, and repeat the verification and packaging steps. The package
script reads the version from the bundle metadata.
