// MARK: - Why these are separate `View` types
//
// Every panel used to be a computed property on `RackScreen` itself — see
// git history. That put all of them behind one `body`, and `@Observable`
// tracks dependencies per *view body invocation*, not per computed property:
// a single `RackScreen.body` call that happened to read `engine.meterLeft`
// anywhere in its (very long) expression tree made *every* engine property
// read anywhere else in that same call a dependency too. The meters and the
// spectrum update up to thirty times a second while the amplifier runs, so
// that one shared dependency set meant the *entire* window — the Presets
// panel, the theme swatches in Appearance, the device list in Output, none
// of which have anything to do with a meter ballistic — was fully
// reconstructed and re-diffed on every tick, not just displayed once and
// left alone.
//
// That was a tolerable cost when a panel was a flat rounded rectangle with a
// border. It stopped being one once panels gained a procedural material, a
// bevel, corner screws, a knob skirt with eleven tick marks apiece — the
// shape of the reconstruction didn't change, but its weight did, and
// reconstructing all of that thirty times a second for panels nobody was
// watching is most of where the energy went.
//
// Splitting each panel into its own `View` gives `@Observable` a separate
// dependency set per panel: `AnalyzerPanel` and `DiagnosticsPanel` read the
// fast-changing properties and legitimately redraw at poll rate: everything
// else reads only what the user's own actions change, and now actually stays
// idle between them.
//
// This discipline is why the panels themselves live in `RackPanels+*.swift`,
// one file per weight/cohesion group, rather than all together here as they
// once did — a single 1300-line file was its own kind of hazard, if not the
// `@Observable` one above. Each split file's panels remain individually
// distinct `View` types for the reason documented above; do not consolidate
// panels back into a shared body or a single generic renderer that reads all
// engine state at once, in this file or any other.
