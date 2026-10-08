import AppKit
import SwiftUI

import DesignSystem

/// A representative composition of the components a real screen assembles,
/// with static sample data standing in for `EngineController` — this is the
/// thing every theme is rendered against, not the live app window, so a
/// screenshot needs no audio engine, no preset store, and no side effects
/// to produce.
private struct ThemeScreenshotComposition: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.panelSpacing) {
            amplifier
            analyzer
            equalizer
        }
        .padding(theme.metrics.panelPadding)
        .background(theme.colors.windowBackground)
        .frame(width: 640)
    }

    private var amplifier: some View {
        RackUnit("Amplifier", status: "RUNNING") {
            SelectorRow(
                items: [SelectorRow.Item(id: "power", label: "Power")],
                selection: ["power"],
                mode: .multiple
            ) { _ in }
        } content: {
            Grid(
                horizontalSpacing: theme.metrics.controlSpacing * 1.6,
                verticalSpacing: theme.metrics.tightSpacing
            ) {
                GridRow {
                    RotaryControl(
                        label: "Volume", value: 0.72, range: 0...1,
                        size: .large, labelPlacement: .none
                    ) { _ in }
                    RotaryControl(
                        label: "Balance", value: 0.2, range: -1...1,
                        detentAtCentre: true, labelPlacement: .none
                    ) { _ in }
                    // `.secondary` so the shot exercises a theme's knob
                    // colour-coding where it has any — `ConsoleBlue` puts
                    // oxblood on level controls and blue on shaping ones,
                    // and a composition that only ever asked for `.primary`
                    // would never show the second colour.
                    RotaryControl(
                        label: "Boost", value: 6, range: 0...12,
                        variant: .secondary, labelPlacement: .none
                    ) { _ in }
                }
                GridRow {
                    LabelledReadout("Volume", Readout("−4.2", unit: "dB", characterCount: 5))
                    LabelledReadout("Balance", Readout("R 20", characterCount: 5))
                    LabelledReadout("Boost", Readout("6.0", unit: "dB", characterCount: 5))
                }
            }

            // Disabled and enabled side by side — one of the states the
            // verification pass asks to check stays distinguishable under
            // every theme.
            HStack(spacing: theme.metrics.controlSpacing) {
                SelectorRow(
                    items: [
                        SelectorRow.Item(id: "on", label: "On"),
                        SelectorRow.Item(id: "off", label: "Off", isEnabled: false)
                    ],
                    selection: ["on"],
                    mode: .multiple
                ) { _ in }
            }
        }
    }

    private var analyzer: some View {
        RackUnit("Analyzer", status: "SPECTRUM") {
            VFDPlate {
                VStack(spacing: theme.metrics.tightSpacing) {
                    SpectrumBars(bands: sampleBands, drawsPlate: false)
                    ResponseCurve(
                        points: sampleCurve,
                        range: -15...15,
                        rules: [ResponseCurve.Rule(value: 0, label: "0", isEmphasised: true)],
                        isOverlay: true
                    )
                    Rectangle()
                        .fill(theme.colors.panelBorder)
                        .frame(height: 1)
                    LevelMeter(
                        channels: [
                            // One at rest, one at full deflection — the pair
                            // the verification pass calls out by name.
                            LevelMeter.Channel(label: "L", position: 0.2, hold: 0.35),
                            LevelMeter.Channel(label: "R", position: 0.98, hold: 1.0)
                        ]
                    )
                }
            }
        }
    }

    private var equalizer: some View {
        RackUnit("Equalizer", status: "10 BAND · ±12 dB") {
            SelectorRow(
                items: [SelectorRow.Item(id: "eq", label: "EQ")],
                selection: ["eq"],
                mode: .multiple
            ) { _ in }
        } content: {
            FaderBank(
                bands: Self.sampleGains.enumerated().map { index, value in
                    FaderBank.Band(
                        id: index, label: "\(index)", value: value,
                        isShelf: index == 0 || index == Self.sampleGains.count - 1
                    )
                },
                range: -12...12
            ) { _, _ in }
        }
    }

    private static let sampleGains: [Double] = [6, -4, 0, 3, -8, 9, 0, 2, -2, 5]

    private var sampleBands: [SpectrumBars.Band] {
        let labels = [3: "50", 10: "200", 17: "1k", 24: "5k", 30: "20k"]
        return (0..<31).map { index in
            let position = Double(index) / 30
            let level = max(0, 0.75 - 0.5 * position + 0.22 * sin(position * .pi * 6))
            return SpectrumBars.Band(level: level, hold: min(1, level + 0.12), label: labels[index])
        }
    }

    private var sampleCurve: [ResponseCurve.Point] {
        (0..<120).map { index in
            let position = Double(index) / 119
            let value = 9 * sin(position * .pi * 2) - 4 * cos(position * .pi * 5)
            return ResponseCurve.Point(position: position, value: value)
        }
    }
}

