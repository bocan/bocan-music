import Foundation
import Testing
@testable import Persistence

// MARK: - DatabaseLocationTests

/// The app's single-instance lock and crash sentinel resolve their directory
/// through `applicationSupportDirectory`, so it must agree with the database's
/// own location and must never trap.
@Suite("Database Location")
struct DatabaseLocationTests {
    @Test("The support directory is the Bocan folder and it exists")
    func supportDirectoryIsBocan() {
        let dir = DatabaseLocation.applicationSupportDirectory
        #expect(dir.lastPathComponent == "Bocan")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("The application database sits inside the support directory")
    func databaseSitsInSupportDirectory() throws {
        let url = try #require(DatabaseLocation.application.url)
        #expect(url.lastPathComponent == "library.sqlite")
        #expect(url.deletingLastPathComponent().path == DatabaseLocation.applicationSupportDirectory.path)
    }

    @Test("In-memory and custom locations do not touch the support directory")
    func otherLocations() {
        #expect(DatabaseLocation.inMemory.url == nil)
        let custom = URL(fileURLWithPath: "/tmp/bocan-test.sqlite")
        #expect(DatabaseLocation.custom(custom).url == custom)
    }
}
