// swiftlint:disable file_length
import Library
import SwiftUI

// MARK: - RuleRowView

/// A single rule row: [field picker] [comparator menu] [value control] [−]
struct RuleRowView: View {
    @Binding var rule: EditableRule
    let validationMessage: String?
    let onRemove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                FieldPicker(field: self.$rule.field)
                    .onChange(of: self.rule.field) { _, newField in
                        self.adaptComparatorAndValue(for: newField)
                    }
                    .frame(minWidth: 140)
                    .help("Choose which track field this rule evaluates")

                ComparatorMenu(
                    field: self.rule.field,
                    comparator: self.$rule.comparator
                )
                .onChange(of: self.rule.comparator) { _, newComp in
                    self.adaptValueForComparator(newComp)
                }
                .frame(minWidth: 120)
                .help("Choose how the selected field is compared")

                ValueControl(rule: self.$rule)
                    .frame(maxWidth: .infinity)
                    .help("Set the comparison value for this rule")

                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(Color.red.opacity(0.8))
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this rule")
                    .accessibilityLabel("Remove rule")
                }
            }
            .padding(.vertical, 2)

            if let validationMessage {
                Text(validationMessage)
                    .font(Typography.caption)
                    .foregroundStyle(Color.red)
                    .accessibilityLabel("Validation error: \(validationMessage)")
            }
        }
    }

    // MARK: - Adapt helpers

    private func adaptComparatorAndValue(for field: Field) {
        let def = FieldDefinitions.definition(for: field)
        let allowed = def.allowedComparators
        if !allowed.contains(self.rule.comparator) {
            self.rule.comparator = allowed.first ?? .contains
        }
        self.adaptValueForComparator(self.rule.comparator)
    }

    private func adaptValueForComparator(_ comp: Library.Comparator) {
        switch comp {
        case .isEmpty, .isNotEmpty, .isNull, .isNotNull, .isTrue, .isFalse:
            self.rule.value = .null

        case .between:
            if case .range = self.rule.value { return }
            self.rule.value = .range(.int(0), .int(100))

        case .inLastDays:
            self.rule.value = .int(30)

        case .inLastMonths:
            self.rule.value = .int(12)

        case .inLastYears:
            self.rule.value = .int(1)

        case .memberOf, .notMemberOf:
            if case .playlistRef = self.rule.value { return }
            self.rule.value = .playlistRef(0)

        case .pathUnder:
            if case .text = self.rule.value { return }
            self.rule.value = .text("")

        default:
            let def = FieldDefinitions.definition(for: self.rule.field)
            switch def.dataType {
            case .text:
                if case .text = self.rule.value { return }
                self.rule.value = .text("")

            case .numeric:
                if case .int = self.rule.value { return }
                self.rule.value = .int(0)

            case .date:
                if case .date = self.rule.value { return }
                self.rule.value = .date(Date())

            case .bool:
                self.rule.value = .null

            case .duration:
                if case .duration = self.rule.value { return }
                self.rule.value = .duration(0)

            case let .enumeration(options):
                if case .enumeration = self.rule.value { return }
                self.rule.value = .enumeration(options.first ?? "")

            case .membership:
                if case .playlistRef = self.rule.value { return }
                self.rule.value = .playlistRef(0)
            }
        }
    }
}

// MARK: - InvalidRuleRow

/// Placeholder row shown when a `SmartCriterion.invalid` sentinel is decoded —
/// typically a rule referencing a field that this build no longer recognises.
/// The user must remove the row before the playlist can be saved.
struct InvalidRuleRow: View {
    let reason: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Invalid rule — please remove")
                    .font(Typography.body)
                    .foregroundStyle(Color.textPrimary)
                Text(self.reason)
                    .font(Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Invalid rule, \(self.reason). Please remove.")
    }
}

// MARK: - FieldPicker

private struct FieldPicker: View {
    @Binding var field: Field

