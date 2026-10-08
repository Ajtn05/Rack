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

The full suite renders every theme, including reduced-transparency variants,
to `Tests/RackTests/ThemeScreenshots/`. Those images are intentional visual
review artifacts. README images are selected copies under `docs/images/`;
refresh them when appearance changes.

GitHub CI runs boundary checks, the full debug suite, optimized headless
tests, and universal archive packaging on macOS. It does not launch the live
audio engine or exercise physical devices.

## Clean generated files

```sh
swift package clean
```

For a complete reset, remove `.build/` and `dist/`. Both directories are
generated and ignored by Git. Preserve release archives elsewhere if you
need them before deleting `dist/`.

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
