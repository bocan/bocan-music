import Foundation
import Testing
@testable import UI

// MARK: - SubsonicSidebarConnectionState

@Suite("SubsonicSidebarConnectionState")
struct SubsonicSidebarConnectionStateTests {
    @Test("isOnline is true only for .online")
    func isOnlineOnlyForOnline() {
        #expect(SubsonicSidebarConnectionState.online.isOnline)
        let others: [SubsonicSidebarConnectionState] = [
            .unknown, .connecting,
            .authFailed("x"), .unreachable("y"), .serverError("z"),
        ]
        for state in others {
            #expect(!state.isOnline, "Expected \(state) not online")
        }
    }

    @Test("isOffline is true for failure states only")
    func isOfflineCases() {
        let offline: [SubsonicSidebarConnectionState] = [
            .authFailed("x"), .unreachable("y"), .serverError("z"),
        ]
        for s in offline {
            #expect(s.isOffline, "Expected \(s) offline")
        }
        let notOffline: [SubsonicSidebarConnectionState] = [
            .unknown, .connecting, .online,
        ]
        for s in notOffline {
            #expect(!s.isOffline, "Expected \(s) not offline")
        }
    }

    @Test("displayLabel is non-empty for every case")
    func displayLabelNonEmpty() {
        let all: [SubsonicSidebarConnectionState] = [
            .unknown, .connecting, .online,
            .authFailed("Bad credentials"),
            .unreachable("DNS failure"),
            .serverError("HTTP 500"),
        ]
        for s in all {
            #expect(!s.displayLabel.isEmpty)
        }
    }

    @Test("displayLabel embeds the message for failure states")
    func failureDisplayLabelsEmbedMessage() {
        #expect(SubsonicSidebarConnectionState.authFailed("nope").displayLabel.contains("nope"))
        #expect(SubsonicSidebarConnectionState.unreachable("no dns").displayLabel.contains("no dns"))
        #expect(SubsonicSidebarConnectionState.serverError("boom").displayLabel.contains("boom"))
    }

    @Test("Hashable: identical cases have identical hashes")
    func hashableConsistency() {
        let lhs: SubsonicSidebarConnectionState = .authFailed("x")
        let rhs: SubsonicSidebarConnectionState = .authFailed("x")
        #expect(lhs == rhs)
        #expect(lhs.hashValue == rhs.hashValue)
    }
}
