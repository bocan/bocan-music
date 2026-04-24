import Foundation
import Testing
@testable import Library

@Suite("RateLimiter")
struct RateLimiterTests {
    @Test func singleRequest_immediate() async {
        let limiter = RateLimiter(maxRequests: 1, per: 1.0)
        // Should return without significant delay
        let start = Date()
        await limiter.wait()
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.1)
    }

    @Test func exceedingBudget_sleeps() async {
        let limiter = RateLimiter(maxRequests: 2, per: 0.3)
        // Fire 2 requests immediately (within budget)
        await limiter.wait()
        await limiter.wait()
        // Third request must wait
        let start = Date()
        await limiter.wait()
        let elapsed = Date().timeIntervalSince(start)
        // Should have waited roughly 0.3s (allow generous tolerance for CI)
        #expect(elapsed > 0.15)
    }

    @Test func countsResetsAfterWindow() async {
        let limiter = RateLimiter(maxRequests: 1, per: 0.1)
        await limiter.wait()

        // Wait for the window to expire
        try? await Task.sleep(nanoseconds: 150_000_000) // 150 ms

        // Now a new request should go through immediately
        let start = Date()
        await limiter.wait()
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.1)
    }
}
