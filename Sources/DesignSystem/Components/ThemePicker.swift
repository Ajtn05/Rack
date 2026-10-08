import SwiftUI

/// Picks a skin, by showing what each one actually looks like.
///
/// The row of chips this replaces had a real problem that only got worse as
/// themes were added: every entry was drawn in the *current* theme, so twelve
/// identical grey buttons differed by nothing but their text. Choosing meant
/// reading a name, guessing, applying it, and undoing — for each one.
///
/// A swatch shows the thing itself. Each tile is rendered in **its own**
/// theme — its panel material, its lighting, its accent, its label colour —
/// so the picker is a shelf of little front panels and the choice is made by
/// looking rather than by recall. The extra cost is one small
/// `MaterialSurface` per theme, all of them cached and none of them animating.
public struct ThemePicker: View {
    @Environment(\.theme) private var theme

    private let selection: String
    private let onSelect: (String) -> Void

    public init(selection: String, onSelect: @escaping (String) -> Void) {
        self.selection = selection
        self.onSelect = onSelect
    }

    /// Wide enough for the longest display name at caption size without
    /// truncating, which is what sets the column rather than the swatch.
    private var tileWidth: CGFloat { theme.metrics.appNameWidth * 0.78 }
    private var swatchHeight: CGFloat { theme.metrics.knobDiameter * 0.62 }

    public var body: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: tileWidth),
                    spacing: theme.metrics.controlSpacing,
                    alignment: .leading
                )
            ],
            alignment: .leading,
            spacing: theme.metrics.controlSpacing
        ) {
            ForEach(ThemeRegistry.all, id: \.id) { entry in
                tile(entry)
            }
        }
    }

    private func tile(_ entry: any Theme) -> some View {
        let isSelected = entry.id == selection

        return Button {
            guard !isSelected else { return }
            onSelect(entry.id)
        } label: {
            VStack(alignment: .leading, spacing: theme.metrics.tightSpacing * 0.6) {
                swatch(entry)

                Text(entry.displayName)
                    .font(theme.typography.caption)
                    // The *host* theme's label colour, not the entry's: this
                    // text sits on the panel you are currently looking at, not
                    // on the swatch above it.
                    .foregroundStyle(
                        isSelected ? theme.colors.labelPrimary : theme.colors.labelSecondary
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A miniature of the theme's own front panel: its material, with a bar
    /// of its accent and a dot of its readout colour — the two things that
    /// most distinguish one skin from another at this size.
    private func swatch(_ entry: any Theme) -> some View {
        let isSelected = entry.id == selection
        let shape = RoundedRectangle(cornerRadius: theme.chrome.cornerRadius)

        return ZStack(alignment: .bottomLeading) {
            MaterialSurface(entry.panelMaterial)

            HStack(spacing: theme.metrics.tightSpacing * 0.5) {
                // The accent — what "engaged" looks like on that theme.
                Capsule()
                    .fill(entry.colors.controlActive)
                    .frame(width: tileWidth * 0.32, height: swatchHeight * 0.13)
                // The display, which is often the most characterful colour a
                // theme has.
                Circle()
                    .fill(entry.colors.readoutForeground)
                    .frame(width: swatchHeight * 0.15, height: swatchHeight * 0.15)
            }
            .padding(theme.metrics.tightSpacing * 0.8)
        }
        // Rendered in the entry's own theme, which is the whole point — the
        // material, its lighting and its bevel all have to come from the
        // theme being previewed, not from the one currently applied.
        .theme(entry)
        .frame(height: swatchHeight)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                isSelected ? theme.colors.controlActive : theme.colors.panelBorder,
                lineWidth: isSelected
                    ? max(theme.chrome.borderWidth, 1) * 2.5
                    : max(theme.chrome.borderWidth, 1)
            )
        )
    }
}

/// Rendered under every registered theme, so a new skin shows up here
/// without anyone writing a preview for it.
///
/// `PreviewProvider` rather than the `#Preview` macro: that macro needs a
/// plugin that ships inside Xcode, and this package must build with Command
/// Line Tools alone.
struct ThemePicker_Previews: PreviewProvider {
    static var previews: some View {
        ThemeGallery {
            ThemePicker(selection: "technics") { _ in }
                .frame(width: 420)
        }
    }
}
