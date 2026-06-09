import SwiftUI

// MARK: - Details, Sorting tabs and field helpers

extension TagEditorSheet {
    // MARK: - Details tab

    var detailsTab: some View {
        Form {
            if !self.vm.isSingleTrack {
                self.selectAllNoneSection
                self.bulkActionsSection
            }

            Section(L10n.string("Track Info")) {
                TagFieldRow(
                    L10n.string("Title"),
                    text: self.fieldBinding(\.title),
                    isVarious: self.vm.title == .various,
                    enabledBinding: self.enabledFor(.title)
                )
                .focused(self.$focusedField, equals: .title)
                TagFieldRow(
                    L10n.string("Artist"),
                    text: self.fieldBinding(\.artist),
                    isVarious: self.vm.artist == .various,
                    enabledBinding: self.enabledFor(.artist)
                )
                .focused(self.$focusedField, equals: .artist)
                TagFieldRow(
                    L10n.string("Album Artist"),
                    text: self.fieldBinding(\.albumArtist),
                    isVarious: self.vm.albumArtist == .various,
                    enabledBinding: self.enabledFor(.albumArtist)
                )
                .focused(self.$focusedField, equals: .albumArtist)
                TagFieldRow(
                    L10n.string("Album"),
                    text: self.fieldBinding(\.album),
                    isVarious: self.vm.album == .various,
                    enabledBinding: self.enabledFor(.album)
                )
                .focused(self.$focusedField, equals: .album)
                TagFieldRow(
                    L10n.string("Genre"),
                    text: self.fieldBinding(\.genre),
                    isVarious: self.vm.genre == .various,
                    enabledBinding: self.enabledFor(.genre)
                )
                .focused(self.$focusedField, equals: .genre)
                TagFieldRow(
                    L10n.string("Composer"),
                    text: self.fieldBinding(\.composer),
                    isVarious: self.vm.composer == .various,
                    enabledBinding: self.enabledFor(.composer)
                )
                .focused(self.$focusedField, equals: .composer)
            }

            Section(L10n.string("Numbering")) {
                IntFieldRow(
                    L10n.string("Year"),
                    value: self.intBinding(\.year),
                    isVarious: self.vm.year == .various,
                    enabledBinding: self.enabledFor(.year)
                )
                .focused(self.$focusedField, equals: .year)
                if self.vm.isSingleTrack {
                    IntFieldRow(L10n.string("Track"), value: self.intBinding(\.trackNumber), isVarious: false)
                        .focused(self.$focusedField, equals: .trackNumber)
                    IntFieldRow(L10n.string("Of"), value: self.intBinding(\.trackTotal), isVarious: false)
                        .focused(self.$focusedField, equals: .trackTotal)
                }
                IntFieldRow(
                    L10n.string("Disc"),
                    value: self.intBinding(\.discNumber),
                    isVarious: self.vm.discNumber == .various,
                    enabledBinding: self.enabledFor(.discNumber)
                )
                .focused(self.$focusedField, equals: .discNumber)
                IntFieldRow(
                    L10n.string("Discs"),
                    value: self.intBinding(\.discTotal),
                    isVarious: self.vm.discTotal == .various,
                    enabledBinding: self.enabledFor(.discTotal)
                )
                .focused(self.$focusedField, equals: .discTotal)
            }

            Section(L10n.string("Extended")) {
                IntFieldRow(
                    L10n.string("BPM"),
                    value: Binding(
                        get: {
                            switch self.vm.bpm {
                            case let .shared(val):
                                val.flatMap { Int($0) }

                            case let .edited(val):
                                val.flatMap { Int($0) }

                            case .various:
                                nil
                            }
                        },
                        set: { self.vm.setBPM($0.map { Double($0) }) }
                    ),
                    isVarious: self.vm.bpm == .various,
                    enabledBinding: self.enabledFor(.bpm)
                )
                .focused(self.$focusedField, equals: .bpm)
                TagFieldRow(
                    L10n.string("Key"),
                    text: self.fieldBinding(\.key),
                    isVarious: self.vm.key == .various,
                    enabledBinding: self.enabledFor(.musicalKey)
                )
                .focused(self.$focusedField, equals: .key)
                TagFieldRow(
                    L10n.string("ISRC"),
                    text: self.fieldBinding(\.isrc),
                    isVarious: self.vm.isrc == .various,
                    enabledBinding: self.enabledFor(.isrc)
                )
                .focused(self.$focusedField, equals: .isrc)
                TagFieldRow(
                    L10n.string("Comment"),
                    text: self.fieldBinding(\.comment),
                    isVarious: self.vm.comment == .various,
                    enabledBinding: self.enabledFor(.comment)
                )
                .focused(self.$focusedField, equals: .comment)
            }

            Section(L10n.string("Identifiers")) {
                ReadOnlyIDRow(label: L10n.string("Recording MBID"), value: self.vm.recordingMBIDDisplay)
                ReadOnlyIDRow(label: L10n.string("Album MBID"), value: self.vm.releaseMBIDDisplay)
            }

            Section(L10n.string("Rating")) {
                StarRatingRow(
                    L10n.string("Rating"),
                    rating: Binding(
                        get: { self.vm.rating.currentValue.flatMap(\.self) },
                        set: { self.vm.setRating($0) }
                    ),
                    enabledBinding: self.enabledFor(.rating)
                )
                .focused(self.$focusedField, equals: .rating)
                ToggleFieldRow(
                    L10n.string("Loved"),
                    value: Binding(
                        get: { self.vm.loved.currentValue.flatMap(\.self) ?? false },
                        set: { self.vm.setLoved($0) }
                    ),
                    enabledBinding: self.enabledFor(.loved)
                )
                .focused(self.$focusedField, equals: .loved)
                ToggleFieldRow(
                    L10n.string("Excluded from Shuffle"),
                    value: Binding(
                        get: { self.vm.excludedFromShuffle.currentValue.flatMap(\.self) ?? false },
                        set: { self.vm.setExcludedFromShuffle($0) }
                    ),
                    enabledBinding: self.enabledFor(.excludedFromShuffle)
                )
                .focused(self.$focusedField, equals: .excludedFromShuffle)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Sorting tab

    var sortingTab: some View {
        Form {
            Section(L10n.string("Sort Names")) {
                TagFieldRow(
                    L10n.string("Sort Artist"),
                    text: self.fieldBinding(\.sortArtist),
                    isVarious: self.vm.sortArtist == .various,
                    enabledBinding: self.enabledFor(.sortArtist)
                )
                TagFieldRow(
                    L10n.string("Sort Album Artist"),
                    text: self.fieldBinding(\.sortAlbumArtist),
                    isVarious: self.vm.sortAlbumArtist == .various,
                    enabledBinding: self.enabledFor(.sortAlbumArtist)
                )
                TagFieldRow(
                    L10n.string("Sort Album"),
                    text: self.fieldBinding(\.sortAlbum),
                    isVarious: self.vm.sortAlbum == .various,
                    enabledBinding: self.enabledFor(.sortAlbum)
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Per-field checkbox helpers

    /// Returns a binding that drives the per-field checkbox in multi-track mode.
    ///
    /// Returns `nil` in single-track mode so that row views omit the checkbox entirely.
    func enabledFor(_ key: TagEditorViewModel.FieldKey) -> Binding<Bool>? {
        guard !self.vm.isSingleTrack else { return nil }
        return Binding(
            get: { self.vm.enabledFields.contains(key) },
            set: { on in
                if on {
                    self.vm.enabledFields.insert(key)
                } else {
                    self.vm.enabledFields.remove(key)
                }
            }
        )
    }

    /// A compact "Select All / None" header row shown at the top of the Details form
    /// when editing multiple tracks.
    var selectAllNoneSection: some View {
        Section {
            HStack {
                Button(L10n.string("Select All")) { self.vm.enableAllFields() }
                    .help(L10n.string("Mark all fields as enabled for saving"))
                Button(L10n.string("None")) { self.vm.disableAllFields() }
                    .help(L10n.string("Uncheck all fields so nothing is overwritten"))
                Spacer()
                if !self.vm.enabledFields.isEmpty {
                    Text(localized: "\(self.vm.enabledFields.count) fields will be updated")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Field binding helpers

    /// String binding for a `FieldState<String>` property on the VM.
    func fieldBinding(
        _ kp: WritableKeyPath<TagEditorViewModel, TagEditorViewModel.FieldState<String>>
    ) -> Binding<String> {
        Binding(
            get: { self.vm[keyPath: kp].currentValue.flatMap(\.self) ?? "" },
            set: { newVal in
                // Guard against spurious writes that TextEditor fires during its
                // initialisation / re-render when the binding value already equals the
                // displayed text. Without this guard, `objectWillChange` fires mid-render,
                // causing "Publishing changes from within view updates" faults.
                let current = self.vm[keyPath: kp].currentValue.flatMap(\.self) ?? ""
                guard newVal != current else { return }
                self.applyStringEdit(kp, value: newVal)
            }
        )
    }

    func intBinding(
        _ kp: WritableKeyPath<TagEditorViewModel, TagEditorViewModel.FieldState<Int>>
    ) -> Binding<Int?> {
        Binding(
            get: { self.vm[keyPath: kp].currentValue.flatMap(\.self) },
            set: { newVal in self.applyIntEdit(kp, value: newVal) }
        )
    }

    func applyStringEdit(
        _ kp: WritableKeyPath<TagEditorViewModel, TagEditorViewModel.FieldState<String>>,
        value: String
    ) {
        switch kp {
        case \.title:
            self.vm.setTitle(value)

        case \.artist:
            self.vm.setArtist(value)

        case \.albumArtist:
            self.vm.setAlbumArtist(value)

        case \.album:
            self.vm.setAlbum(value)

        case \.genre:
            self.vm.setGenre(value)

        case \.composer:
            self.vm.setComposer(value)

        case \.comment:
            self.vm.setComment(value)

        case \.key:
            self.vm.setKey(value)

        case \.isrc:
            self.vm.setISRC(value)

        case \.lyrics:
            self.vm.setLyrics(value)

        case \.sortArtist:
            self.vm.setSortArtist(value)

        case \.sortAlbumArtist:
            self.vm.setSortAlbumArtist(value)

        case \.sortAlbum:
            self.vm.setSortAlbum(value)

        default:
            break
        }
    }

    func applyIntEdit(
        _ kp: WritableKeyPath<TagEditorViewModel, TagEditorViewModel.FieldState<Int>>,
        value: Int?
    ) {
        switch kp {
        case \.year:
            self.vm.setYear(value)

        case \.trackNumber:
            self.vm.setTrackNumber(value)

        case \.trackTotal:
            self.vm.setTrackTotal(value)

        case \.discNumber:
            self.vm.setDiscNumber(value)

        case \.discTotal:
            self.vm.setDiscTotal(value)

        default:
            break
        }
    }

    /// Three compact case-transformation buttons for a single text field.
    func casePillButtons(for field: TagEditorViewModel.StringField) -> some View {
        HStack(spacing: 4) {
            Button(L10n.string("Aa")) {
                self.vm.applyTextCase(.titleCase, to: field)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help(L10n.string("Title Case"))
            .accessibilityLabel(L10n.string("Title Case for \(String(describing: field))"))

            Button(L10n.string("AA")) {
                self.vm.applyTextCase(.upper, to: field)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help(L10n.string("UPPERCASE"))
            .accessibilityLabel(L10n.string("Uppercase for \(String(describing: field))"))

            Button(L10n.string("aa")) {
                self.vm.applyTextCase(.lower, to: field)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help(L10n.string("lowercase"))
            .accessibilityLabel(L10n.string("Lowercase for \(String(describing: field))"))
        }
    }
}

// MARK: - FieldState helpers (internal)

extension TagEditorViewModel.FieldState {
    /// Current displayable value: the edited value if set, the shared value otherwise.
    /// Returns `nil` for `.various`.
    var currentValue: T?? {
        switch self {
        case let .shared(val):
            val

        case let .edited(val):
            val

        case .various:
            nil
        }
    }
}

extension TagEditorViewModel.FieldState where Self == TagEditorViewModel.FieldState<String> {
    static func == (lhs: Self, rhs: Self) -> Bool {
        if case .various = lhs, case .various = rhs { return true }
        return false
    }
}

extension TagEditorViewModel.FieldState where Self == TagEditorViewModel.FieldState<Int> {
    static func == (lhs: Self, rhs: Self) -> Bool {
        if case .various = lhs, case .various = rhs { return true }
        return false
    }
}

/// Double-optional FieldState comparison for IntFieldRow.isVarious
extension TagEditorViewModel.FieldState where Self == TagEditorViewModel.FieldState<Double> {
    static func == (lhs: Self, rhs: Self) -> Bool {
        if case .various = lhs, case .various = rhs { return true }
        return false
    }
}
