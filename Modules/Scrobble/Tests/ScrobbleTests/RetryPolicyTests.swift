import Foundation
import Testing
@testable import Scrobble

@Suite("RetryPolicy")
struct RetryPolicyTests {
    @Test("first attempt has no delay")
    func noDelayForFirst() {
        let policy = RetryPolicy(baseDelay: 30, maxDelay: 3600, maxAttempts: 5, jitter: 0)
        #expect(policy.delay(forAttempt: 1) == 0)
    }

    @Test("backoff doubles each attempt up to cap")
    func doublingBackoff() {
        let policy = RetryPolicy(baseDelay: 30, maxDelay: 3600, maxAttempts: 20, jitter: 0)
        // attempt 2 → base * 2^0 = 30
        // attempt 3 → 60, attempt 4 → 120, …
        #expect(policy.delay(forAttempt: 2) == 30)
        #expect(policy.delay(forAttempt: 3) == 60)
        #expect(policy.delay(forAttempt: 4) == 120)
        #expect(policy.delay(forAttempt: 10) == 3600) // capped
    }

    @Test("jitter falls within ±range")
    func jitterRange() {
        let policy = RetryPolicy(baseDelay: 30, maxDelay: 3600, maxAttempts: 20, jitter: 0.2)
        for r in [0.0, 0.5, 1.0] {
            let delay = policy.delay(forAttempt: 3) { r }
            // base 60, ±20% → [48, 72] (allow tiny FP slop)
            #expect(delay >= 47.999 && delay <= 72.001)
        }
    }

    @Test("isExhausted at maxAttempts")
    func exhaustion() {
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 1, maxAttempts: 5, jitter: 0)
        #expect(!policy.isExhausted(attempts: 4))
        #expect(policy.isExhausted(attempts: 5))
        #expect(policy.isExhausted(attempts: 100))
    }
}
