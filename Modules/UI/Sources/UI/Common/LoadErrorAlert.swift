import SwiftUI

// MARK: - LoadErrorAlert

extension View {
    /// A one-button ("OK") error alert bound to a view model's optional
    /// `errorMessage`. The alert is shown whenever `message` is non-nil and
    /// clears it on dismissal.
    ///
    /// Folds the identical load-error alert every Subsonic browse view (and
    /// other load-and-show surfaces) otherwise spells out inline:
    ///
    /// ```swift
    /// .loadErrorAlert(L10n.string("Couldn't load genres"), message: self.$vm.errorMessage)
    /// ```
    func loadErrorAlert(_ title: String, message: Binding<String?>) -> some View {
        self.alert(
            title,
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            ),
            actions: { Button(L10n.string("OK"), role: .cancel) {} },
            message: { Text(message.wrappedValue ?? "") }
        )
    }
}
