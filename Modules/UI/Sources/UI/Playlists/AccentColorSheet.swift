import Library
import SwiftUI

// MARK: - AccentColorSheet

/// Sheet for picking or clearing a playlist's accent colour.
struct AccentColorSheet: View {
    let node: PlaylistNode
    let onSave: (String?) async -> Void

    @State private var color: Color
    @Environment(\.dismiss) private var dismiss

    init(node: PlaylistNode, onSave: @escaping (String?) async -> Void) {
        self.node = node
        self.onSave = onSave
        let initial = node.accentHex.flatMap { Color(hex: $0) } ?? Color.accentColor
        self._color = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Accent Colour — \(self.node.name)")
                .font(Typography.title)
                .lineLimit(1)

            HStack(spacing: 16) {
                ColorPicker(selection: self.$color, supportsOpacity: false) {
                    Text("Colour")
                }

                RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall)
                    .fill(self.color)
                    .frame(width: 44, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )
            }

            HStack {
                Button("Remove Colour") {
                    Task {
                        await self.onSave(nil)
                        self.dismiss()
                    }
                }
                .buttonStyle(.bordered)
                .help("Remove the custom accent colour from this playlist")

                Spacer()

                Button("Cancel") {
                    self.dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    Task {
                        let hex = self.color.toHex()
                        await self.onSave(hex)
                        self.dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 320)
        .accessibilityLabel("Set accent colour for \(self.node.name)")
    }
}
