import Library
import SwiftUI

// MARK: - TagFieldRow

/// A single label + text-input row in the tag editor form.
///
/// When the backing field state is `.various` the placeholder shows `<various>`
/// until the user starts typing (which implicitly marks the field as `.edited`).
/// In multi-track mode pass `enabledBinding` to show a leading checkbox;
/// unchecking it prevents the field from being applied on Save.
public struct TagFieldRow: View {
    public let label: LocalizedStringKey
    @Binding public var text: String
    public let isVarious: Bool
    public var axis: Axis = .horizontal
    public var enabledBinding: Binding<Bool>?

    public init(
        _ label: LocalizedStringKey,
        text: Binding<String>,
        isVarious: Bool = false,
        axis: Axis = .horizontal,
        enabledBinding: Binding<Bool>? = nil
    ) {
        self.label = label
        self._text = text
        self.isVarious = isVarious
        self.axis = axis
        self.enabledBinding = enabledBinding
    }

    public var body: some View {
        LabeledContent {
            TextField(
                self.isVarious
                    ? String(localized: "<various>", comment: "Placeholder for mixed multi-edit values")
                    : "",
                text: self.$text,
                axis: self.axis
            )
            .foregroundStyle(self.isVarious && self.text.isEmpty ? Color.textTertiary : Color.primary)
            .disabled(self.enabledBinding.map { !$0.wrappedValue } ?? false)
        } label: {
            HStack(spacing: 4) {
                if let eb = self.enabledBinding {
                    Toggle("", isOn: eb)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .help("Include this field when saving")
                        .fixedSize()
                }
                Text(self.label)
            }
        }
    }
}

// MARK: - IntFieldRow

/// A label + integer text field that converts between `String` and `Int?`.
/// In multi-track mode pass `enabledBinding` to show a leading checkbox.
public struct IntFieldRow: View {
    public let label: LocalizedStringKey
    @Binding public var value: Int?
    public let isVarious: Bool
    public var enabledBinding: Binding<Bool>?

    @State private var text = ""

    public init(
        _ label: LocalizedStringKey,
        value: Binding<Int?>,
        isVarious: Bool = false,
        enabledBinding: Binding<Bool>? = nil
    ) {
        self.label = label
        self._value = value
        self.isVarious = isVarious
        self.enabledBinding = enabledBinding
    }

    public var body: some View {
        LabeledContent {
            TextField(
                self.isVarious ? "<various>" : "",
                text: Binding(
                    get: { self.value.map { String($0) } ?? "" },
                    set: { self.value = Int($0) }
                )
            )
            .foregroundStyle(self.isVarious && self.value == nil ? Color.textTertiary : Color.primary)
            .disabled(self.enabledBinding.map { !$0.wrappedValue } ?? false)
        } label: {
            HStack(spacing: 4) {
                if let eb = self.enabledBinding {
                    Toggle("", isOn: eb)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .help("Include this field when saving")
                        .fixedSize()
                }
                Text(self.label)
            }
        }
    }
}

// MARK: - StarRatingRow

/// A 0–5 star rating control (backed by 0–100 integer).
/// In multi-track mode pass `enabledBinding` to show a leading checkbox.
public struct StarRatingRow: View {
    public let label: LocalizedStringKey
    @Binding public var rating: Int?
    public var enabledBinding: Binding<Bool>?

    public init(
        _ label: LocalizedStringKey,
        rating: Binding<Int?>,
        enabledBinding: Binding<Bool>? = nil
    ) {
        self.label = label
        self._rating = rating
        self.enabledBinding = enabledBinding
    }

    public var body: some View {
        LabeledContent {
            HStack(spacing: 2) {
                ForEach(1 ..< 6) { star in
                    Button {
                        self.tap(star: star)
                    } label: {
                        Image(systemName: self.starImage(for: star))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(star) \(star == 1 ? "star" : "stars")")
                }
                if self.rating != nil {
                    Button(
                        action: { self.rating = nil },
                        label: { Image(systemName: "xmark.circle").foregroundStyle(Color.textTertiary) }
                    )
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear rating")
                }
            }
            .disabled(self.enabledBinding.map { !$0.wrappedValue } ?? false)
        } label: {
            HStack(spacing: 4) {
                if let eb = self.enabledBinding {
                    Toggle("", isOn: eb)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .help("Include this field when saving")
                        .fixedSize()
                }
                Text(self.label)
            }
        }
    }

    private func starImage(for star: Int) -> String {
        let threshold = star * 20
        guard let r = self.rating else { return "star" }
        if r >= threshold { return "star.fill" }
        if r >= threshold - 10 { return "star.leadinghalf.filled" }
        return "star"
    }

    private func tap(star: Int) {
        let newRating = star * 20
        if self.rating == newRating {
            self.rating = nil
        } else {
            self.rating = newRating
        }
    }
}

// MARK: - ToggleFieldRow

/// A boolean toggle field row for the tag editor form.
///
/// In multi-track mode pass `enabledBinding` to show a leading checkbox;\n/// unchecking it prevents the field from being applied on Save.
public struct ToggleFieldRow: View {
    public let label: LocalizedStringKey
    @Binding public var value: Bool
    public var enabledBinding: Binding<Bool>?

    public init(
        _ label: LocalizedStringKey,
        value: Binding<Bool>,
        enabledBinding: Binding<Bool>? = nil
    ) {
        self.label = label
        self._value = value
        self.enabledBinding = enabledBinding
    }

    public var body: some View {
        LabeledContent {
            Toggle("", isOn: self.$value)
                .labelsHidden()
                .disabled(self.enabledBinding.map { !$0.wrappedValue } ?? false)
        } label: {
            HStack(spacing: 4) {
                if let eb = self.enabledBinding {
                    Toggle("", isOn: eb)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .help("Include this field when saving")
                        .fixedSize()
                }
                Text(self.label)
            }
        }
    }
}
