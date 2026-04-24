import Library
import SwiftUI

// MARK: - TagFieldRow

/// A single label + text-input row in the tag editor form.
///
/// When the backing field state is `.various` the placeholder shows `<various>`
/// until the user starts typing (which implicitly marks the field as `.edited`).
public struct TagFieldRow: View {
    public let label: LocalizedStringKey
    @Binding public var text: String
    public let isVarious: Bool
    public var axis: Axis = .horizontal

    public init(
        _ label: LocalizedStringKey,
        text: Binding<String>,
        isVarious: Bool = false,
        axis: Axis = .horizontal
    ) {
        self.label = label
        self._text = text
        self.isVarious = isVarious
        self.axis = axis
    }

    public var body: some View {
        LabeledContent(self.label) {
            TextField(
                self.isVarious
                    ? String(localized: "<various>", comment: "Placeholder for mixed multi-edit values")
                    : "",
                text: self.$text,
                axis: self.axis
            )
            .foregroundStyle(self.isVarious && self.text.isEmpty ? Color.textTertiary : Color.primary)
        }
    }
}

// MARK: - IntFieldRow

/// A label + integer text field that converts between `String` and `Int?`.
public struct IntFieldRow: View {
    public let label: LocalizedStringKey
    @Binding public var value: Int?
    public let isVarious: Bool

    @State private var text = ""

    public init(_ label: LocalizedStringKey, value: Binding<Int?>, isVarious: Bool = false) {
        self.label = label
        self._value = value
        self.isVarious = isVarious
    }

    public var body: some View {
        LabeledContent(self.label) {
            TextField(
                self.isVarious ? "<various>" : "",
                text: Binding(
                    get: { self.value.map { String($0) } ?? "" },
                    set: { self.value = Int($0) }
                )
            )
            .foregroundStyle(self.isVarious && self.value == nil ? Color.textTertiary : Color.primary)
        }
    }
}

// MARK: - StarRatingRow

/// A 0–5 star rating control (backed by 0–100 integer).
public struct StarRatingRow: View {
    public let label: LocalizedStringKey
    @Binding public var rating: Int?

    public init(_ label: LocalizedStringKey, rating: Binding<Int?>) {
        self.label = label
        self._rating = rating
    }

    public var body: some View {
        LabeledContent(self.label) {
            HStack(spacing: 2) {
                ForEach(1 ..< 6) { star in
                    Image(systemName: self.starImage(for: star))
                        .foregroundStyle(Color.accentColor)
                        .onTapGesture { self.tap(star: star) }
                        .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
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
