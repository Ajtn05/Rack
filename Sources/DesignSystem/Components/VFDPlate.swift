import SwiftUI

/// One glass, one plate: the shared face a VFD or LCD readout draws its
/// content on.
///
/// Every readout in this system already draws its own version of this — the
/// same background, the same border, the same corner radius — because each
/// was built to stand alone. Grouping several of them into one instrument (a
/// spectrum, a stereo meter, a peak digit — the way a real hi-fi's display
/// tube shows all three under one piece of smoked glass) only reads as one
/// instrument if they share a single plate rather than each carrying its
/// own. This is that shared plate; nothing placed inside it should draw a
/// second one of its own.
public struct VFDPlate<Content: View>: View {
    @Environment(\.theme) private var theme

    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(theme.metrics.tightSpacing)
            .background(
                RoundedRectangle(cornerRadius: theme.chrome.cornerRadius)
                    .fill(theme.colors.readoutBackground)
            )
            .overlay(border)
    }

    @ViewBuilder
    private var border: some View {
        if theme.chrome.borderWidth > 0 {
            RoundedRectangle(cornerRadius: theme.chrome.cornerRadius)
                .strokeBorder(theme.colors.panelBorder, lineWidth: theme.chrome.borderWidth)
        }
    }
}

/// Rendered under every registered theme, so a new skin shows up here
/// without anyone writing a preview for it.
///
/// `PreviewProvider` rather than the `#Preview` macro: that macro needs a
/// plugin that ships inside Xcode, and this package must build with Command
/// Line Tools alone.
struct VFDPlate_Previews: PreviewProvider {
    static var previews: some View {
        ThemeGallery {
            VFDPlate {
                VStack(alignment: .leading, spacing: 4) {
                    Text("One glass, several instruments")
                    Text("Second line")
                }
                .padding()
            }
            .frame(width: 260)
        }
    }
}
