import Observability
import Persistence
import SwiftUI

// MARK: - LibraryListeningBehaviourPane

/// The Library Summary window's Listening Behaviour tab (#373), slice one
/// (phase 25-1): the imported-history ledger the coming analytics build on.
/// Import, re-match, and remove live here; skip rates, heatmaps, and
/// discovery charts arrive on top of this store in the next slices.
struct LibraryListeningBehaviourPane: View {
    /// Observed so the import-in-flight spinner and completion refresh work.
    @ObservedObject var library: LibraryViewModel

    @State private var counts: ListenImportRepository.Counts?
    @State private var showRemoveConfirm = false

    var body: some View {
        Form {
            self.importedHistorySection
        }
        .formStyle(.grouped)
        .task { await self.load() }
        .onChange(of: self.library.isImportingListens) { _, importing in
            guard !importing else { return }
            Task { await self.load() }
        }
        .confirmationDialog(
            L10n.string("Remove all imported listening history?"),
            isPresented: self.$showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Remove Imported History"), role: .destructive) {
                Task {
                    await self.library.removeImportedListens()
                    await self.load()
                }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(localized: "Locally recorded plays are not affected.")
        }
    }

    // MARK: - Sections

    private var importedHistorySection: some View {
        Section {
            if self.library.isImportingListens {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(localized: "Importing listening history…")
                }
            } else if let counts, counts.total > 0 {
                self.countRows(counts)
                self.actionsRow
            } else {
                HStack {
                    Text(localized: "No listening history imported yet")
                    Spacer()
                    self.importButton
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(localized: "Imported History")
        } footer: {
            self.footer
        }
    }

    @ViewBuilder
    private func countRows(_ counts: ListenImportRepository.Counts) -> some View {
        LabeledContent(L10n.string("Imported listens"), value: counts.total.formatted())
        LabeledContent(L10n.string("Matched to your library"), value: Self.matchedValue(counts))
        if counts.unmatched > 0 {
            LabeledContent(L10n.string("Awaiting a match"), value: counts.unmatched.formatted())
        }
    }

    private var actionsRow: some View {
        HStack {
            self.importButton
            Button(L10n.string("Match Again")) {
                Task {
                    await self.library.rematchImportedListens()
                    await self.load()
                }
            }
            .buttonStyle(.bordered)
            .help(L10n.string("Try to link unmatched listens after adding music to the library"))
            Spacer()
            Button(L10n.string("Remove…"), role: .destructive) {
                self.showRemoveConfirm = true
            }
            .buttonStyle(.bordered)
        }
    }

    private var importButton: some View {
        Button(L10n.string("Import Last.fm Export…")) {
            Task { await self.library.importListeningHistoryByPicker() }
        }
        .buttonStyle(.bordered)
    }

    private var footer: some View {
        Text(
            localized: """
            Imported plays stay separate from local play counts. Unmatched \
            listens are kept, and Match Again links them up after your \
            library grows.
            """
        )
        .font(Typography.caption)
        .foregroundStyle(Color.textTertiary)
    }

    // MARK: - Formatting

    private static func matchedValue(_ counts: ListenImportRepository.Counts) -> String {
        let share = counts.total > 0
            ? (Double(counts.matched) / Double(counts.total)).formatted(.percent.precision(.fractionLength(0)))
            : 0.formatted(.percent)
        return L10n.string("\(counts.matched.formatted()) (\(share))")
    }

    // MARK: - Data

    private func load() async {
        do {
            self.counts = try await ListenImportRepository(database: self.library.database).counts()
        } catch {
            AppLogger.make(.ui).error(
                "librarySummary.listening.load.failed",
                ["error": String(reflecting: error)]
            )
        }
    }
}
