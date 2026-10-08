import DesignSystem
import SwiftUI

/// Available independently of the rack, including when every optional panel
/// is hidden or Rack is running in the menu bar alone.
public struct SettingsScreen: View {
    private let engine: EngineController

    public init(engine: EngineController) {
        self.engine = engine
    }

    public var body: some View {
        RackUnit("UI Components") {
            VStack(alignment: .leading, spacing: engine.theme.metrics.controlSpacing) {
                Text("Choose which components appear in your rack. Hidden components keep their audio settings.")
                    .font(engine.theme.typography.caption)
                    .foregroundStyle(engine.theme.colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(RackPanelKind.defaultOrder, id: \.self) { kind in
                    Toggle(isOn: visibilityBinding(for: kind)) {
                        HStack(spacing: engine.theme.metrics.tightSpacing) {
                            Text(kind.displayName)
                            if kind == .amplifier {
                                Text("Always enabled")
                                    .font(engine.theme.typography.caption)
                                    .foregroundStyle(engine.theme.colors.labelSecondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(kind == .amplifier)
                }

                Button("Restore Default Components") {
                    engine.resetPanelVisibility()
                }
            }
            .font(engine.theme.typography.label)
            .foregroundStyle(engine.theme.colors.labelPrimary)
            .tint(engine.theme.colors.controlActive)
        }
        .padding(engine.theme.metrics.panelPadding)
        .frame(width: engine.theme.metrics.appNameWidth * 4)
        .fixedSize(horizontal: false, vertical: true)
        .background(engine.theme.colors.windowBackground)
        .theme(engine.theme)
    }

    private func visibilityBinding(for kind: RackPanelKind) -> Binding<Bool> {
        Binding(
            get: { engine.enabledPanels.contains(kind) },
            set: { engine.setPanelEnabled(kind, isEnabled: $0) }
        )
    }
}
