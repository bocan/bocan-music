import Foundation
import Testing

// MARK: - PhoneSyncWiringTests

/// Guards the App-level wiring for the Phone Sync server (phase 22-7). The
/// bootstrap and lifecycle observers cannot be introspected without a running
/// app, so this pins the source contract: the server is a graph member,
/// constructed unconditionally, started only behind the default-off
/// `sync.enabled` gate, and hooked into wake/terminate.
@Suite("Phone Sync app wiring")
struct PhoneSyncWiringTests {
    private func appSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/BocanApp.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("SyncServer is a member of AppGraph")
    func syncServerInGraph() throws {
        let source = try self.appSource()
        #expect(
            source.contains("let syncServer: SyncServer"),
            "AppGraph must hold the Phone Sync server"
        )
    }

    @Test("the server starts only when sync.enabled is on")
    func startGatedOnToggle() throws {
        let source = try self.appSource()
        #expect(
            source.contains("UserDefaults.standard.bool(forKey: \"sync.enabled\")"),
            "start() must be gated on the sync.enabled toggle"
        )
        #expect(
            source.contains("try await syncServer.start()"),
            "the gated branch must start the server"
        )
    }

    @Test("Phone Sync is off by default")
    func offByDefault() throws {
        let source = try self.appSource()
        #expect(
            source.contains("\"sync.enabled\": false"),
            "sync.enabled must default to false"
        )
    }

    @Test("the server re-advertises on wake and stops on quit")
    func lifecycleObservers() throws {
        let source = try self.appSource()
        #expect(
            source.contains("await syncServer.reAdvertise()"),
            "didWake must re-advertise the Bonjour service"
        )
        #expect(
            source.contains("quitWork.add { await syncServer.stop() }"),
            "the quit work must withdraw the server"
        )
    }

    /// A quit observer that waits on a semaphore blocks the user-interactive
    /// main thread on a default-QoS task: a priority inversion on every quit.
    /// Quit-time async work goes through `QuitWork` instead.
    @Test("no App code blocks the main thread on a semaphore")
    func noSemaphoreWaits() throws {
        let appDir = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App")
        let files = try FileManager.default.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !source.contains("DispatchSemaphore("),
                "\(file.lastPathComponent) waits on a semaphore; use QuitWork or async code"
            )
        }
    }
}
