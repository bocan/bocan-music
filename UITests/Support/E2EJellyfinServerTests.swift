import XCTest

// MARK: - E2EJellyfinServerTests

/// Checks `E2EJellyfinServer`'s answers directly, before the app's Jellyfin
/// SDK sees them. A mistake here would otherwise show up three steps away in
/// the journey, as a sign-in or decode failure (the same reason as
/// `E2EPodcastServerTests`).
final class E2EJellyfinServerTests: XCTestCase {
    private var server: E2EJellyfinServer!

    override func setUp() async throws {
        self.server = try E2EJellyfinServer(songSeconds: 1)
    }

    override func tearDown() async throws {
        self.server?.stop()
    }

    func testPublicInfoNeedsNoSignIn() async throws {
        let (data, status) = try await self.request("GET", "/System/Info/Public")
        XCTAssertEqual(status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["ServerName"] as? String, E2EJellyfinFixture.serverName)
    }

    func testSignInAcceptsOnlyTheFixturePassword() async throws {
        let (data, status) = try await self.request(
            "POST",
            "/Users/AuthenticateByName",
            body: ["Username": E2EJellyfinFixture.username, "Pw": E2EJellyfinFixture.password]
        )
        XCTAssertEqual(status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["AccessToken"] as? String, E2EJellyfinFixture.accessToken)

        let (_, refused) = try await self.request(
            "POST",
            "/Users/AuthenticateByName",
            body: ["Username": E2EJellyfinFixture.username, "Pw": "wrong"]
        )
        XCTAssertEqual(refused, 401)
    }

    func testListsNeedTheToken() async throws {
        let (_, without) = try await self.request("GET", "/Items?includeItemTypes=Audio")
        XCTAssertEqual(without, 401)

        let (data, with) = try await self.request("GET", "/Items?includeItemTypes=Audio", signedIn: true)
        XCTAssertEqual(with, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let names = (json["Items"] as? [[String: Any]])?.compactMap { $0["Name"] as? String }
        XCTAssertEqual(names, E2EJellyfinFixture.songs.map(\.title))
    }

    func testFavouritesAreLoggedAndFilterStarred() async throws {
        let id = E2EJellyfinFixture.songs[0].id
        let (_, status) = try await self.request("POST", "/UserFavoriteItems/\(id)", signedIn: true)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(self.server.favouriteItemIDs, [id])
        XCTAssertEqual(self.server.actions, ["POST /UserFavoriteItems/\(id)"])

        let (data, _) = try await self.request("GET", "/Items?includeItemTypes=Audio&isFavorite=true", signedIn: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["Items"] as? [Any])?.count, 1)
    }

    func testStreamServesTheWAVWithTheTokenInTheURL() async throws {
        let id = E2EJellyfinFixture.songs[1].id
        let path = "/Audio/\(id)/stream?static=true&ApiKey=\(E2EJellyfinFixture.accessToken)"
        let (data, status) = try await self.request("GET", path)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(self.server.streamedItemIDs, [id])
    }

    // MARK: - Helpers

    private func request(
        _ method: String,
        _ pathAndQuery: String,
        body: [String: String]? = nil,
        signedIn: Bool = false
    ) async throws -> (Data, Int) {
        let url = try XCTUnwrap(URL(string: self.server.baseURL.absoluteString + pathAndQuery))
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if signedIn {
            request.setValue(
                "MediaBrowser Client=\"E2E\", Token=\"\(E2EJellyfinFixture.accessToken)\"",
                forHTTPHeaderField: "Authorization"
            )
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
