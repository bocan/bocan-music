import SwiftUI

// MARK: - SearchField

/// Toolbar search field that drives `SearchViewModel`.
///
/// - Focuses when `⌘F` is pressed.
/// - Clears on `Escape`.
/// - Debounce is handled by the Combine subscription in `LibraryViewModel`.
public struct SearchField: View {
    @ObservedObject public var vm: SearchViewModel
    @FocusState private var isFocused: Bool

    public init(vm: SearchViewModel) {
        self.vm = vm
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.textSecondary)
                .font(Typography.subheadline)
                .accessibilityHidden(true)

            TextField("Search", text: self.$vm.query)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .focused(self.$isFocused)
                .onSubmit {}
                .accessibilityIdentifier(A11y.Search.field)
                .accessibilityLabel("Search library")

            if !self.vm.query.isEmpty {
                Button {
                    self.vm.clear()
                    self.isFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.bgSecondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .keyboardShortcut(KeyBindings.focusSearch)
        .onKeyPress(.escape) {
            if self.isFocused {
                self.vm.clear()
                self.isFocused = false
                return .handled
            }
            return .ignored
        }
    }
}
