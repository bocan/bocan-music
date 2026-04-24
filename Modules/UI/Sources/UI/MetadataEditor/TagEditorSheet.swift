import Library
import SwiftUI

// MARK: - TagEditorSheet

/// Metadata editor sheet — single or multi-track.
///
/// Open via `⌘I` / "Get Info" context menu.  Multi-track mode activates
/// automatically when `vm.trackIDs` has more than one item.
public struct TagEditorSheet: View {
    @ObservedObject public var vm: TagEditorViewModel
    @Binding public var isPresented: Bool

    public init(vm: TagEditorViewModel, isPresented: Binding<Bool>) {
        self.vm = vm
        self._isPresented = isPresented
    }

    @State private var selectedTab: Tab = .details
    @State private var isPresentingFetchSheet = false

    public var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("Tab", selection: self.$selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 12)

            Divider().padding(.top, 8)

            ScrollView {
                switch self.selectedTab {
                case .details:
                    self.detailsTab

                case .artwork:
                    self.artworkTab

                case .lyrics:
                    self.lyricsTab

                case .sorting:
                    self.sortingTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            self.bottomBar
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 420)
        .task { await self.vm.load() }
        .alert("Error", isPresented: Binding(
            get: { self.vm.lastError != nil },
            set: { if !$0 { self.vm.lastError = nil } }
        )) {
            Button("OK") { self.vm.lastError = nil }
        } message: {
            Text(self.vm.lastError ?? "")
        }
        .sheet(isPresented: self.$isPresentingFetchSheet) {
            CoverArtFetchSheet(
                vm: CoverArtFetchViewModel(fetcher: CoverArtSearchService()),
                isPresented: self.$isPresentingFetchSheet
            ) { data in
                self.vm.pendingArtData = data
            }
        }
    }

    // MARK: - Tabs

