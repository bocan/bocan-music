import Foundation
import Testing

/// Background services started with `Task.detached { await service.start() }`
/// in `buildGraph` must also be stored on `AppGraph`. A local deallocates the
/// moment `buildGraph` returns and the service's pass silently never runs;
/// that is how the artist enrichment job (#401) shipped inert for a day.
@Suite("Background service retention")
struct BackgroundServiceRetentionTests {
    private func bocanAppSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/BocanApp.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("every service whose start() is fired from buildGraph is a stored property of AppGraph")
    func startedServicesAreRetained() throws {
        let source = try self.bocanAppSource()
        let started = source.matches(of: /await (\w+)\.start\(\)/).map { String($0.1) }
        #expect(!started.isEmpty)
        let graph = try #require(source.range(of: "struct AppGraph {"))
        let graphBody = source[graph.upperBound...].prefix(while: { _ in true })
        for name in started {
            let type = name.prefix(1).uppercased() + name.dropFirst()
            let retained = graphBody.contains(": \(type)") || graphBody
                .contains(": \(type.replacingOccurrences(of: "Service", with: ""))Service")
            #expect(retained, "\(name).start() is called in buildGraph but AppGraph has no stored property of its type")
        }
    }
}
