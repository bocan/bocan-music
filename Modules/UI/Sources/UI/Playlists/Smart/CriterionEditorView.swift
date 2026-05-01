import Library
import Persistence
import SwiftUI

// MARK: - CriterionEditorView

/// Recursively renders an `EditableCriterion` — either a single rule row
/// or a group with a match-all/any header and nested children.
struct CriterionEditorView: View {
    @Binding var criterion: EditableCriterion
    let depth: Int

    var body: some View {
        switch self.criterion {
        case let .rule(id, rule):
            RuleRowView(
                rule: Binding(
                    get: { rule },
                    set: { self.criterion = .rule(id: id, $0) }
                ),
                onRemove: nil // top-level rule: cannot remove (caller handles)
            )

        case let .invalid(_, reason):
            InvalidRuleRow(reason: reason)

        case let .group(id, op, children):
            GroupEditorView(
                id: id,
                op: Binding(
                    get: { op },
                    set: { newOp in
                        if case let .group(_, _, ch) = self.criterion {
                            self.criterion = .group(id: id, op: newOp, children: ch)
                        }
                    }
                ),
                children: Binding(
                    get: { children },
                    set: { newChildren in
                        self.criterion = .group(id: id, op: op, children: newChildren)
                    }
                ),
                depth: self.depth
            )
        }
    }
}

// MARK: - GroupEditorView

struct GroupEditorView: View {
    let id: UUID
    @Binding var op: LogicalOp
    @Binding var children: [EditableCriterion]
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row: Match [all|any] of these rules
            HStack(spacing: 6) {
                Text("Match")
                    .foregroundStyle(Color.textSecondary)
                    .font(Typography.subheadline)
                Picker("", selection: self.$op) {
                    Text("all").tag(LogicalOp.and)
                    Text("any").tag(LogicalOp.or)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Choose whether all rules or any rule must match")
                .accessibilityLabel("Match mode")
                .accessibilityValue(self.op == .and ? "all" : "any")
                Text("of the following rules:")
                    .foregroundStyle(Color.textSecondary)
                    .font(Typography.subheadline)
                Spacer()
                Button {
                    self.children.append(.defaultRule())
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .help("Add a rule to this group")
                .accessibilityIdentifier(A11y.RuleBuilder.addRuleButton)
                .accessibilityLabel("Add rule")
                if self.depth < 2 {
                    Button {
                        self.children.append(.defaultGroup())
                    } label: {
                        Image(systemName: "plus.rectangle.on.rectangle")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .help("Add a nested rule group")
                    .accessibilityLabel("Add group")
                }
            }
            .padding(.bottom, 2)

            // Children
            ForEach(Array(self.children.enumerated()), id: \.element.id) { index, child in
                HStack(alignment: .top, spacing: 0) {
                    // Indentation bracket for depth > 0
                    if self.depth > 0 {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.separatorAdaptive)
                            .frame(width: 2)
                            .padding(.trailing, 8)
                    }
                    CriterionEditorView(
                        criterion: Binding(
                            get: { self.children[safe: index] ?? child },
                            set: { self.children[safe: index] = $0 }
                        ),
                        depth: self.depth + 1
                    )
                    Button {
                        self.children.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(Color.red.opacity(0.8))
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this row")
                    .accessibilityLabel("Remove rule")
                    .opacity(self.children.count > 1 ? 1 : 0.3)
                    .disabled(self.children.count <= 1)
                }
            }
        }
        .padding(self.depth > 0 ? 10 : 0)
        .background(self.depth > 0 ? Color.bgSecondary.opacity(0.5) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: self.depth > 0 ? 8 : 0))
        .overlay(
            self.depth > 0 ? RoundedRectangle(cornerRadius: 8)
                .stroke(Color.separatorAdaptive, lineWidth: 1) : nil
        )
    }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        get { indices.contains(index) ? self[index] : nil }
        set {
            guard indices.contains(index), let value = newValue else { return }
            self[index] = value
        }
    }
}