/// Renders `view` under `theme` and encodes it as PNG data, or nil if
/// rendering produced nothing — a blank window is exactly the failure this
/// exists to catch, not something to write to disk and call a pass.
@MainActor
private func renderPNG(
    _ theme: any Theme,
    scale: CGFloat = 2,
    reduceTransparency: Bool = false
) -> Data? {
    let renderer = ImageRenderer(
        content: ThemeScreenshotComposition()
            .theme(theme)
            .environment(\.rackReduceTransparency, reduceTransparency)
    )
    renderer.scale = scale
    guard let cgImage = renderer.cgImage else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
}

/// One screenshot per registered theme, so a change to a token or a
/// component shows up as a change to a file `git diff` already knows how to
/// flag — the lightweight version of a snapshot test this project's
/// Xcode-free toolchain has no framework for.
///
/// Normal runs update the repository's review images. Organized build runs
/// set RACK_THEME_SCREENSHOT_DIR to retain images with that build's report,
/// without changing the committed source while verification is in progress.
@MainActor
func runThemeScreenshotTests() {
    let directory: URL
    if let path = ProcessInfo.processInfo.environment["RACK_THEME_SCREENSHOT_DIR"], !path.isEmpty {
        directory = URL(fileURLWithPath: path, isDirectory: true)
    } else {
        directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/RackTests/ThemeScreenshots", isDirectory: true)
    }

    Check.suite("Theme screenshots — every registered theme renders the full composition") {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for theme in ThemeRegistry.all {
            guard let data = renderPNG(theme) else {
                Check.isTrue(false, "\(theme.displayName) failed to render — a blank or crashed composition")
                continue
            }
            Check.isTrue(data.count > 0, "\(theme.displayName) produced non-empty image data")

            let url = directory.appendingPathComponent("\(theme.id).png")
            do {
                try data.write(to: url)
            } catch {
                Check.isTrue(false, "\(theme.displayName) rendered but could not be written: \(error)")
            }
        }
    }

    Check.suite("Theme screenshots — the reduced-transparency path renders") {
        // Every material collapses to its base colour when the system asks
        // for reduced transparency, and every bevel and engraved relief stops
        // being drawn. That path has to stay a usable interface rather than a
        // degraded one, so it is rendered here too — and written out beside
        // the normal shots, because the only way to know it still looks like
        // the theme is to be able to look at it.
        for theme in ThemeRegistry.all {
            guard let data = renderPNG(theme, reduceTransparency: true) else {
                Check.isTrue(
                    false,
                    "\(theme.displayName) failed to render with reduced transparency"
                )
                continue
            }
            Check.isTrue(
                data.count > 0,
                "\(theme.displayName) renders with reduced transparency"
            )
            do {
                try data.write(to: directory.appendingPathComponent("\(theme.id)-reduced.png"))
            } catch {
                Check.isTrue(false, "\(theme.displayName) reduced preview could not be written: \(error)")
            }
        }
    }
}
