import Library
import Persistence
import SwiftUI

// MARK: - RuleBuilderView

/// Sheet that lets the user view and edit the smart playlist rules.
/// Supports nested groups, limit/sort, and preset picker.
public struct RuleBuilderView: View {
    let smartPlaylist: SmartPlaylist
    let service: SmartPlaylistService
    let playlistService: PlaylistService?
    let onSaved: (SmartPlaylist) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var root: EditableCriterion
    @State private var limitSort: LimitSort
    @State private var isSaving = false
    @State private var validationError: String?
    @State private var nodeValidationErrors: [UUID: String] = [:]
    @State private var saveError: String?
    @State private var showPresets = false

    public init(
        smartPlaylist: SmartPlaylist,
        service: SmartPlaylistService,
        playlistService: PlaylistService? = nil,
        onSaved: @escaping (SmartPlaylist) -> Void
    ) {
        self.smartPlaylist = smartPlaylist
        self.service = service
        self.playlistService = playlistService
        self.onSaved = onSaved
        self._root = State(wrappedValue: EditableCriterion(from: smartPlaylist.criteria))
        self._limitSort = State(wrappedValue: smartPlaylist.limitSort)
    }

    public var body: some View {
        VStack(spacing: 0) {
            self.toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CriterionEditorView(
                        criterion: self.$root,
                        depth: 0,
                        validationMessages: self.nodeValidationErrors
                    )
                    Divider().padding(.horizontal, 4)
                    LimitAndSortView(limitSort: self.$limitSort)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 420)
        .accessibilityIdentifier(A11y.RuleBuilder.view)
        .environment(\.playlistServiceForRules, self.playlistService)
        .alert("Save Error", isPresented: Binding(
            get: { self.saveError != nil },
            set: { if !$0 { self.saveError = nil } }
        )) {
            Button("OK") { self.saveError = nil }
                .help("Dismiss this message")
        } message: {
            Text(self.saveError ?? "")
        }
        .sheet(isPresented: self.$showPresets) {
            SmartPresetPickerView(service: self.service) { preset in
                self.root = EditableCriterion(from: preset.criteria)
                self.limitSort = preset.limitSort
                self.refreshValidation()
                self.showPresets = false
            }
        }
        .onChange(of: self.root) { _, _ in
            self.refreshValidation()
        }
        .onAppear {
            Task { @MainActor in SmartPlaylistSurfacePrewarmer.prewarmOnce() }
            self.refreshValidation()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Button {
                self.showPresets = true
            } label: {
                Label("Presets…", systemImage: "star")
            }
            .buttonStyle(.borderless)
            .help("Load criteria from a built-in smart playlist preset")

            Spacer()

            Text("Edit Smart Playlist Rules")
                .font(Typography.title)
                .foregroundStyle(Color.textPrimary)

            Spacer()

            Button("Cancel") {
                self.dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .help("Close this editor without saving changes")

            Button {
                Task { await self.save() }
            } label: {
                if self.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Save")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(Self.isSaveDisabled(isSaving: self.isSaving, validationError: self.validationError))
            .keyboardShortcut(.defaultAction)
            .help(self.saveHelpText)
            .accessibilityIdentifier(A11y.RuleBuilder.saveButton)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Save

    private func save() async {
        self.refreshValidation()
        guard self.validationError == nil else { return }
        self.isSaving = true
        do {
            let compiled = try self.root.toSmartCriterion()
            try await self.service.update(
                id: self.smartPlaylist.id,
                name: self.smartPlaylist.name,
                criteria: compiled,
                limitSort: self.limitSort
            )
            let updated = try await self.service.resolve(id: self.smartPlaylist.id)
            self.onSaved(updated)
            self.dismiss()
        } catch {
            self.saveError = error.localizedDescription
        }
        self.isSaving = false
    }

    private var saveHelpText: String {
        if let validationError {
            return "Fix validation errors before saving: \(validationError)"
        }
        return "Save these rules and update the smart playlist"
    }

    private func refreshValidation() {
        let result = Self.validationResult(for: self.root)
        self.validationError = result.error
        self.nodeValidationErrors = result.nodeErrors
    }

    static func isSaveDisabled(isSaving: Bool, validationError: String?) -> Bool {
        isSaving || validationError != nil
    }

    static func validationResult(for root: EditableCriterion) -> ValidationResult {
        var result = MutableValidationAccumulator()
        Self.validateNode(root, parentGroupID: nil, result: &result)

        do {
            let criterion = try root.toSmartCriterion()
            try Validator.validate(criterion)
        } catch let error as SmartPlaylistError {
            result.setFallback(Self.message(for: error))
        } catch {
            result.setFallback(error.localizedDescription)
        }

        return ValidationResult(error: result.firstError, nodeErrors: result.nodeErrors)
    }

    private static func validateNode(
        _ node: EditableCriterion,
        parentGroupID: UUID?,
        result: inout MutableValidationAccumulator
    ) {
        switch node {
        case let .rule(id, rule):
            if rule.comparator == .matchesRegex,
               case let .text(pattern) = rule.value,
               !Self.isValidRegex(pattern) {
                result.add(nodeID: id, message: "Invalid regex pattern: \(pattern)")
            }
            if rule.comparator == .between,
               case let .range(low, high) = rule.value,
               Self.isReversedRange(low, high) {
                result.add(
                    nodeID: parentGroupID ?? id,
                    message: "Between range is reversed (from must be <= to)"
                )
            }

        case let .group(id, _, children):
            if children.isEmpty {
                result.add(nodeID: id, message: "Group must contain at least one rule")
            }
            for child in children {
                Self.validateNode(child, parentGroupID: id, result: &result)
            }

        case let .invalid(id, reason):
            result.add(nodeID: id, message: "Invalid rule: \(reason)")
        }
    }

    private static func isValidRegex(_ pattern: String) -> Bool {
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return true
        } catch {
            return false
        }
    }

    private static func isReversedRange(_ low: Value, _ high: Value) -> Bool {
        switch (low, high) {
        case let (.int(left), .int(right)):
            left > right

        case let (.double(left), .double(right)):
            left > right

        case let (.duration(left), .duration(right)):
            left > right

        case let (.date(left), .date(right)):
            left > right

        default:
            false
        }
    }

    private static func message(for error: SmartPlaylistError) -> String {
        switch error {
        case .emptyGroup:
            "Group must contain at least one rule"

        case .betweenRangeReversed:
            "Between range is reversed (from must be <= to)"

        case let .invalidRegex(pattern):
            "Invalid regex pattern: \(pattern)"

        case let .invalidRule(reason):
            "Invalid rule: \(reason)"

        default:
            error.localizedDescription
        }
    }
}

struct ValidationResult {
    let error: String?
    let nodeErrors: [UUID: String]
}

private struct MutableValidationAccumulator {
    var firstError: String?
    var nodeErrors: [UUID: String] = [:]

    mutating func add(nodeID: UUID, message: String) {
        if self.nodeErrors[nodeID] == nil {
            self.nodeErrors[nodeID] = message
        }
        self.setFallback(message)
    }

    mutating func setFallback(_ message: String) {
        if self.firstError == nil {
            self.firstError = message
        }
    }
}
