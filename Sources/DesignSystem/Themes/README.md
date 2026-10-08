# Themes

This directory is the only place in Rack where an appearance value may appear
as a literal. A hex string, a `Color(red:)`, a named colour like `Color.teal`,
or a system font like `.font(.title)` anywhere else **fails the build** — see
`Scripts/check-boundaries.sh`, rules 5 and 6.

Everything outside this directory reads its appearance from an injected `Theme`
through `@Environment(\.theme)`. That is what makes a skin swappable: "make it
look like a Braun radio" is one new file here and one line in the registry,
touching no view and no audio code.

## Adding a theme

1. **Copy an existing theme file** in this directory. `SystemTheme.swift` is
   the smaller starting point; `TechnicsTheme.swift` shows what a strongly
   opinionated skin looks like.
2. **Rename the type** and give it a new `id` (stable, lowercase, never shown)
   and `displayName` (what the picker shows).
3. **Fill in every token.** There are no defaults, on purpose: a missing role
   should be a compile error, not a value silently inherited from another skin.
4. **Add one line to `ThemeRegistry.all`.**
5. Build. The theme now appears in the Appearance selector and in every
   component preview automatically — `ThemeGallery` renders each component once
   per registered theme, so nobody has to write a preview for the new skin.

That is the whole procedure. If you find yourself editing a file outside this
directory, something has gone wrong and the boundary check will say so.

## Colour reference

Every name describes **what the colour is for**, never what it looks like. A
token called `teal` or `darkGray` is a bug: it stops meaning anything the
moment a second theme exists.

| Token | Where it is drawn |
|---|---|
| `windowBackground` | Behind the whole rack. |
| `panelBackground` | The face of a `RackUnit`. Unused when `chrome.panelStyle` is `.continuous`. |
| `panelBorder` | A `RackUnit`'s edge, the fader centre line, the knob rim. Unused when `chrome.borderWidth` is 0. |
| `readoutBackground` | The glass behind a `Readout`. Unused when `chrome.displayStyle` is `.printed`. |
| `readoutForeground` | The lit value in a `Readout`. |
| `readoutDim` | The faintest mark on a display's own glass — `ResponseCurve`'s gridlines. |
| `meterNominal` | A `LevelMeter` bar below its hot threshold. |
| `meterHot` | The same bar above it. |
| `meterHold` | The peak-hold marker. |
| `controlActive` | Anything engaged: a lit indicator lamp on a pushbutton, a fader away from centre, an emphasised readout. A button's *legend* stays `labelPrimary` whatever its state — the lamp reports the state — so this no longer has to be dark enough to reverse text on. |
| `controlIdle` | A fader cap sitting at centre. |
| `controlTrack` | Fader grooves and meter backgrounds — things that are *recessed*. |
| `buttonFace` | The face of a pushbutton cap. Its own token for the same reason `knobFace` is: a cap is a separate physical part from the panel and from the grooves `controlTrack` describes. On a dark theme it should be **lighter** than `panelBackground`, or the button reads as a hole. |
| `labelPrimary` | Unit titles, control values. |
| `labelSecondary` | Captions, units, fader legends, status lines. |
| `meterFace` | The lit face behind a `NeedleMeter` — the VU needles, and the compressor's gain-reduction meter. |
| `meterScale` | The printed scale and tick marks on that face. |
| `meterNeedle` | The needle itself. |
| `meterZoneWarning` | The region of a needle scale past its `warningThreshold` — `meterHot` for a needle rather than a bar. VU's red zone above 0 VU is the reference case; the gain-reduction meter passes a threshold that never fires, since a real GR meter has no red zone of its own. |
| `readoutLevel` | The spectrum's own lit colour, and the goniometer's dots, when a theme needs one distinct from `meterNominal` — falls back to it (`theme.colors.readoutLevel ?? theme.colors.meterNominal`) when a theme leaves it `nil`, which is most of them. |
| `displayGlow` | Bloom colour for a readout that emits light. Paired with `metrics.displayGlowRadius`; only drawn when `chrome.displayStyle` is `.emissive`. |
| `knobFace` | A knob's face — `RotaryControl` only. Distinct from `controlTrack` so a knob can read as its own physical object rather than sharing a fader's groove colour. |
| `knobIndicator` | The knob's pointer. |
| `knobArc` | The knob's value arc. |
| `knobRing` | The knob's rim — a hairline when `chrome.knobStyle` is `.flush`, a trim ring when `.raised`. |
| `panelHighlight` | The edge that catches the light on a raised panel, knob or button cap. Must be lighter than `buttonFace` when `chrome.buttonStyle` is `.raised`, or the cap's top rim reads as a second shadow. |
| `panelShadow` | The edge falling away from it, and the drop shadow underneath a raised panel or knob. |
| `accentWarm` | A second accent for a theme built around two, not one. Themes with a single accent set this and `accentCool` to the same colour. |
| `accentCool` | The other one. |

