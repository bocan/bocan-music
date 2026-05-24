import Foundation
import Testing
@testable import Playback

@Suite("CoreAudioOutputDeviceProvider")
struct CoreAudioOutputDeviceProviderTests {
    @Test("current() returns a non-nil device info on macOS")
    func current() async {
        let provider = CoreAudioOutputDeviceProvider()
        let info = await provider.current()
        // On a CI/sandbox host with no audio there's still a default output device.
        #expect(!info.name.isEmpty)
    }

    @Test("updates() yields the current value to subscribers")
    func updatesYieldsInitial() async {
        let provider = CoreAudioOutputDeviceProvider()
        let stream = provider.updates()
        var iter = stream.makeAsyncIterator()
        let info = await iter.next()
        #expect(info != nil)
        // Drop the stream — onTermination should run and remove listeners.
    }

    @Test("multiple subscribers can subscribe concurrently and terminate cleanly")
    func multipleSubscribers() async {
        let provider = CoreAudioOutputDeviceProvider()
        let a = provider.updates()
        let b = provider.updates()
        var aiter = a.makeAsyncIterator()
        var biter = b.makeAsyncIterator()
        _ = await aiter.next()
        _ = await biter.next()
    }
}