    private var detailsTab: some View {
        Form {
            Section("Track Info") {
                TagFieldRow("Title", text: self.fieldBinding(\.title), isVarious: self.vm.title == .various)
                TagFieldRow("Artist", text: self.fieldBinding(\.artist), isVarious: self.vm.artist == .various)
                TagFieldRow("Album Artist", text: self.fieldBinding(\.albumArtist), isVarious: self.vm.albumArtist == .various)
                TagFieldRow("Album", text: self.fieldBinding(\.album), isVarious: self.vm.album == .various)
                TagFieldRow("Genre", text: self.fieldBinding(\.genre), isVarious: self.vm.genre == .various)
                TagFieldRow("Composer", text: self.fieldBinding(\.composer), isVarious: self.vm.composer == .various)
            }

            Section("Numbering") {
                IntFieldRow("Year", value: self.intBinding(\.year), isVarious: self.vm.year == .various)
                if self.vm.isSingleTrack {
                    IntFieldRow("Track", value: self.intBinding(\.trackNumber), isVarious: false)
                    IntFieldRow("Of", value: self.intBinding(\.trackTotal), isVarious: false)
                }
                IntFieldRow("Disc", value: self.intBinding(\.discNumber), isVarious: self.vm.discNumber == .various)
                IntFieldRow("Discs", value: self.intBinding(\.discTotal), isVarious: self.vm.discTotal == .various)
            }

            Section("Extended") {
                IntFieldRow("BPM", value: Binding(
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
                ))
                TagFieldRow("Key", text: self.fieldBinding(\.key), isVarious: self.vm.key == .various)
                TagFieldRow("ISRC", text: self.fieldBinding(\.isrc), isVarious: self.vm.isrc == .various)
                TagFieldRow("Comment", text: self.fieldBinding(\.comment), isVarious: self.vm.comment == .various)
            }

            Section("Rating") {
                StarRatingRow("Rating", rating: Binding(
                    get: { self.vm.rating.currentValue.flatMap(\.self) },
                    set: { self.vm.setRating($0) }
                ))
                Toggle("Loved", isOn: Binding(
                    get: { self.vm.loved.currentValue.flatMap(\.self) ?? false },
                    set: { self.vm.setLoved($0) }
                ))
                Toggle("Excluded from Shuffle", isOn: Binding(
                    get: { self.vm.excludedFromShuffle.currentValue.flatMap(\.self) ?? false },
                    set: { self.vm.setExcludedFromShuffle($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var artworkTab: some View {
        ArtworkEditor(vm: self.vm, isPresentingFetchSheet: self.$isPresentingFetchSheet)
    }

    private var lyricsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lyrics")
                .font(Typography.footnote)
                .foregroundStyle(Color.textTertiary)
                .padding(.horizontal)
            TextEditor(text: self.fieldBinding(\.lyrics))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(4)
                .background(Color(.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding()
        }
    }

    private var sortingTab: some View {
        Form {
            Section("Sort Names") {
                TagFieldRow(
                    "Sort Artist",
                    text: self.fieldBinding(\.sortArtist),
                    isVarious: self.vm.sortArtist == .various
                )
                TagFieldRow(
                    "Sort Album Artist",
                    text: self.fieldBinding(\.sortAlbumArtist),
                    isVarious: self.vm.sortAlbumArtist == .various
                )
                TagFieldRow(
                    "Sort Album",
                    text: self.fieldBinding(\.sortAlbum),
                    isVarious: self.vm.sortAlbum == .various
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            if self.vm.lastEditID != nil {
                Button("Undo") { Task { await self.vm.undo() } }
                    .keyboardShortcut("z", modifiers: .command)
            }
            Spacer()
            if self.vm.isSaving {
                ProgressView().scaleEffect(0.7)
            }
            Button("Cancel") { self.isPresented = false }
                .keyboardShortcut(.escape)
            Button("Save") {
                Task {
                    await self.vm.save()
                    if self.vm.lastError == nil { self.isPresented = false }
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(self.vm.isSaving)
        }
        .padding()
    }

    // MARK: - Helpers

    /// String binding for a `FieldState<String>` property on the VM.
    private func fieldBinding(_ kp: WritableKeyPath<TagEditorViewModel, TagEditorViewModel.FieldState<String>>) -> Binding<String> {
        Binding(
            get: { self.vm[keyPath: kp].currentValue.flatMap(\.self) ?? "" },
            set: { newVal in
                // Reflect the edit back through the typed setter on the VM.
                // Since we can't call a setter generically, we embed the mapping here.
                self.applyStringEdit(kp, value: newVal)
            }
        )
    }

    private func intBinding(_ kp: WritableKeyPath<TagEditorViewModel, TagEditorViewModel.FieldState<Int>>) -> Binding<Int?> {
        Binding(
            get: { self.vm[keyPath: kp].currentValue.flatMap(\.self) },
            set: { newVal in self.applyIntEdit(kp, value: newVal) }
        )
    }

    private func applyStringEdit(
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

    private func applyIntEdit(
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
}

// MARK: - Tab enum

private enum Tab: String, CaseIterable, Identifiable {
    case details, artwork, lyrics, sorting

    var id: String {
        self.rawValue
    }

    var label: LocalizedStringKey {
        switch self {
        case .details:
            "Details"

        case .artwork:
            "Artwork"

        case .lyrics:
            "Lyrics"

        case .sorting:
            "Sorting"
        }
    }
}

// MARK: - FieldState helper

private extension TagEditorViewModel.FieldState {
    /// Current displayable value (edited or shared).
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

private extension TagEditorViewModel.FieldState where Self == TagEditorViewModel.FieldState<String> {
    static func == (lhs: Self, rhs: Self) -> Bool {
        if case .various = lhs, case .various = rhs { return true }
        return false
    }
}

private extension TagEditorViewModel.FieldState where Self == TagEditorViewModel.FieldState<Int> {
    static func == (lhs: Self, rhs: Self) -> Bool {
        if case .various = lhs, case .various = rhs { return true }
        return false
    }
}