## Typography reference

| Token | Where |
|---|---|
| `unitTitle` | `RackUnit` heading. Tracked wider when `panelStyle` is `.separated`, to read as a silkscreened legend. |
| `unitStatus` | The line under it. |
| `readout` | The number in a `Readout`. Should be monospaced-digit, or values jitter as they count. |
| `readoutUnit` | The "dB" or "Hz" beside it. |
| `label` | Control labels and chip text. |
| `caption` | Fader legends, diagnostic labels, meter channel letters. |
| `displayFace` | What `readout` and `readoutUnit` are built from. Give this a family of its own before giving `unitTitle` one — a theme with only one distinct face should spend it here. |
| `labelFace` | What `unitStatus`, `label` and `caption` are built from. |
| `brandFace` | What `unitTitle` — the panel's own "brand" — is built from. The one place a theme's typographic personality (a transitional serif, Helvetica) is most visible. |

These three are not read by any component directly; they exist so a theme
file has a place to decide "these three things are different families" once,
rather than repeating that decision six times across the granular tokens
above, which are what components actually read.

## Metrics reference

All in points. `panelPadding`, `panelSpacing`, `controlSpacing`, `tightSpacing`
for layout; `faderTrackWidth`, `faderHeight`, `faderCapHeight`, `meterHeight`,
`knobDiameter`, `readoutMinWidth` for component sizing. `displayGlowRadius`
pairs with `colors.displayGlow` — 0 for anything other than an `.emissive`
display style, since there is no "no colour", only "no glow".

## Chrome reference

Chrome is not decoration — it changes how a screen is **assembled**, which is
why it lives in the theme rather than in the views.

| Token | Effect |
|---|---|
| `panelStyle` | `.separated` gives each `RackUnit` its own background and edge — a stack of boxes bolted into a rack. `.continuous` draws neither, so units are grouped by whitespace alone and the window reads as one surface. |
| `displayStyle` | `.segmented` and `.emissive` both set the value on its own lit plate; `.emissive` adds a real bloom (`colors.displayGlow` / `metrics.displayGlowRadius`) and lights the indicator lamp on every button to match. `.printed` is ink on the panel — no plate, no glow, ever. |
| `cornerRadius` | Panels, readouts, chips, fader caps. |
| `borderWidth` | 0 removes every border, and the components check for it rather than drawing a zero-width line. |
| `showsCentreDetent` | Whether faders and knobs snap to the middle of their range. A hi-fi fader has a physical notch at 0; a plain slider should not silently refuse to sit at −0.3 dB. |
| `isLight` | Whether this is a light theme. Colours are already authored per-theme and never need this to pick one over another; it exists for the handful of places a *structural* choice — how strong a relief shadow reads — genuinely differs against a bright panel versus a dark one. |
| `knobStyle` | `.flush` is a flat knob face. `.raised` adds a crescent of `panelHighlight` along the rim and a drop shadow lifting it off the panel. |
| `buttonStyle` | `.flat` fills a pushbutton with `controlTrack`, tinting it faintly with `controlActive` when down. `.raised` shades it from `panelHighlight` / `panelShadow` and *reverses* that shading when down, so the button reads as physically pressed in. Independent of `knobStyle` and `panelRelief`: `TechnicsTheme` has flat panels and flush knobs but unmistakably physical buttons. |
| `panelRelief` | `.flat` is a plain panel — every theme before this one. `.inset` and `.raised` draw a bevel from `panelHighlight` / `panelShadow` (reversed between the two) plus, for `.raised`, a drop shadow. |
| `usesSideCheeks` | Wood or metal cabinet edges on the window frame. Read by `RackScreen`, not by any component here — it is a screen-level decoration, not a per-unit one. |
| `meterStyle` | `.bar` or `.needle`. No component reads this yet; the needle meter it is for is Part 2. |

