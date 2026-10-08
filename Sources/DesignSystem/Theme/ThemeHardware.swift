import SwiftUI

/// The head of a fastener.
public enum ScrewStyle: Equatable, Sendable {
    case phillips
    case hex
    case slotted
}

/// What the cabinet edges are made of.
public enum SideCheekStyle: Equatable, Sendable {
    case wood(ThemeMaterial)
    case metal(ThemeMaterial)

    /// What the cheek is actually made of. The two cases exist so a theme
    /// says *what kind of thing* the cabinet edge is, not just what it looks
    /// like — but both resolve to a material, and that is what gets drawn.
    public var material: ThemeMaterial {
        switch self {
        case .wood(let m), .metal(let m): m
        }
    }
}

/// The optional ironmongery a theme can bolt onto its panels.
///
/// All procedural, all off by default. A theme that wants none of it says
/// nothing and pays nothing — none of these draw when unset, so the flat
/// themes are unaffected.
public struct ThemeHardware: Equatable, Sendable {
    /// Fasteners at panel corners. Nil for a panel that is not visibly bolted
    /// to anything.
    public var screws: ScrewStyle?

    /// 19-inch rack flanges, with mounting holes.
    public var rackEars: Bool

    /// Cabinet edges on the window frame.
    public var sideCheeks: SideCheekStyle?

    /// Visible seams between stacked units — the gap where one chassis ends
    /// and the next begins.
    public var panelSeams: Bool

    /// Handles on the outer frame.
    public var handles: Bool

    /// A strip of a *different* material along the top edge of every panel.
    ///
    /// Console front panels are frequently two pieces: the painted steel face
    /// and a brushed metal extrusion capping it. Nil for a panel milled from
    /// one piece, which is most of them.
    public var topStrip: ThemeMaterial?

    public init(
        screws: ScrewStyle? = nil,
        rackEars: Bool = false,
        sideCheeks: SideCheekStyle? = nil,
        panelSeams: Bool = false,
        handles: Bool = false,
        topStrip: ThemeMaterial? = nil
    ) {
        self.screws = screws
        self.rackEars = rackEars
        self.sideCheeks = sideCheeks
        self.panelSeams = panelSeams
        self.handles = handles
        self.topStrip = topStrip
    }

    /// No ironmongery at all.
    public static let none = ThemeHardware()
}

// MARK: - Drawing

/// A single fastener.
///
/// Its rotation is random per instance but **stably seeded**, from a caller-
/// supplied index. Real screws sit at whatever angle they were driven to, so
/// a row of identically-aligned ones reads as a repeated sprite — but a
/// rotation drawn fresh each render would make them spin every time the
/// window resized, which reads as a fault. Seeding on position gives both:
/// each screw has its own angle, and it is the same angle forever.
public struct Screw: View {
    @Environment(\.theme) private var theme

    let style: ScrewStyle
    /// Distinguishes this screw from the others on the same panel. Any stable
    /// small integer will do; corner index is what callers pass.
    let index: Int
    let diameter: CGFloat

    private var angle: Angle {
        // A hash rather than a random: same index, same angle, every launch.
        .degrees(MaterialNoise.hash(index, 0, 0x5C_2E_00) * 360)
    }

    public init(style: ScrewStyle, index: Int, diameter: CGFloat) {
        self.style = style
        self.index = index
        self.diameter = diameter
    }

    public var body: some View {
        let lighting = theme.lighting
        let slotWidth = max(diameter * 0.1, 1)

        ZStack {
            // The head, lit from the window's own light so it agrees with
            // every other raised thing on the panel.
            Circle()
                .fill(theme.colors.panelHighlight)
            Circle()
                .inset(by: diameter * 0.06)
                .fill(theme.colors.buttonFace)

            // The drive, cut into the head — a shadow, not a line, so it
            // reads as a recess.
            Group {
                switch style {
                case .slotted:
                    Capsule().frame(width: diameter * 0.66, height: slotWidth)
                case .phillips:
                    ZStack {
                        Capsule().frame(width: diameter * 0.6, height: slotWidth)
                        Capsule().frame(width: slotWidth, height: diameter * 0.6)
                    }
                case .hex:
                    RegularPolygon(sides: 6)
                        .stroke(lineWidth: slotWidth)
                        .frame(width: diameter * 0.5, height: diameter * 0.5)
                }
            }
            .foregroundStyle(theme.colors.panelShadow)
            .rotationEffect(angle)
        }
        .frame(width: diameter, height: diameter)
        // Proud of the panel by a fraction of its own size.
        .shadow(
            color: theme.colors.panelShadow.opacity(lighting.shadowStrength),
            radius: lighting.shadowRadius(forHeight: diameter * 0.08),
            x: lighting.shadowOffset(forHeight: diameter * 0.08).width,
            y: lighting.shadowOffset(forHeight: diameter * 0.08).height
        )
        // Decoration only: a screw is not a control and must never eat a
        // click meant for something underneath it.
        .allowsHitTesting(false)
    }
}

/// An n-sided polygon, for the hex drive.
public struct RegularPolygon: Shape {
    let sides: Int

    public init(sides: Int) { self.sides = sides }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for corner in 0..<max(sides, 3) {
            let theta = Double(corner) / Double(max(sides, 3)) * 2 * .pi - .pi / 2
            let point = CGPoint(
                x: centre.x + radius * cos(theta),
                y: centre.y + radius * sin(theta)
            )
            if corner == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// A 19-inch rack flange: the strip either side of a unit, with the mounting
/// holes a real ear is drilled with.
public struct RackEar: View {
    @Environment(\.theme) private var theme

    let width: CGFloat

    public init(width: CGFloat) { self.width = width }

    public var body: some View {
        MaterialSurface(theme.panelMaterial)
            .overlay(alignment: .top) { holes }
            .overlay(alignment: .trailing) {
                // The seam where the ear meets the panel it is bolted to.
                Rectangle()
                    .fill(theme.colors.panelShadow.opacity(0.5))
                    .frame(width: max(theme.chrome.borderWidth, 1))
            }
            .frame(width: width)
            .allowsHitTesting(false)
    }

    /// Two holes, at the spacing a rack unit actually uses — near the top and
    /// near the bottom of each ear rather than evenly distributed, which is
    /// what makes the proportion read as 19-inch hardware.
    private var holes: some View {
        VStack {
            hole
            Spacer(minLength: 0)
            hole
        }
        .padding(.vertical, width * 0.45)
    }

    private var hole: some View {
        let diameter = width * 0.34
        return Capsule()
            .fill(theme.colors.panelShadow)
            .frame(width: diameter, height: diameter * 1.5)
            .overlay(
                // The lit lower lip of a drilled hole.
                Capsule()
                    .strokeBorder(
                        theme.colors.panelHighlight.opacity(0.6),
                        lineWidth: max(theme.chrome.borderWidth, 1) * 0.8
                    )
                    .offset(y: 0.5)
            )
    }
}
