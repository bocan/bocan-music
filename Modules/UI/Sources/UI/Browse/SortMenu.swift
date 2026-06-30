import SwiftUI

// MARK: - SortMenuOption

/// A sort-order choice that can populate a ``SortMenu``: a finite set of cases,
/// each with a localized label.
public protocol SortMenuOption: CaseIterable, Hashable {
    /// Localized label shown for this option in the menu.
    var displayName: String { get }
}

// MARK: - SortMenu

/// A toolbar dropdown that chooses a browse list's sort order, styled like the
/// Albums grid sort chooser (#349). Bind it to whatever owns the preference (a
/// view model or `@AppStorage`).
struct SortMenu<Order: SortMenuOption>: View where Order.AllCases: RandomAccessCollection {
    @Binding var selection: Order
    let help: String

    var body: some View {
        Menu {
            Picker(L10n.string("Sort By"), selection: self.$selection) {
                ForEach(Order.allCases, id: \.self) { order in
                    Text(order.displayName).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(L10n.string("Sort"), systemImage: "arrow.up.arrow.down")
        }
        .help(self.help)
    }
}
