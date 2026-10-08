# Developing Rack

Rack builds with Swift Package Manager and Apple's Command Line Tools with
Swift 6.0 or later. There is no Xcode project and no external package dependency.
The minimum deployment version is macOS 14.4.

## Build and run

```sh
sh Scripts/build-app.sh --run
sh Scripts/build-app.sh --release
sh Scripts/build-app.sh --release --universal --ad-hoc
```

Bundles live at `.build/app/debug/Rack.app` and
`.build/app/release/Rack.app`. Universal builds compile `arm64` and `x86_64`
separately under `.build/universal/` and combine the executables with `lipo`.

The bundle script signs every build. It uses `RACK_SIGN_IDENTITY` when set,
then a local `Rack Local Signing` certificate if present, then an ad-hoc
signature. `--ad-hoc` explicitly overrides certificate selection.

For a stable local audio permission grant across rebuilds, optionally create
the development certificate once per machine:

```sh
sh Scripts/make-signing-cert.sh
```

This certificate is for local development. Release packaging uses ad-hoc
signing unless you explicitly supply a signing identity.

## Verify changes

Use the organized runner when declaring a build verified:

```sh
python3 Scripts/release.py verify
python3 Scripts/release.py test-build
```

It retains command logs, structured results, and theme previews with each
run. The full process is in [BUILD_SYSTEM.md](BUILD_SYSTEM.md).
For targeted development checks, the underlying commands remain available:

```sh
sh Scripts/check-boundaries.sh
sh Scripts/check-test-registration.sh
swift run RackTests
swift run -c release -Xswiftc -enable-testing RackTests --headless
```

`RackTests` is a custom executable harness; use `swift run RackTests` rather
than `swift test`. `--headless` skips AppKit appearance checks and SwiftUI
screenshot rendering while keeping the audio and model suites.
Release tests need `-enable-testing` because they import internal module APIs.

The full suite renders every theme, including reduced-transparency variants.
The organized runner stores them in the build's validation directory. A
direct `swift run RackTests` updates `Tests/RackTests/ThemeScreenshots/`;
use that when refreshing the intentional visual review assets. README images
under `docs/images/` show the current app panels with sample audio data;
refresh them when appearance changes.

GitHub CI runs the same verification on Apple silicon and Intel, then packages
the exact verified source for testing. It does not launch the live audio
engine or exercise physical devices.

## Clean generated files

```sh
python3 Scripts/release.py clean
python3 Scripts/release.py clean --apply
```

This previews or applies cache/test-build retention while preserving app
bundles, the last successful test build, and all release candidates. `dist/`
is the ignored local build history; do not delete it wholesale during cleanup.

## Read before changing code

| Guide | Scope |
| --- | --- |
| [Architecture](../ARCHITECTURE.md) | Modules, boundaries, signing, persistence |
| [Audio engine](../AUDIO.md) | Process taps, DSP, realtime rules, device changes |
| [Interface](../UI.md) | View models, panels, meter behavior, themes |
| [Theme authoring](../Sources/DesignSystem/Themes/README.md) | Theme tokens and registration |

Run the relevant tests for DSP or model changes. For interface changes, also
inspect the rendered theme previews. Historical review records are in
[CODE-QUALITY-REVIEW.md](../CODE-QUALITY-REVIEW.md) and
[SANDBOX-REVIEW.md](../SANDBOX-REVIEW.md); they describe the code at their review dates.
