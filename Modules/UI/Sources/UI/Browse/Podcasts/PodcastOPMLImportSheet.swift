import SwiftUI

// MARK: - OPMLImportProgress

/// Main-actor progress box the off-actor import callback writes through.
/// A `@MainActor` class is implicitly `Sendable`, so the `@Sendable` progress
/// closure can capture it and hop a `Task { @MainActor }` to update it.
@MainActor
final class OPMLImportProgress: ObservableObject {
    @Published var completed = 0
    @Published var total = 0

    func update(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }
}

// MARK: - PodcastOPMLImportSheet

/// Reads a picked OPML file, drives `PodcastsViewModel.importOPML` with
/// determinate progress, and shows an added / skipped / failed summary with the
/// failed feeds (and reasons) listed. A non-empty success toasts via the library.
struct PodcastOPMLImportSheet: View {
    let fileURL: URL
    @ObservedObject var vm: PodcastsViewModel
    let library: LibraryViewModel

    @Environment(\.dismiss) private var dismiss

    @StateObject private var progress = OPMLImportProgress()
    @State private var phase: Phase = .importing
    @State private var summary: UIOPMLImportSummary?
    @State private var errorMessage: String?

    private enum Phase {
        case importing
        case done
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized: "Import Subscriptions")
                .font(.title2.weight(.semibold))

            self.content

            HStack {
                Spacer()
                if self.phase == .done {
                    Button(L10n.string("Done")) { self.dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L10n.string("Cancel"), role: .cancel) { self.dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 320)
        .task { await self.runImport() }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var content: some View {
        if self.phase == .failed {
            self.failedView
        } else if self.phase == .done {
            self.summaryView
        } else {
            self.importingView
        }
    }

    private var importingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: self.fileURL.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
            if self.progress.total > 0 {
                ProgressView(value: Double(self.progress.completed), total: Double(self.progress.total)) {
                    Text(localized: "Subscribing…")
                }
                Text(L10n.string("\(self.progress.completed) of \(self.progress.total)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView {
                    Text(localized: "Reading subscriptions…")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryView: some View {
        let summary = self.summary ?? UIOPMLImportSummary()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Label(L10n.string("\(summary.succeeded.count) added"), systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Label(L10n.string("\(summary.alreadySubscribed.count) skipped"), systemImage: "minus.circle")
                    .foregroundStyle(.secondary)
                Label(L10n.string("\(summary.failed.count) failed"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(summary.failed.isEmpty ? Color.secondary : Color.orange)
            }
            if !summary.failed.isEmpty {
                Text(localized: "Could not subscribe to:")
                    .font(.headline)
                List(summary.failed) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.title)
                            .font(.body.weight(.medium))
                        Text(verbatim: item.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 160)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var failedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.string("Import failed"), systemImage: "xmark.octagon")
                .foregroundStyle(.red)
            if let message = self.errorMessage {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func runImport() async {
        let progress = self.progress // local capture: keeps the @Sendable closure off `self`
        do {
            let data = try Data(contentsOf: self.fileURL)
            let result = try await self.vm.importOPML(data: data) { completed, total in
                Task { @MainActor in progress.update(completed: completed, total: total) }
            }
            self.summary = result
            self.phase = .done
            if !result.succeeded.isEmpty {
                self.library.showToast(ToastMessage(
                    text: L10n.string("Imported \(result.succeeded.count) subscriptions"),
                    kind: .success
                ))
            }
            await self.vm.loadSubscribed()
        } catch {
            self.errorMessage = error.localizedDescription
            self.phase = .failed
        }
    }
}
