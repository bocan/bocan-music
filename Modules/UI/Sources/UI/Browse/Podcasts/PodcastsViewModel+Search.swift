import Foundation

// MARK: - PodcastsViewModel + Search (Phase 21-8)

/// Search, add-by-URL, and detail-sheet actions for the podcast discovery bar.
public extension PodcastsViewModel {
    // MARK: - Add bar / search driver

    /// Search driver invoked by `PodcastsHomeView` after a 300 ms debounce.
    ///
    /// - Detects whether `text` is a feed URL and sets `addByURLCandidate`.
    /// - Empty/whitespace -> `.idle`, clear results.
    /// - Otherwise fires `searchProvider.search(term:)` and updates `searchState`.
    ///
    /// Called inside a SwiftUI `task(id: vm.addBarText)` closure, so the in-flight
    /// search is cancelled automatically when `addBarText` changes (Task cancellation
    /// propagates into `PodcastSearchService.search` which calls `checkCancellation`).
    func onAddBarTextChanged(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           url.host != nil {
            self.addByURLCandidate = url
        } else {
            self.addByURLCandidate = nil
        }

        guard !trimmed.isEmpty else {
            self.searchState = .idle
            self.searchResults = []
            return
        }

        guard let searchProvider else { return }
        self.searchState = .searching

        do {
            let results = try await searchProvider.search(term: trimmed)
            self.searchResults = results
            self.searchState = results.isEmpty ? .empty : .results
        } catch is CancellationError {
            // Task was cancelled because addBarText changed; leave state as-is.
        } catch {
            self.searchState = .error(error.localizedDescription)
            self.log.error("podcasts.search.failed", [
                "term": trimmed,
                "error": String(reflecting: error),
            ])
        }
    }

    // MARK: - Detail

    /// Fetches and opens the detail sheet for a search result.
    ///
    /// Sets `isLoadingDetail = true` and `showingDetail = true` immediately so the
    /// sheet opens with a spinner while the live feed is fetched + parsed.
    func openDetail(_ result: UIPodcastSearchResult) async {
        self.currentDetail = nil
        self.detailError = nil
        self.isLoadingDetail = true
        self.showingDetail = true
        self.detailTask?.cancel()
        guard let searchProvider else {
            self.isLoadingDetail = false
            return
        }
        self.detailTask = Task { [weak self, result] in
            do {
                let detail = try await searchProvider.detail(feedURL: result.feedURL, hint: result)
                guard !Task.isCancelled else { return }
                self?.currentDetail = detail
                self?.isLoadingDetail = false
            } catch is CancellationError {
                self?.isLoadingDetail = false
            } catch {
                self?.detailError = error.localizedDescription
                self?.isLoadingDetail = false
                self?.log.error("podcasts.detail.failed", [
                    "url": result.feedURL.absoluteString,
                    "error": String(reflecting: error),
                ])
            }
        }
    }

    /// Fetches and opens the detail sheet for a raw feed URL (the add-by-URL flow).
    func openDetailForURL(_ url: URL) async {
        let syntheticResult = UIPodcastSearchResult(
            canonicalFeedKey: url.absoluteString,
            feedURL: url,
            title: url.absoluteString
        )
        await self.openDetail(syntheticResult)
    }

    /// Dismisses the detail sheet and clears its state.
    func dismissDetail() {
        self.showingDetail = false
        self.currentDetail = nil
        self.detailError = nil
        self.isLoadingDetail = false
        self.detailTask?.cancel()
    }

    /// Subscribes using the feed URL from the current detail. On success, flips
    /// `currentDetail.alreadySubscribed` so the button reflects the new state.
    func subscribe(fromDetail detail: PodcastDetail) async {
        do {
            let newID = try await self.actions?.subscribe(feedURL: detail.feedURL)
            if var updated = self.currentDetail, updated.feedURL == detail.feedURL {
                updated.alreadySubscribed = true
                updated.podcastID = newID
                self.currentDetail = updated
            }
        } catch {
            self.log.error("podcasts.subscribe.failed", [
                "url": detail.feedURL.absoluteString,
                "error": String(reflecting: error),
            ])
        }
    }

    /// Re-runs the current add-bar text through search (retry after an error).
    func retrySearch() async {
        await self.onAddBarTextChanged(self.addBarText)
    }
}
