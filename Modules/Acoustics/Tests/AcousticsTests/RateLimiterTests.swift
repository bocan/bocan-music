import Foundation
import Testing
@testable import Acoustics

@Suite("RateLimiter")
struct RateLimiterTests {
    @Test("single request passes immediately")
    func singleRequest() async {
        let limiter = RateLimiter(maxRequests: 1, per: 1.0)
        let start = Date()
        await limiter.wait()
        #expect(Date().timeIntervalSince(start) < 0.1)
    }

    @Test("3-req/s bucket: 4th request delayed by ≥ 333 ms")
    func acoustidBucket() async {
        let limiter = RateLimiter(maxRequests: 3, per: 1.0)
        await limiter.wait()
        await limiter.wait()
        await limiter.wait()
        let start = Date()
        await limiter.wait()
        let elapsed = Date().timeIntervalSince(start)
        // 1s / 3 requests ≈ 333 ms. Allow generous tolerance for CI.
        #expect(elapsed >= 0.25)
    }

    @Test("1-req/s bucket: 2nd request delayed by ≥ 1 s")
    func mbBucket() async {
        let limiter = RateLimiter(maxRequests: 1, per: 1.0)
        await limiter.wait()
        let start = Date()
        await limiter.wait()
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 0.8)
    }

    @Test("window resets: request after interval passes immediately")
    func windowReset() async {
        let limiter = RateLimiter(maxRequests: 1, per: 0.1)
        await limiter.wait()
        try? await Task.sleep(for: .milliseconds(150))
        let start = Date()
        await limiter.wait()
        #expect(Date().timeIntervalSince(start) < 0.1)
    }
}
