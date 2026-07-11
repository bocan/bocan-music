import Foundation
import Testing
@testable import SyncServer

@Suite("Router")
struct RouterTests {
    private func request(_ method: String, _ path: String) -> HttpRequest {
        HttpRequest(method: method, path: path, query: [:], headers: [:], body: Data())
    }

    private func trustedContext() -> ConnectionContext {
        let context = ConnectionContext()
        context.recordPeer(certificateDER: Data([0x01]), fingerprint: "aa", isPairing: false, isTrusted: true)
        return context
    }

    private func makeRouter() -> Router {
        Router(routes: [
            Router.Route("GET", "/v1/ping", auth: .anyTLS) { _, _ in
                HttpResponse(status: 200)
            },
            Router.Route("GET", "/v1/manifest", auth: .paired) { _, _ in
                HttpResponse(status: 200, body: Data("manifest".utf8))
            },
            Router.Route("GET", "/v1/file/track/{trackId}", auth: .paired) { _, match in
                HttpResponse(status: 200, body: Data((match.parameters["trackId"] ?? "").utf8))
            },
        ])
    }

    @Test("dispatches a matching route")
    func dispatchesPing() async {
        let response = await self.makeRouter().dispatch(self.request("GET", "/v1/ping"), context: ConnectionContext())
        #expect(response.status == 200)
    }

    @Test("unknown path returns 404")
    func unknownPath() async {
        let response = await self.makeRouter().dispatch(self.request("GET", "/v1/nope"), context: ConnectionContext())
        #expect(response.status == 404)
    }

    @Test("known path with the wrong method returns 405")
    func wrongMethod() async {
        let response = await self.makeRouter().dispatch(self.request("POST", "/v1/ping"), context: ConnectionContext())
        #expect(response.status == 405)
    }

    @Test("a paired route rejects an untrusted connection with 403")
    func pairedRouteRejectsUntrusted() async {
        let response = await self.makeRouter().dispatch(self.request("GET", "/v1/manifest"), context: ConnectionContext())
        #expect(response.status == 403)
    }

    @Test("a paired route admits a trusted connection")
    func pairedRouteAdmitsTrusted() async {
        let response = await self.makeRouter().dispatch(self.request("GET", "/v1/manifest"), context: self.trustedContext())
        #expect(response.status == 200)
        #expect(String(data: response.body, encoding: .utf8) == "manifest")
    }

    @Test("captures a path parameter")
    func capturesParameter() async {
        let response = await self.makeRouter().dispatch(self.request("GET", "/v1/file/track/123"), context: self.trustedContext())
        #expect(response.status == 200)
        #expect(String(data: response.body, encoding: .utf8) == "123")
    }
}
