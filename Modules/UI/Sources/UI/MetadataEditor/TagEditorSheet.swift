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
    @State private var isPresentingRenumberConfirm = false
    @State private var isPresentingConflictDiff = false
    /// Tracks keyboard focus across all editable fields in the Details tab.
    /// Internal (not private) so the TagEditorSheet+DetailsTab extension can access `$focusedField`.
    @FocusState var focusedField: TagEditorFocusField?

    public var body: some View {
        VStack(spacing: 0) {
            // Conflict-resolution banner — shown when disk changed after user edit
            if self.vm.hasConflict {
                self.conflictBanner
            }

            // Tab picker
            Picker(L10n.string("Tab"), selection: self.$selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .labelsHidden()
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

                case .fileInfo:
                    self.fileInfoTab

                case .sorting:
                    self.sortingTab

                case .advanced:
                    self.advancedTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            self.bottomBar
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 420)
        .task { await self.vm.load() }
        .onAppear { self.focusedField = .title }
        .alert(L10n.string("Error"), isPresented: Binding(
            get: { self.vm.lastError != nil },
            set: { if !$0 { self.vm.lastError = nil } }
        )) {
            Button(L10n.string("OK")) { self.vm.lastError = nil }
        } message: {
            Text(self.vm.lastError ?? "")
        }
        .sheet(isPresented: self.$isPresentingFetchSheet) {
            CoverArtFetchSheet(
                vm: self.vm.coverArtFetchVM,
                isPresented: self.$isPresentingFetchSheet
            ) { data in
                self.vm.pendingArtData = data
            }
        }
        .sheet(isPresented: self.$isPresentingConflictDiff) {
            ConflictDiffSheet(vm: self.vm, isPresented: self.$isPresentingConflictDiff)
        }
    }

    // MARK: - Tabs

    /// Banner displayed when at least one track has `needsConflictReview = true`.
    private var conflictBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(localized: "This file was changed on disk after your last edit.")
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.string("Keep My Edits")) {
                Task { await self.vm.keepMyEdits() }
            }
            .help(L10n.string("Preserve your stored tag values and dismiss this warning"))
            Button(L10n.string("Take Disk Version")) {
                Task { await self.vm.takeDiskVersion() }
            }
            .help(L10n.string("Load the tags now on disk, discarding your previous edits"))
            Button(L10n.string("Show Diff…")) {
                self.isPresentingConflictDiff = true
            }
            .help(L10n.string("Compare your stored edits side-by-side with what's on disk"))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Conflict: file was changed on disk after your last edit"))
    }

    // MARK: - Bulk Actions (multi-track only)

    var bulkActionsSection: some View {
        Section(L10n.string("Bulk Actions")) {
            // Renumber tracks in current sort order
            LabeledContent(L10n.string("Track Numbers")) {
                Button(L10n.string("Renumber 1…\(self.vm.trackCount)")) {
                    if self.vm.tracksSpanMultipleAlbums {
                        self.isPresentingRenumberConfirm = true
                    } else {
                        Task { await self.vm.renumberTracks() }
                    }
                }
                .disabled(self.vm.isApplyingBulkAction)
                .help(L10n.string("Assign sequential track numbers (1…N) in the current sort order"))
            }
            .confirmationDialog(
                L10n.string("Tracks span multiple albums"),
                isPresented: self.$isPresentingRenumberConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.string("Renumber Anyway"), role: .destructive) {
                    Task { await self.vm.renumberTracks() }
                }
                Button(L10n.string("Cancel"), role: .cancel) {}
            } message: {
                Text(localized:
                    "The selected tracks belong to more than one album. Renumbering will overwrite each track's number. Continue?")
            }

            // Copy each track's artist into its album artist field
            LabeledContent(L10n.string("Album Artist")) {
                Button(L10n.string("Set from Artist")) {
                    Task { await self.vm.copyArtistToAlbumArtist() }
                }
                .disabled(self.vm.isApplyingBulkAction)
                .help(L10n.string("Copy each track's Artist value into its Album Artist field"))
            }

            // Text case buttons for all text fields
            LabeledContent(L10n.string("Text Case")) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(TagEditorViewModel.StringField.allCases, id: \.self) { field in
                        GridRow {
                            Text(field.label)
                                .foregroundStyle(Color.textSecondary)
                                .frame(maxWidth: 110, alignment: .trailing)
                            self.casePillButtons(for: field)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // Three compact case-transformation buttons for a single text field.
    // (defined in TagEditorSheet+DetailsTab.swift)

    private var artworkTab: some View {
        ArtworkEditor(vm: self.vm, isPresentingFetchSheet: self.$isPresentingFetchSheet)
    }

    private var lyricsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !self.vm.isSingleTrack, let eb = self.enabledFor(.lyrics) {
                Toggle(L10n.string("Apply lyrics to all tracks"), isOn: eb)
                    .toggleStyle(.checkbox)
                    .padding(.horizontal)
                    .help(L10n.string("When checked, the lyrics text will be written to every selected track on Save"))
            }
            HStack {
                Text(localized: "Lyrics")
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textTertiary)
                Spacer()
                Picker("", selection: self.$vm.lyricsMode) {
                    Text(localized: "Auto").tag(TagEditorViewModel.LyricsMode.auto)
                    Text(localized: "Synced").tag(TagEditorViewModel.LyricsMode.synced)
                    Text(localized: "Plain").tag(TagEditorViewModel.LyricsMode.plain)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .help(L10n.string(
                    "Auto: detect LRC timestamps. Synced: always save as synced (LRC). Plain: always save as plain text."
                ))
            }
            .padding(.horizontal)
            if self.vm.lyricsMode == .auto, self.vm.lrcTimestampsDetected {
                HStack(spacing: 4) {
                    Image(systemName: "clock.badge.checkmark")
                        .imageScale(.small)
                    Text(localized: "LRC timestamps detected — will be saved as synced lyrics")
                        .font(Typography.footnote)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal)
                .accessibilityLabel(L10n.string("LRC timestamps detected, lyrics will be saved as synced"))
            }
            TextEditor(text: self.fieldBinding(\.lyrics))
                .font(Typography.body)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(4)
                .background(Color(.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding()
        }
    }

    // sortingTab is defined in TagEditorSheet+DetailsTab.swift

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            if self.vm.lastEditID != nil {
                Button(L10n.string("Undo")) { Task { await self.vm.undo() } }
                    .keyboardShortcut("z", modifiers: .command)
            }
            Spacer()
            if self.vm.isSaving {
                ProgressView().scaleEffect(0.7)
            }
            Button(L10n.string("Cancel")) { self.isPresented = false }
                .keyboardShortcut(.escape)
            Button(L10n.string("Save")) {
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

    // fieldBinding, intBinding, applyStringEdit, applyIntEdit live in TagEditorSheet+DetailsTab.swift
}

// MARK: - TagEditorFocusField

/// Identifies each focusable field in the Details tab for explicit Tab-key order.
/// Internal so the TagEditorSheet+DetailsTab extension in a separate file can use it.
enum TagEditorFocusField: Hashable {
    case title

    case artist

    case albumArtist

    case album

    case genre

    case composer

    case year

    case trackNumber

    case trackTotal

    case discNumber

    case discTotal

    case bpm

    case key

    case isrc

    case comment

    case rating

    case loved

    case excludedFromShuffle
}

// MARK: - Tab enum

private enum Tab: String, CaseIterable, Identifiable {
    case details, artwork, lyrics, fileInfo, sorting, advanced

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .details:
            L10n.string("Details")

        case .artwork:
            L10n.string("Artwork")

        case .lyrics:
            L10n.string("Lyrics")

        case .fileInfo:
            L10n.string("File Info")

        case .sorting:
            L10n.string("Sorting")

        case .advanced:
            L10n.string("Advanced")
        }
    }
}