    var body: some View {
        Menu {
            ForEach(FieldGroup.allCases, id: \.self) { group in
                Section(group.displayName) {
                    ForEach(group.fields, id: \.self) { f in
                        Button(f.displayName) { self.field = f }
                    }
                }
            }
        } label: {
            HStack {
                Text(self.field.displayName)
                    .font(Typography.body)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .help("Open field options")
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .help("Field selector")
    }
}

// MARK: - ComparatorMenu

private struct ComparatorMenu: View {
    let field: Field
    @Binding var comparator: Library.Comparator

    var body: some View {
        let allowed = Array(FieldDefinitions.definition(for: self.field).allowedComparators)
            .sorted { $0.displayName < $1.displayName }
        Menu {
            ForEach(allowed, id: \.self) { comp in
                Button(comp.displayName) { self.comparator = comp }
            }
        } label: {
            HStack {
                Text(self.comparator.displayName)
                    .font(Typography.body)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .help("Open comparator options")
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .help("Comparator selector")
    }
}

// MARK: - ValueControl

/// Morphs based on the field data type and comparator.
private struct ValueControl: View {
    @Binding var rule: EditableRule

    var body: some View {
        self.content
    }

    @ViewBuilder
    private var content: some View {
        // No-value comparators
        switch self.rule.comparator {
        case .isEmpty, .isNotEmpty, .isNull, .isNotNull, .isTrue, .isFalse:
            Color.clear.frame(height: 24)

        default:
            self.typedControl
        }
    }

    @ViewBuilder
    private var typedControl: some View {
        // inLastDays / inLastMonths / inLastYears use an integer count, even for date fields.
        let isLastN = self.rule.comparator == .inLastDays
            || self.rule.comparator == .inLastMonths
            || self.rule.comparator == .inLastYears
        if isLastN {
            self.intControl
        } else {
            self.typedControlByDataType
        }
    }

    @ViewBuilder
    private var typedControlByDataType: some View {
        let def = FieldDefinitions.definition(for: self.rule.field)
        switch def.dataType {
        case .text:
            self.textControl

        case .numeric:
            self.intControl

        case .date:
            self.dateControl

        case .bool:
            Color.clear.frame(height: 24)

        case .duration:
            self.durationControl

        case .enumeration:
            self.enumerationControl

        case .membership:
            self.membershipControl
        }
    }

    // MARK: - Text

    @ViewBuilder private var textControl: some View {
        if case .between = self.rule.comparator {
            // between: low/high text
            HStack {
                TextField("from", text: Binding(
                    get: {
                        if case let .range(.text(lo), _) = self.rule.value { return lo }
                        return ""
                    },
                    set: { lo in
                        if case let .range(_, hi) = self.rule.value {
                            self.rule.value = .range(.text(lo), hi)
                        } else {
                            self.rule.value = .range(.text(lo), .text(""))
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                Text("to")
                    .foregroundStyle(Color.textSecondary)
                TextField("to", text: Binding(
                    get: {
                        if case let .range(_, .text(hi)) = self.rule.value { return hi }
                        return ""
                    },
                    set: { hi in
                        if case let .range(lo, _) = self.rule.value {
                            self.rule.value = .range(lo, .text(hi))
                        } else {
                            self.rule.value = .range(.text(""), .text(hi))
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }
        } else {
            TextField("value", text: Binding(
                get: {
                    if case let .text(t) = self.rule.value { return t }
                    return ""
                },
                set: { self.rule.value = .text($0) }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Integer

    @ViewBuilder private var intControl: some View {
        switch self.rule.comparator {
        case .inLastDays, .inLastMonths, .inLastYears:
            Stepper(
                value: Binding(
                    get: { if case let .int(n) = self.rule.value { return Int(n) }
                        return 30
                    },
                    set: { self.rule.value = .int(Int64($0)) }
                ),
                in: 1 ... 3650
            ) {
                if case let .int(n) = self.rule.value {
                    Text("\(n)")
                        .frame(minWidth: 36, alignment: .trailing)
                } else {
                    Text("30")
                }
            }

        case .between:
            HStack {
                IntField(label: "from", value: Binding(
                    get: { if case let .range(.int(lo), _) = self.rule.value { return lo }
                        return 0
                    },
                    set: { lo in
                        if case let .range(_, hi) = self.rule.value {
                            self.rule.value = .range(.int(lo), hi)
                        } else {
                            self.rule.value = .range(.int(lo), .int(100))
                        }
                    }
                ))
                Text("to").foregroundStyle(Color.textSecondary)
                IntField(label: "to", value: Binding(
                    get: { if case let .range(_, .int(hi)) = self.rule.value { return hi }
                        return 100
                    },
                    set: { hi in
                        if case let .range(lo, _) = self.rule.value {
                            self.rule.value = .range(lo, .int(hi))
                        } else {
                            self.rule.value = .range(.int(0), .int(hi))
                        }
                    }
                ))
            }

        default:
            IntField(label: "value", value: Binding(
                get: { if case let .int(n) = self.rule.value { return n }
                    return 0
                },
                set: { self.rule.value = .int($0) }
            ))
        }
    }

    // MARK: - Date

    private var dateControl: some View {
        DatePicker(
            "",
            selection: Binding(
                get: { if case let .date(date) = self.rule.value { return date }
                    return Date()
                },
                set: { self.rule.value = .date($0) }
            ),
            displayedComponents: .date
        )
        .labelsHidden()
    }

    // MARK: - Duration

    private var durationControl: some View {
        DurationField(value: Binding(
            get: { if case let .duration(dur) = self.rule.value { return dur }
                return 0
            },
            set: { self.rule.value = .duration($0) }
        ))
    }

    // MARK: - Enumeration

    private var enumerationControl: some View {
        let def = FieldDefinitions.definition(for: self.rule.field)
        guard case let .enumeration(options) = def.dataType, !options.isEmpty else {
            return AnyView(EmptyView())
        }
        let current: String = {
            if case let .enumeration(v) = self.rule.value { return v }
            return options[0]
        }()
        return AnyView(
            Menu(current) {
                ForEach(options, id: \.self) { option in
                    Button(option) {
                        self.rule.value = .enumeration(option)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(Text("File format"))
        )
    }

    // MARK: - Membership

    private var membershipControl: some View {
        PlaylistPicker(selectedID: Binding(
            get: {
                if case let .playlistRef(id) = self.rule.value { return id }
                return 0
            },
            set: { self.rule.value = .playlistRef($0) }
        ))
    }
}

// MARK: - IntField

private struct IntField: View {
    let label: String
    @Binding var value: Int64

    var body: some View {
        TextField(self.label, value: self.$value, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 64)
    }
}

// MARK: - DurationField (MM:SS)

/// Shows a simple MM:SS text field for TimeInterval values.
private struct DurationField: View {
    @Binding var value: TimeInterval
    @State private var text = ""
    @State private var isEditing = false

    var body: some View {
        TextField("M:SS", text: self.$text) { editing in
            self.isEditing = editing
            if !editing {
                self.commit()
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 72)
        .onAppear {
            self.text = self.format(self.value)
        }
        .onChange(of: self.value) { _, newVal in
            if !self.isEditing {
                self.text = self.format(newVal)
            }
        }
    }

    private func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func commit() {
        let parts = self.text.split(separator: ":", maxSplits: 1)
        if parts.count == 2,
           let mins = Int(parts[0]),
           let secs = Int(parts[1]) {
            self.value = TimeInterval(mins * 60 + secs)
        }
    }
}

// MARK: - Field display names

extension Field {
    var displayName: String {
        switch self {
        case .title:
            "Title"

        case .artist:
            "Artist"

        case .albumArtist:
            "Album Artist"

        case .album:
            "Album"

        case .genre:
            "Genre"

        case .composer:
            "Composer"

        case .comment:
            "Comment"

        case .year:
            "Year"

        case .trackNumber:
            "Track #"

        case .discNumber:
            "Disc #"

        case .playCount:
            "Play Count"

        case .skipCount:
            "Skip Count"

        case .rating:
            "Rating"

        case .bpm:
            "BPM"

        case .bitrate:
            "Bitrate"

        case .sampleRate:
            "Sample Rate"

        case .bitDepth:
            "Bit Depth"

        case .duration:
            "Duration"

        case .addedAt:
            "Date Added"

        case .lastPlayedAt:
            "Last Played"

        case .loved:
            "Loved"

        case .excludedFromShuffle:
            "Skip in Shuffle"

        case .isLossless:
            "Lossless"

        case .hasCoverArt:
            "Has Cover Art"

        case .hasLyrics:
            "Has Lyrics"

        case .hasMusicBrainzReleaseID:
            "Has MusicBrainz ID"

        case .fileFormat:
            "File Format"

        case .inPlaylist:
            "In Playlist"

        case .notInPlaylist:
            "Not in Playlist"

        case .pathUnder:
            "File Path"
        }
    }
}

// MARK: - Comparator display names

extension Library.Comparator {
    var displayName: String {
        switch self {
        case .is:
            "is"

        case .isNot:
            "is not"

        case .contains:
            "contains"

        case .doesNotContain:
            "doesn't contain"

        case .startsWith:
            "starts with"

        case .endsWith:
            "ends with"

        case .matchesRegex:
            "matches regex"

        case .isEmpty:
            "is empty"

        case .isNotEmpty:
            "is not empty"

        case .equalTo:
            "="

        case .notEqualTo:
            "≠"

        case .lessThan:
            "<"

        case .greaterThan:
            ">"

        case .lessThanOrEqual:
            "≤"

        case .greaterThanOrEqual:
            "≥"

        case .between:
            "is between"

        case .isNull:
            "is not set"

        case .isNotNull:
            "is set"

        case .inLastDays:
            "in last (days)"

        case .inLastMonths:
            "in last (months)"

        case .inLastYears:
            "in last (years)"

        case .beforeDate:
            "before"

        case .afterDate:
            "after"

        case .onDate:
            "on"

        case .isTrue:
            "is true"

        case .isFalse:
            "is false"

        case .memberOf:
            "is in playlist"

        case .notMemberOf:
            "is not in playlist"

        case .pathUnder:
            "is under path"
        }
    }
}

// MARK: - Field groups for the picker

enum FieldGroup: CaseIterable {
    case text, numbers, dates, flags, membership

    var displayName: String {
        switch self {
        case .text:
            "Text"

        case .numbers:
            "Numbers"

        case .dates:
            "Dates"

        case .flags:
            "Flags"

        case .membership:
            "Membership"
        }
    }

    var fields: [Field] {
        switch self {
        case .text:
            [.title, .artist, .albumArtist, .album, .genre, .composer, .comment, .fileFormat, .pathUnder]

        case .numbers:
            [.year, .trackNumber, .discNumber, .playCount, .skipCount, .rating, .bpm, .bitrate, .sampleRate, .bitDepth, .duration]

        case .dates:
            [.addedAt, .lastPlayedAt]

        case .flags:
            [.loved, .excludedFromShuffle, .isLossless, .hasCoverArt, .hasLyrics, .hasMusicBrainzReleaseID]

        case .membership:
            [.inPlaylist, .notInPlaylist]
        }
    }
}
