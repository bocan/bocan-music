import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PodcastsHomeView

/// Main Podcasts window: a persistent Add bar docked at the top, followed by
/// either the search results list (when the user has typed) or the subscribed-
/// shows grid (or empty state) when the search is idle.
///
/// Routed from `ContentPane` for `.podcasts`.
public struct PodcastsHomeView: View {
    @ObservedObject public var vm: PodcastsViewModel
    public var library: LibraryViewModel

    /// Identifiable wrapper so the import sheet is driven by `.sheet(item:)`: the
    /// content is built with the URL present from the first frame, so the sheet
    /// sizes correctly (a `.sheet(isPresented:)` + `if let` renders an empty,
    /// collapsed box on the first pass before the URL is observed).
    private struct OPMLImportFile: Identifiable {
        var id: String {
            self.url.absoluteString
        }

        let url: URL
    }

    @State private var importFile: OPMLImportFile?

    public init(vm: PodcastsViewModel, library: LibraryViewModel) {
        self.vm = vm
        self.library = library
    }

    public var body: some View {
        VStack(spacing: 0) {
            PodcastAddBar(vm: self.vm)
            Divider()
            Group {
                if self.vm.searchState == .idle {
                    if self.vm.subscribed.isEmpty {
                        PodcastsEmptyState()
                    } else {
                        PodcastsGridView(vm: self.vm, library: self.library)
                    }
                } else {
                    PodcastSearchResultsView(vm: self.vm)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(L10n.string("Podcasts"))
        // Debounce: task(id:) cancels the prior task when addBarText changes.
        // The 300 ms sleep is the debounce window; CancellationError means a new
        // character arrived -- do not call onAddBarTextChanged.
        .task(id: self.vm.addBarText) {
            do {
                try await Task.sleep(for: .milliseconds(300))
                await self.vm.onAddBarTextChanged(self.vm.addBarText)
            } catch {
                // CancellationError -- text changed within 300 ms; debounce working.
            }
        }
        .sheet(
            isPresented: self.$vm.showingDetail,
            onDismiss: { self.vm.dismissDetail() },
            content: {
                if let detail = self.vm.currentDetail {
                    PodcastDetailView(vm: self.vm, detail: detail)
                } else {
                    PodcastDetailLoadingView(vm: self.vm)
                }
            }
        )
        .sheet(item: self.$importFile) { file in
            PodcastOPMLImportSheet(fileURL: file.url, vm: self.vm, library: self.library)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L10n.string("Import Subscriptions…")) { self.importSubscriptions() }
                    Button(L10n.string("Export Subscriptions…")) { Task { await self.exportSubscriptions() } }
                } label: {
                    Label(L10n.string("Subscriptions"), systemImage: "square.and.arrow.up.on.square")
                }
                .help(L10n.string("Import or export your podcast subscriptions as OPML"))
            }
        }
    }

    // MARK: - OPML import / export

    private func importSubscriptions() {
        // Non-blocking begin{} panel, matching the PlaylistIO file-picker idiom.
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            var types: [UTType] = [.xml]
            if let opml = UTType(filenameExtension: "opml") { types.insert(opml, at: 0) }
            panel.allowedContentTypes = types
            let result = await withCheckedContinuation { cont in
                panel.begin { cont.resume(returning: $0) }
            }
            guard result == .OK, let url = panel.url else { return }
            self.importFile = OPMLImportFile(url: url)
        }
    }

    private func exportSubscriptions() async {
        guard !self.vm.subscribed.isEmpty else {
            self.library.showToast(ToastMessage(text: L10n.string("No subscriptions to export"), kind: .info))
            return
        }
        do {
            let data = try await self.vm.exportOPML()
            let save = NSSavePanel()
            save.nameFieldStringValue = L10n.string("Podcast Subscriptions") + ".opml"
            if let opml = UTType(filenameExtension: "opml") { save.allowedContentTypes = [opml] }
            let result = await withCheckedContinuation { cont in
                save.begin { cont.resume(returning: $0) }
            }
            guard result == .OK, let dest = save.url else { return }
            try data.write(to: dest, options: .atomic)
            self.library.showToast(ToastMessage(text: L10n.string("Exported subscriptions"), kind: .success))
        } catch {
            self.library.showToast(ToastMessage(text: L10n.string("Could not export subscriptions"), kind: .info))
        }
    }
}

// MARK: - PodcastsEmptyState

/// Shown when the user has no subscriptions yet.
private struct PodcastsEmptyState: View {
    var body: some View {
        EmptyState(
            symbol: "antenna.radiowaves.left.and.right",
            title: L10n.string("No Podcasts"),
            message: L10n.string("Subscribe to a podcast to get started.")
        )
    }
}
