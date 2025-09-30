import Foundation

/// Retry strategy for connection attempts.
public enum RetryStrategy: Sendable {
    /// Use exponential backoff with jitter.
    case exponentialBackoff

    /// Use a fixed delay between retries.
    case fixedDelay
}
