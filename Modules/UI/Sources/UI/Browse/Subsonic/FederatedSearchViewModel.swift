import Foundation
import Observability
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicSearchSection

/// One server's contribution to a federated search (Phase 19 step 13).
///
/// Carries enough state for the search results UI to render a per-server
/// card showing in-flight, success, failure, or timeout states without
/// needing to inspect the underlying data source.
public struct SubsonicSearchSection: Identifiable, Sendable {
    public enum State: Sendable {
        case loading
        case success(SearchResult3)
        case failure(String)
        case timedOut
    }

    public let serverID: UUID
    public let serverName: String
    public var state: State

    public var id: UUID {
        self.serverID
    }
}

// MARK: - FederatedSearchViewModel

/// Drives the federated Subsonic search panel (Phase 19 step 13).
///
/// Holds one ``SubsonicSearchSection`` per `includeInGlobalSearch` server.
/// Each server is queried in parallel with a soft per-server timeout so a
/// slow or unreachable server cannot delay the others.
@MainActor
public final class FederatedSearchViewModel: ObservableObject {
    /// Per-server soft timeout. Slow servers fall over to ``State/timedOut``
    /// rather than blocking the panel as a whole.
    public static let defaultTimeout: Duration = .milliseconds(1500)

    /// Maximum artists/albums/songs to request per server.
    public static let artistCount = 5
    public static let albumCount = 5
    public static let songCount = 20

    @Published public private(set) var query = ""
    @Published public private(set) var sections: [SubsonicSearchSection] = []

    private let dataSource: any SubsonicBrowseDataSource
    private let timeout: Duration
    private let log = AppLogger.make(.ui)
    private var currentTask: Task<Void, Never>?

    public init(
        dataSource: any SubsonicBrowseDataSource,
        timeout: Duration = FederatedSearchViewModel.defaultTimeout
    ) {
        self.dataSource = dataSource
        self.timeout = timeout
    }

    /// Cancels any in-flight search and clears the panel.
    public func clear() {
        self.currentTask?.cancel()
        self.currentTask = nil
        self.query = ""
        self.sections = []
    }

    /// Fan out a `search3` call to every `includeInGlobalSearch` server.
    ///
    /// Trims the query; empty queries clear the panel. Any previous in-flight
    /// search is cancelled before the new fan-out starts.
    public func search(query rawQuery: String, servers: [SubsonicSidebarServer]) {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentTask?.cancel()

        guard !trimmed.isEmpty else {
            self.query = ""
            self.sections = []
            self.currentTask = nil
            return
        }

        let included = servers.filter(\.includeInGlobalSearch)
        guard !included.isEmpty else {
            self.query = trimmed
            self.sections = []
            self.currentTask = nil
            return
        }

        self.query = trimmed
        self.sections = included.map { server in
            SubsonicSearchSection(
                serverID: server.id,
                serverName: server.name,
                state: .loading
            )
        }

        let dataSource = self.dataSource
        let timeout = self.timeout
        self.currentTask = Task { [weak self] in
            await withTaskGroup(of: (UUID, SubsonicSearchSection.State).self) { group in
                for server in included {
                    group.addTask {
                        let result = await Self.searchOne(
                            serverID: server.id,
                            query: trimmed,
                            dataSource: dataSource,
                            timeout: timeout
                        )
                        return (server.id, result)
                    }
                }
                for await (id, state) in group {
                    guard let self else { return }
                    if Task.isCancelled { return }
                    self.updateSection(id: id, state: state)
                }
            }
        }
    }

    private func updateSection(id: UUID, state: SubsonicSearchSection.State) {
        guard let idx = self.sections.firstIndex(where: { $0.serverID == id }) else { return }
        self.sections[idx].state = state
    }

    private static func searchOne(
        serverID: UUID,
        query: String,
        dataSource: any SubsonicBrowseDataSource,
        timeout: Duration
    ) async -> SubsonicSearchSection.State {
        let log = AppLogger.make(.ui)
        return await withTaskGroup(of: SubsonicSearchSection.State?.self) { group in
            group.addTask {
                do {
                    let result = try await dataSource.search3(
                        serverID: serverID,
                        query: query,
                        artistCount: Self.artistCount,
                        albumCount: Self.albumCount,
                        songCount: Self.songCount
                    )
                    return .success(result)
                } catch is CancellationError {
                    return nil
                } catch {
                    log.warning(
                        "subsonic.search.failed",
                        ["server": serverID.uuidString, "error": String(reflecting: error)]
                    )
                    let msg = (error as? LocalizedError)?.errorDescription
                        ?? "Search failed on this server."
                    return .failure(msg)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                if Task.isCancelled { return nil }
                return .timedOut
            }
            let first = await (group.next()).flatMap(\.self)
            group.cancelAll()
            return first ?? .timedOut
        }
    }
}
