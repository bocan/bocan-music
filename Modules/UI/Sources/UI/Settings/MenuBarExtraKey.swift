import SwiftUI

/// `EnvironmentValues` extension for menu-bar extra visibility.
public extension EnvironmentValues {
    /// A `Binding<Bool>` injected by `BocanApp` that controls whether the
    /// menu-bar extra is shown.  Read and written by `GeneralSettingsView`.
    @Entry var menuBarExtraEnabled: Binding<Bool> = .constant(false)
}
