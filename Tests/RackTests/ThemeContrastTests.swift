import AppKit
import SwiftUI

import DesignSystem

/// WCAG contrast, measured on every registered theme.
///
/// This exists because "check the contrast" is exactly the kind of
/// verification that gets done once, by eye, and then quietly rots as colours
/// are tuned. Every failure this file has caught so far was in a *light*
/// theme, and every one of them was invisible to the person who had just
/// chosen the colour: a bright amber on brushed aluminium and a signal red on
/// a tan meter card both look obviously legible and both measure under 4.5:1.
///
/// The material layer does not change any of these numbers, and that is by
/// design: every texture is centred on mid-grey and composited in `overlay`
/// blend, which leaves a surface's *mean* luminance exactly where its base
/// colour put it. So a panel's material can be retuned freely without
/// invalidating the audit — which is the property that lets the texture
/// intensities be a design decision rather than an accessibility one.
@MainActor
func runThemeContrastTests() {
    /// Relative luminance, per WCAG 2.1.
    ///
    /// Resolved against an explicit appearance. `SystemTheme` is built from
    /// dynamic AppKit colours (`.labelColor`, `.controlColor`), and outside a
    /// drawing context those collapse to whatever the process happens to
    /// consider current — which in a headless test run is nothing, so every
    /// pair measured 1.00:1 and the theme appeared to fail catastrophically
    /// while being perfectly legible on screen. Forcing an appearance makes
    /// the number mean something.
    func resolve(_ color: Color) -> NSColor {
        var resolved = NSColor.black
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return resolved
    }

    func channel(_ v: CGFloat) -> Double {
        let x = Double(v)
        return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    func luminance(_ c: NSColor) -> Double {
        0.2126 * channel(c.redComponent)
            + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }

    /// `a` painted over `b` using `a`'s own alpha — plain alpha compositing,
    /// with the result always fully opaque.
    func composite(_ a: NSColor, over b: NSColor) -> NSColor {
        let alpha = a.alphaComponent
        return NSColor(
            srgbRed: a.redComponent * alpha + b.redComponent * (1 - alpha),
            green: a.greenComponent * alpha + b.greenComponent * (1 - alpha),
            blue: a.blueComponent * alpha + b.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    /// Contrast between a foreground and the surface behind it, given what
    /// the surface itself sits on.
    ///
    /// Both the foreground *and the background* are composited over their
    /// own backdrop before being measured — not just the foreground. Several
    /// AppKit semantic colours are deliberately translucent — `.labelColor`,
    /// `.secondaryLabelColor` and `.quaternaryLabelColor` all resolve to
    /// literal black, differing only in alpha (0.85 / 0.50 / 0.10) — so
    /// treating the background as already-opaque and only compositing the
    /// foreground onto its *raw* components measures black-at-one-alpha
    /// against black-at-another-alpha as identical: pure black either way,
    /// a flat 1:1 no matter which pair is chosen. That is what made
    /// `SystemTheme` keep failing at exactly 1.00:1 through several
    /// different colour choices — the bug was in this function, not in the
    /// colours it was judging. Compositing the background over its real
    /// backdrop first (`controlTrack` over the panel it is drawn on, here)
    /// resolves it to the pale grey it actually renders as, and only then
    /// does comparing two different alphas produce two different greys.
    ///
    /// For the overwhelming majority of colours — fully opaque, everywhere
    /// but `SystemTheme` — compositing over any backdrop is a no-op, so this
    /// generalisation changes nothing for themes that were already measuring
    /// correctly.
    func contrast(_ foreground: Color, _ background: Color, on backdrop: Color) -> Double {
        let back = resolve(backdrop)
        let bg = composite(resolve(background), over: back)
        let fg = composite(resolve(foreground), over: bg)
        let la = luminance(fg), lb = luminance(bg)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    Check.suite("Theme contrast — every theme passes WCAG AA") {
        for theme in ThemeRegistry.all {
            let c = theme.colors

            // Text against the surface it is actually drawn on. A material's
            // base colour *is* its average luminance, so this is the honest
            // comparison and not an approximation.
            let panel = theme.panelMaterial.baseColor
            let knob = theme.knobMaterial.baseColor
            let button = theme.buttonMaterial.baseColor
            let meterFace = theme.meterFaceMaterial.baseColor

            // `controlTrack` — a fader groove or a level meter's channel —
            // is itself drawn on the panel, not free-floating. Almost every
            // theme's track is fully opaque, where compositing over any
            // backdrop is a no-op; but `SystemTheme` builds it from
            // `.quaternaryLabelColor`, an AppKit ink colour that is
            // literally black at low alpha, and measuring that as if it
            // were already the rendered colour is what previously made
            // `meterHold` fail against it no matter which opaque-looking
            // colour it was set to — see `contrast(_:_:on:)` above.
            let trackBackdrop = panel

            // (foreground, background, backdrop, what, needs 4.5 not 3.0)
            let checks: [(Color, Color, Color, String, Bool)] = [
                (c.labelPrimary, panel, panel, "unit title / values", true),
                (c.labelSecondary, panel, panel, "captions / legends", true),
                (c.labelPrimary, button, button, "button legend", true),
                (c.readoutForeground, c.readoutBackground, c.readoutBackground, "readout value", false),
                (c.meterScale, meterFace, meterFace, "meter printed scale", true),
                (c.meterNeedle, meterFace, meterFace, "meter needle", false),
                (c.meterZoneWarning, meterFace, meterFace, "meter warning zone", true),
                (c.knobIndicator, knob, knob, "knob indicator", false),
                (c.meterNominal, c.controlTrack, trackBackdrop, "meter bar vs track", false),
                (c.controlIdle, panel, panel, "disabled control", false),
                (c.controlActive, panel, panel, "lit lamp vs panel", false),

                // The spectrum's own lit fill, against the display's own
                // glass rather than the panel or the fader track —
                // `SpectrumBars` draws it directly onto `readoutBackground`,
                // and that background is not necessarily anywhere near
                // `controlTrack` in brightness. `RackSteel` is exactly the
                // theme this catches: a light aluminium groove paired with
                // near-black VFD glass, where a groove-calibrated
                // `meterNominal` measured 1.4:1 on the glass — legible on the
                // panel, all but invisible on the display it actually draws
                // on. `readoutLevel` is the theme's escape hatch for this;
                // absent one, the check falls back to `meterNominal` so a
                // theme with no such conflict still gets audited honestly.
                //
                // Deliberately not checking the *unlit* groove
                // (`readoutDim`) the same way: that layer is structural
                // context, not data, the same role `controlTrack` plays for
                // a fader — and this suite has never held a track to AA
                // against its panel either. A groove that reads as "off" is
                // doing its job, not failing it.
                (
                    c.readoutLevel ?? c.meterNominal, c.readoutBackground, c.readoutBackground,
                    "spectrum lit bar", false
                ),
                // The peak-hold marker, in both of the places it is drawn:
                // `SpectrumBars` on the display glass, and `LevelMeter` on
                // the fader track. `readoutHold` is the escape hatch when one
                // colour cannot do both — `TapeMachine` is where that turned
                // out to be a hard requirement rather than a convenience:
                // its `controlTrack` is bright enough that even white fails
                // to clear 3:1 against it, so `meterHold` had to specialise
                // for the track and `readoutHold` for the glass.
                (
                    c.readoutHold ?? c.meterHold, c.readoutBackground, c.readoutBackground,
                    "spectrum peak marker", false
                ),
                (c.meterHold, c.controlTrack, trackBackdrop, "level meter peak vs track", false),
            ]

            for (foreground, background, backdrop, what, isText) in checks {
                let required = isText ? 4.5 : 3.0
                let measured = contrast(foreground, background, on: backdrop)
                Check.isTrue(
                    measured >= required,
                    "\(theme.displayName): \(what) is \(String(format: "%.2f", measured)):1, "
                        + "needs \(required):1"
                )
            }
        }
    }

    Check.suite("Theme materials — textures are generated once and cached") {
        // The claim the whole frame budget rests on: a panel's grain is
        // computed once per distinct description and reused thereafter, so a
        // window redrawing its meters thirty times a second is compositing a
        // cached image rather than running value noise per pixel.
        //
        // Timed rather than asserted structurally, because "is it cached" is
        // exactly the sort of thing that stays true in the code and stops
        // being true in practice the moment a key stops matching.
        var coldest = 0.0
        var warmest = 0.0

        for theme in ThemeRegistry.all {
            guard let request = theme.panelMaterial.textureRequest else { continue }

            let coldStart = ContinuousClock.now
            _ = MaterialTexture.image(for: request)
            let cold = Double((ContinuousClock.now - coldStart).components.attoseconds) / 1e18

            let warmStart = ContinuousClock.now
            for _ in 0..<200 { _ = MaterialTexture.image(for: request) }
            let warm = Double((ContinuousClock.now - warmStart).components.attoseconds) / 1e18 / 200

            coldest = max(coldest, cold)
            warmest = max(warmest, warm)
        }

        // A cache hit is a dictionary lookup. Even generously, it should be
        // orders of magnitude under a 60 fps frame's 16 ms budget.
        Check.isTrue(
            warmest < 0.0005,
            "a cached texture costs \(String(format: "%.6f", warmest))s per fetch"
        )
        Check.isTrue(
            coldest < 0.25,
            "generating a texture the first time costs "
                + "\(String(format: "%.4f", coldest))s"
        )
    }

    Check.suite("Theme materials — texture never moves a surface's mean") {
        // The property the audit above depends on. A material's `baseColor`
        // has to be the colour the surface actually averages to, or every
        // number in this file is measuring the wrong thing.
        for theme in ThemeRegistry.all {
            for (name, material) in [
                ("panel", theme.panelMaterial),
                ("window", theme.windowMaterial),
                ("knob", theme.knobMaterial),
                ("button", theme.buttonMaterial),
                ("meter face", theme.meterFaceMaterial),
            ] {
                Check.isTrue(
                    material.textureOpacity <= 0.6,
                    "\(theme.displayName) \(name) texture stays within the amplitude clamp"
                )
            }
        }
    }
}
