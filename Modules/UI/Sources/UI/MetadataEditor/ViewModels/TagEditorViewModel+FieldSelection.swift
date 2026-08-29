import Foundation

// MARK: - Multi-edit field selection

/// Multi-edit field selection helpers.
public extension TagEditorViewModel {
    /// Marks every field as enabled so all edits will be applied on Save.
    func enableAllFields() {
        self.enabledFields = Set(FieldKey.allCases)
    }

    /// Clears all field-enable flags so no edits will be applied on Save.
    func disableAllFields() {
        self.enabledFields = []
    }
}
