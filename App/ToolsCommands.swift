import SwiftUI
import UI

// MARK: - ToolsCommands

/// The Tools menu. Lives apart from `BocanCommands` (which sits at the
/// file-length limit) and needs no graph access: the windows it opens gate
/// their own content on the graph. Menu copy resolves against the app
/// target's String Catalog (`App/Localizable.xcstrings`).
struct ToolsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Tools") {
            Button("Library Summary…") {
                self.openWindow(id: "library-summary")
            }
            .keyboardShortcut(KeyBindings.librarySummary)
        }
    }
}
