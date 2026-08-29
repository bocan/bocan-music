import Foundation
import Testing
@testable import UI

/// Deep Dive is off by default and every surface reads the one key (#413).
@Suite("Deep Dive setting conventions")
struct DeepDiveSettingConventionTests {
    private func source(_ relative: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url.deleteLastPathComponent()
        }
        url.appendPathComponent("Sources/UI/\(relative)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the setting is off unless the user turned it on")
    func offByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "DeepDiveSettingConventionTests-\(UUID().uuidString)"))
        #expect(DeepDiveSetting.isEnabled(in: defaults) == false)
        defaults.set(true, forKey: DeepDiveSetting.key)
        #expect(DeepDiveSetting.isEnabled(in: defaults))
    }

    @Test("Settings > Library owns the toggle, and every Deep Dive surface gates on the key")
    func surfacesGateOnTheKey() throws {
        #expect(try self.source("Settings/LibrarySettingsView.swift").contains("@AppStorage(DeepDiveSetting.key)"))
        #expect(try self.source("Settings/LibrarySettingsView.swift").contains("A11y.SettingsIDs.deepDive"))
        for file in ["DeepDive/ArtistInfoSheet.swift", "MetadataEditor/TagEditorSheet.swift", "Import/ScanBanner.swift"] {
            #expect(try self.source(file).contains("@AppStorage(DeepDiveSetting.key)"), Comment(rawValue: file))
        }
        #expect(try self.source("DeepDive/ArtistInfoSheet.swift").contains("DeepDiveDisabledView()"))
        #expect(try self.source("MetadataEditor/TagEditorSheet+DeepDiveTab.swift").contains("DeepDiveDisabledView()"))
        #expect(try self.source("DeepDive/DeepDiveDisabledView.swift").contains("settingsRouter?.open(.library)"))
    }

    @Test("the enrichment gate never starts the pass while off, starts once per flip on, stops on flip off")
    @MainActor
    func gateFollowsTheSetting() {
        var enabled = false
        var starts: [Duration] = []
        var stops = 0
        let gate = DeepDiveEnrichmentGate(isEnabled: { enabled }, start: { starts.append($0) }, stop: { stops += 1 })

        gate.apply()
        gate.apply()
        #expect(starts.isEmpty)
        #expect(stops == 0, "stopping a pass that never started is noise")

        enabled = true
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        #expect(starts == [DeepDiveEnrichmentGate.toggleDelay], "one start per flip, not per defaults write, and a short wait")

        enabled = false
        gate.apply()
        #expect(stops == 1)
        enabled = true
        gate.apply()
        #expect(starts.count == 2)

        // Enabled at launch: the long wait, so scanning settles first.
        var launchStarts: [Duration] = []
        let atLaunch = DeepDiveEnrichmentGate(isEnabled: { true }, start: { launchStarts.append($0) }, stop: {})
        atLaunch.apply()
        #expect(launchStarts == [DeepDiveEnrichmentGate.launchDelay])
    }
}
