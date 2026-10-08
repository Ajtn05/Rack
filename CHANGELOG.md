# Changelog

## 0.0.2 — configurable UI components (preview candidate)

- Add Settings with switches for showing or hiding rack components.
- Show Amplifier, Analyzer, Equalizer, and Sound Field Processor by default.
- Keep the amplifier visible at all times.
- Restore component visibility after relaunch without changing audio settings,
  rack order, or panel size preferences.
- Open Settings from the amplifier, the menu bar, or the ⌘, shortcut.
- Add regression coverage for visibility, required components, and persistence.
- Fix Intel compilation and keep theme contrast checks in headless CI environments.

Manual listening and device checks remain pending for this preview candidate.
See [release notes](docs/releases/0.0.2.md).

## 0.0.1 — first preview (prepared, unpublished)

- System-wide audio processing through Core Audio process taps.
- Ten-band graphic EQ, tone controls, preamp, balance, and boost contour.
- Tape/tube saturation, compression, limiting, reverb, echo, stereo width,
  and headphone crossfeed.
- Per-application volume and mute controls.
- Spectrum, VU, frequency response, overlay, pulse, goniometer, and
  oscilloscope analyzer modes.
- Output selection, optional microphone monitoring, and feedback protection.
- Presets, device/app switching rules, and session restoration.
- Thirteen themes, rearrangeable panels, menu bar controls, login item,
  and global keyboard shortcuts.
- Universal macOS archive packaging, checksums, and continuous integration.
- Organized verification, immutable test builds and release candidates,
  retained logs/screenshots, and promotion of the exact tested archive.

Requires macOS 14.4 or later. The ad-hoc signed preview is not notarized.
See [release notes](docs/releases/0.0.1.md) for installation and validation scope.
