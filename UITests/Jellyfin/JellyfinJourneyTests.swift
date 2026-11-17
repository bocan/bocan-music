import XCTest

// MARK: - JellyfinJourneyTests

/// ADR-097 slice 9: the Jellyfin source end to end, against
/// `E2EJellyfinServer`, a loopback fake server (the ADR-085 pattern). One
/// journey walks the whole life of a server: add it in Settings by password,
/// browse its songs, play one, star it, and remove the server.
///
/// The app keeps the journey's sign-in token under its own Keychain service
/// and its streamed songs in the run's own folder (`E2EEnvironment`), so a
/// run never touches the developer's real Jellyfin servers.
@MainActor
final class JellyfinJourneyTests: XCTestCase {
    private var session: E2ESession!
    private var server: E2EJellyfinServer!

    override func setUp() async throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
        self.server = try E2EJellyfinServer()
    }

    override func tearDown() async throws {
        self.server?.stop()
    }

    func testAddBrowsePlayFavouriteAndRemoveAServer() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        let first = E2EJellyfinFixture.songs[0]

        // Add: Settings, Sources, Jellyfin, sign in with a password.
        self.addServer(app, inv)
        XCTAssertEqual(self.server.actions.first, "POST /Users/AuthenticateByName accepted")

        // Browse: the server's row, then its Songs.
        inv.selectSidebar(identifier: "sidebar.jellyfin.server")
        XCTAssertTrue(
            inv.element("sidebar.jellyfin.songs").waitForExistence(timeout: 10),
            "expanding the server never showed its rows"
        )
        inv.selectSidebar(identifier: "sidebar.jellyfin.songs")
        // In the table only: once the song plays, the player bar shows its title too.
        let table = inv.element("jellyfinSongsTable")
        let firstRow = table.staticTexts[first.title]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15), "the server's songs never appeared")
        XCTAssertTrue(table.staticTexts[E2EJellyfinFixture.songs[1].title].exists)

        // Play: the stream comes from the fake server, and the server hears
        // that the song started (play reports are on by default).
        firstRow.doubleClick()
        XCTAssertTrue(app.waitUntilPlaying(timeout: 20), "the Jellyfin song never started playing")
        XCTAssertEqual(self.server.streamedItemIDs.first, first.id)
        inv.waitFor("the server hears that the song started", timeout: 10) {
            self.server.actions.contains("POST /Sessions/Playing")
        }
        app.playPauseButton.click()
        XCTAssertTrue(app.waitUntilNotPlaying(timeout: 5))

        // Favourite: Star in the row's menu marks it on the server.
        firstRow.rightClick()
        inv.settle(0.3)
        app.menuItems["Star"].click()
        inv.waitFor("the server records the favourite", timeout: 10) {
            self.server.favouriteItemIDs.contains(first.id)
        }

        // Remove: from the sidebar, which asks the server to end the sign-in.
        inv.element("sidebar.jellyfin.server").rightClick()
        inv.settle(0.3)
        app.menuItems["Remove\u{2026}"].click()
        let confirm = app.buttons["Remove Server"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the removal was never confirmed")
        confirm.click()
        inv.waitFor("the server is asked to end the sign-in", timeout: 10) {
            self.server.actions.contains("POST /Sessions/Logout")
        }
        inv.waitFor("the server leaves the sidebar") {
            !inv.element("sidebar.jellyfin.server").exists
        }
    }

    // MARK: - Helpers

    private func launch() -> XCUIApplication {
        let app = self.session.launch(arguments: MenuManifest.matrixDefaults)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        app.activate()
        return app
    }

    /// Adds the fake server through Settings, Sources, as a user does, then
    /// closes Settings. `.pasteText` carries the address, because `typeText`
    /// drops the colon in `http://127.0.0.1:PORT` (see `MenuInvoker`).
    private func addServer(_ app: XCUIApplication, _ inv: MenuInvoker) {
        let anchor = SettingsCrawlTests.openSettings(app, inv)
        SettingsCrawlTests.navigate(inv, app, to: "sources", anchor: anchor)

        let kind = inv.element("settings.sources.kind")
        XCTAssertTrue(kind.waitForExistence(timeout: 5), "the Subsonic / Jellyfin switch is missing")
        kind.radioButtons["Jellyfin"].click()

        let add = inv.element("settings.jellyfin.addServer.empty")
        XCTAssertTrue(add.waitForExistence(timeout: 5), "a first Jellyfin server has no Add Server button")
        SettingsCrawlTests.tap(add)

        let address = inv.element("settings.jellyfin.url")
        XCTAssertTrue(address.waitForExistence(timeout: 5), "the server editor never opened")
        inv.pasteText(self.server.baseURL.absoluteString, into: address)

        let username = inv.element("settings.jellyfin.username")
        username.click()
        username.typeText(E2EJellyfinFixture.username)
        let password = inv.element("settings.jellyfin.password")
        password.click()
        password.typeText(E2EJellyfinFixture.password)

        SettingsCrawlTests.tap(inv.element("settings.jellyfin.signIn"))
        // A saved server's editor has Remove; the new-server form does not.
        inv.waitFor("the sign-in saves the server", timeout: 15) {
            inv.element("settings.jellyfin.remove").exists
        }
        inv.closeFrontWindow()
        inv.waitFor("the server appears in the sidebar", timeout: 10) {
            inv.element("sidebar.jellyfin.server").exists
        }
    }
}
