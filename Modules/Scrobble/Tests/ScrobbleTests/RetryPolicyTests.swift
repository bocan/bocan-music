import Foundation
import Testing
@testable import Scrobble

@Suite("RetryPolicy")
struct RetryPolicyTests {
    @Test("first attempt has no delay")
    func noDelayForFirst() {
        let p = RetryPolicy(baseDelay: 30, maxDelay: 3600, maxAttempts: 5, jitter: 0)
        #expect(p.delay(forAttempt: 1) == 0)
    }

    @Test("backoff doubles each attempt up to cap")
    func doublingBackoff() {
        let p = RetryPolicy(baseDelay: 30, maxDelay: 3600, maxAttempts: 20, jitter: 0)
        // attempt 2 → base * 2^0 = 30
        // attempt 3 → 60, attempt 4 → 120, …
        #expect(p.delay(forAttempt: 2) == 30)
        #expect(p.delay(forAttempt: 3) == 60)
        #expect(p.delay(forAttempt: 4) == 120)
        #expect(p.delay(forAttempt: 10) == 3600) // capped
    }

    @Test("jitter falls within ±range")
    func jitterRange() {
        let p = RetryPolicy(baseDelay: 30, maxDelay: 3600, maxAttempts: 20, jitter: 0.2)
        for r in [0.0, 0.5, 1.0] {
            let d = p.delay(forAttempt: 3) { r }
            // base 60, ±20% → [48, 72] (allow tiny FP slop)
            #expect(d >= 47.999 && d <= 72.001)
        }
    }

    @Test("isExhausted at maxAttempts")
    func exhaustion() {
        let p = RetryPolicy(baseDelay: 1, maxDelay: 1, maxAttempts: 5, jitter: 0)
        #expect(!p.isExhausted(attempts: 4))
        #expect(p.isExhausted(attempts: 5))
        #expect(p.isExhausted(attempts: 100))
    }
}