## The two shipping themes

**`TechnicsTheme`** — dark warm-grey panels (not black; true black reads as a
hole in the screen), teal fluorescent readouts, amber for anything engaged,
monospaced faces, separated units with visible edges and a centre detent.

**`SystemTheme`** — standard macOS materials, the user's accent colour, system
fonts, no borders, one continuous surface. Adapts to light and dark
automatically because every colour is a semantic system colour rather than a
fixed value.

`SystemTheme` exists to keep the others honest. One theme is indistinguishable
from hardcoding; it is only when a second exists, and looks nothing like the
first, that a token named `panelBackground` has to actually mean something.

## The material layer

Everything below is **procedural**. There are no bitmap panels in this
project and there should never be: a shipped PNG is soft on Retina at
non-integer scale, bloats the download, cannot be resized, and turns a theme
from one editable Swift file into an art pipeline.

A theme that says nothing about any of this is flat, unlit and unbolted —
which is a coherent thing to be, and is exactly what the pre-material themes
were. Unlike `colors` and friends, these carry protocol defaults; every
shipped theme still states them explicitly so nothing is special-cased.

| Token | Effect |
|---|---|
| `panelMaterial` / `windowMaterial` | What the surface is made of. `.flat`, `.brushedMetal`, `.paintedSteel`, `.bakelite`, `.enamel`, `.wood`, `.glass`, `.clothGrille`, `.anodised`. |
| `knobMaterial` / `buttonMaterial` / `meterFaceMaterial` | The same, for parts rather than panels. |
| `meterGlass` | An optional pane over a needle meter, or nil for an unglazed one. |
| `lighting` | **One light source for the whole window.** Every bevel, drop shadow, specular highlight and needle shadow derives from it. |
| `panelBevel` / `knobBevel` / `buttonBevel` / `displayBevel` | Edge treatment. `.raised` puts the highlight on the lit edge, `.inset` swaps it, and *which edge that is* comes from `lighting.angle` — never from the component. |
| `engraving` | `.silkscreen`, `.engraved`, `.embossed`, `.etched(fill:)`. Labels on real gear are physically part of the panel; flat text on a bevelled panel is the commonest tell that a skin is fake. |
| `hardware` | Screws, rack ears, side cheeks, panel seams, handles. All optional, all procedural. |

### The rules that are not negotiable

**Keep the amplitude low.** The difference between painted steel and a JPEG
artefact is almost entirely intensity. Convincing values for grain, mottle and
orange peel are nearly all under 0.15; the renderer clamps at 0.6 as a
backstop, not as a licence.

**Never hardcode a shadow offset.** Ask `lighting.shadowOffset(forHeight:)`.
A single fixed `y: 2` somewhere breaks the effect for the entire window,
because the eye reads the *disagreement* between two shadows long before it
reads either one.

**Only the indicator rotates.** A knob's cap turns but the light on it does
not follow, so its highlight and cast shadow stay put. Rotating the shading
with the value is the commonest way this gets built backwards.

**Textures never move a surface's mean.** Every one is centred on mid-grey and
composited in `overlay` blend, so `material.baseColor` *is* the surface's
average luminance. That is what lets `ThemeContrastTests` check text against a
base colour and stay honest, and what lets the reduced-transparency path
collapse to that colour without shifting any contrast ratio.

**Legibility survives everything.** `ThemeContrastTests` measures every theme
against WCAG AA on each run. A texture that eats contrast gets its intensity
reduced — not its text recoloured.
