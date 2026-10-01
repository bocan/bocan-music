import SwiftUI

// MARK: - SidebarHeaderAccessibility

/// Makes a sidebar section header one deliberate accessibility element.
///
/// A `List` in the sidebar style turns each section header into a single
/// element and merges every control in it. The Playlists "+" answered to
/// VoiceOver as "Collapse Playlists", and the collapse button did not exist
/// for it at all (#596). This names the element after the section, says
/// whether it is expanded, and makes collapsing its default and a named
/// action. Each header adds its "+" as a further named action, so VoiceOver
/// reaches every control. The look and the mouse behaviour are unchanged.
struct SidebarHeaderAccessibility: ViewModifier {
    let title: String
    let isExpanded: Bool
    let toggle: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(self.title)
            .accessibilityValue(self.isExpanded ? L10n.string("Expanded") : L10n.string("Collapsed"))
            .accessibilityAddTraits(.isHeader)
            .accessibilityAction { self.toggle() }
            .accessibilityAction(
                named: self.isExpanded ? L10n.string("Collapse \(self.title)") : L10n.string("Expand \(self.title)")
            ) { self.toggle() }
    }
}

extension View {
    /// See ``SidebarHeaderAccessibility``.
    func sidebarHeaderAccessibility(title: String, isExpanded: Bool, toggle: @escaping () -> Void) -> some View {
        modifier(SidebarHeaderAccessibility(title: title, isExpanded: isExpanded, toggle: toggle))
    }
}
