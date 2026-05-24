import Foundation
import Observability
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicInternetRadioViewModel

/// Drives the per-server Internet Radio destination (Phase 19 step 11).
///
/// Capability-gated by `SubsonicCapabilities.supportsInternetRadio`. The
/// view is read-only — direct streaming of arbitrary HTTP radio URLs is
/// handled separately and is out of scope here.
@MainActor
public final class SubsonicInternetRadioViewModel: ObservableObject {
    public let serverID: UUID

    @Published public private(set) var stations: [InternetRadioStation] = []
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?

    private let dataSource: any SubsonicBrowseDataSource
    private let log = AppLogger.make(.ui)

    public init(serverID: UUID, dataSource: any SubsonicBrowseDataSource) {
        self.serverID = serverID
        self.dataSource = dataSource
    }

    public func load() async {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        do {
            self.stations = try await self.dataSource
                .getInternetRadioStations(serverID: self.serverID)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.errorMessage = nil
        } catch {
            self.log.error("subsonic.radio.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Could not load internet radio stations."
        }
    }
}

// MARK: - SubsonicInternetRadioView

public struct SubsonicInternetRadioView: View {
    public let serverID: UUID

    @StateObject private var vm: SubsonicInternetRadioViewModel

    public init(serverID: UUID, dataSource: any SubsonicBrowseDataSource) {
        self.serverID = serverID
        self._vm = StateObject(
            wrappedValue: SubsonicInternetRadioViewModel(serverID: serverID, dataSource: dataSource)
        )
    }

    public var body: some View {
        Group {
            if self.vm.stations.isEmpty, !self.vm.isLoading {
                ContentUnavailableView(
                    "No Stations",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("This server has no internet radio stations.")
                )
            } else {
                List {
                    ForEach(self.vm.stations, id: \.id) { station in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(station.name)
                                .font(Typography.subheadline)
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(1)
                            if let home = station.homePageUrl, !home.isEmpty {
                                Text(home)
                                    .font(Typography.caption)
                                    .foregroundStyle(Color.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Internet Radio")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await self.vm.load() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(self.vm.isLoading)
            }
        }
        .task(id: self.serverID) {
            if self.vm.stations.isEmpty { await self.vm.load() }
        }
        .alert(
            "Couldn't load stations",
            isPresented: Binding(
                get: { self.vm.errorMessage != nil },
                set: { if !$0 { self.vm.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(self.vm.errorMessage ?? "") }
        )
    }
}
