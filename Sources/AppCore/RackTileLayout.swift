import SwiftUI

/// Packs the rack's panels into rows: a panel tagged full width (see
/// `IsFullWidthKey`) always starts a row of its own, and every other panel
/// joins the row already being built as long as doing so does not ask
/// anything in it — the row's existing members, or itself — to go narrower
/// than its own real minimum width.
///
/// That minimum is measured from the panel itself — `sizeThatFits(.unspecified)`
/// — rather than restated as a formula the way `RackScreen.minimumWindowWidth`
/// still does for the window's own floor. A restated formula is what this
/// replaced, and it undercounted anything sized by its own text: a preset's
/// name, a device's name, a reverb preset's legend. There is no way to know a
/// rendered string's width without asking SwiftUI to measure it, and this is
/// exactly that question, asked of the real view instead of guessed at from
/// outside it — so a row this builds can never ask a panel to clip.
struct RackTileLayout: Layout {
    var spacing: CGFloat

    /// Set via `.layoutValue(key:value:)` on each panel — whether it takes a
    /// full row regardless of what would otherwise fit beside it. Mirrors
    /// `EngineController.fullWidthPanels`, which is what a screen actually
    /// reads to set this.
    struct IsFullWidthKey: LayoutValueKey {
        static let defaultValue = false
    }

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? naturalWidth(of: subviews)
        let rows = packRows(subviews: subviews, availableWidth: width)
        return CGSize(width: width, height: totalHeight(of: rows, subviews: subviews, rowWidth: width))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let rows = packRows(subviews: subviews, availableWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            let widths = columnWidths(for: row, subviews: subviews, totalWidth: bounds.width)
            let height = rowHeight(row, subviews: subviews, columnWidths: widths)
            var x = bounds.minX
            for (index, width) in zip(row, widths) {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: width, height: height)
                )
                x += width + spacing
            }
            y += height + spacing
        }
    }

    // MARK: - Packing

    private func packRows(subviews: Subviews, availableWidth: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var currentMinimumSum: CGFloat = 0

        func flush() {
            guard !current.isEmpty else { return }
            rows.append(current)
            current = []
            currentMinimumSum = 0
        }

        for index in subviews.indices {
            let subview = subviews[index]
            if subview[IsFullWidthKey.self] {
                flush()
                rows.append([index])
                continue
            }

            let minimum = subview.sizeThatFits(.unspecified).width
            let candidateSum = currentMinimumSum + minimum
            // One gap for every panel already in the row, plus the one this
            // would add.
            let candidateSpacing = spacing * CGFloat(current.count)
            if current.isEmpty || candidateSum + candidateSpacing <= availableWidth {
                current.append(index)
                currentMinimumSum = candidateSum
            } else {
                flush()
                current = [index]
                currentMinimumSum = minimum
            }
        }
        flush()
        return rows
    }

    // MARK: - Sizing

    /// Each panel in a row gets at least its own measured minimum — never
    /// less, which is the one thing `packRows` already guaranteed the *sum*
    /// of the row would fit — plus an equal share of whatever is left over.
    ///
    /// Splitting the row's width evenly instead, regardless of what each
    /// panel actually asked for, is what let a row `packRows` had correctly
    /// sized *in total* still hand one narrow-content panel more than it
    /// needed while handing a wide-content one less than its own measured
    /// minimum — the exact overflow this layout exists to prevent. A panel
    /// with more to say keeps the room it measured as needing; a panel with
    /// less does not inflate to match it.
    private func columnWidths(for row: [Int], subviews: Subviews, totalWidth: CGFloat) -> [CGFloat] {
        guard row.count > 1 else {
            // A solo full-width panel still has to clear its own measured
            // minimum, the same guarantee `packRows` already gives every
            // multi-panel row by construction (it never adds a panel unless
            // the row's running sum still fits). Without this, a window
            // narrower than the panel's real content — a restored frame from
            // a wider screen, say — would hand the panel less than it needs
            // and it would clip rather than the window ever knowing to grow.
            let measured = subviews[row[0]].sizeThatFits(.unspecified).width
            return [max(totalWidth, measured)]
        }
        let naturals = row.map { subviews[$0].sizeThatFits(.unspecified).width }
        let totalSpacing = spacing * CGFloat(row.count - 1)
        let surplus = max(totalWidth - totalSpacing - naturals.reduce(0, +), 0)
        let extra = surplus / CGFloat(row.count)
        return naturals.map { $0 + extra }
    }

    private func rowHeight(_ row: [Int], subviews: Subviews, columnWidths: [CGFloat]) -> CGFloat {
        zip(row, columnWidths).map { index, width in
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }.max() ?? 0
    }

    private func totalHeight(of rows: [[Int]], subviews: Subviews, rowWidth: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let widths = columnWidths(for: row, subviews: subviews, totalWidth: rowWidth)
            height += rowHeight(row, subviews: subviews, columnWidths: widths)
            if index < rows.count - 1 { height += spacing }
        }
        return height
    }

    /// The layout's own "ideal size" query, for when nothing proposes a
    /// width at all. Nothing in the rack's real usage asks for this — the
    /// scroll view always proposes its actual width — but `sizeThatFits`
    /// still has to answer, and one row of every panel at its own natural
    /// width is the honest answer to "how wide do you want to be."
    private func naturalWidth(of subviews: Subviews) -> CGFloat {
        subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width }
            + spacing * CGFloat(max(subviews.count - 1, 0))
    }
}
