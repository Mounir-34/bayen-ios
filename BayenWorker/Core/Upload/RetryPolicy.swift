import Foundation

/// Exponential backoff with jitter: 2 s, 4 s, 8 s … capped at 5 minutes.
struct RetryPolicy: Sendable {
    var baseDelay: TimeInterval = 2
    var multiplier: Double = 2
    var maxDelay: TimeInterval = 300
    /// ±20 % randomisation so many phones coming back online don't hit the server together.
    var jitter: Double = 0.2

    /// Delay before attempt number `attempt + 1`, given `attempt` failures so far (1-based).
    func delay(afterFailures attempt: Int, random: () -> Double = { Double.random(in: 0...1) }) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let raw = min(maxDelay, baseDelay * pow(multiplier, exponent))
        let factor = 1 + jitter * (random() * 2 - 1)
        return min(maxDelay, max(0, raw * factor))
    }
}
