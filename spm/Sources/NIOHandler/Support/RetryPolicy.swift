import Foundation

/// Retry policy for automatic reconnection attempts.
public struct RetryPolicy: Sendable {
    /// The maximum number of retry attempts. Set to 0 for unlimited retries.
    public let maxRetries: Int

    /// The base delay between retry attempts in seconds.
    public let baseDelay: TimeInterval

    /// The maximum delay between retry attempts in seconds.
    public let maxDelay: TimeInterval

    /// The multiplier for exponential backoff. Only used with exponential backoff strategy.
    public let backoffMultiplier: Double

    /// The retry strategy to use.
    public let strategy: RetryStrategy

    /// Creates a new RetryPolicy with the specified parameters.
    ///
    /// - Parameters:
    ///   - maxRetries: The maximum number of retry attempts.
    ///   - baseDelay: The base delay between retry attempts in seconds.
    ///   - maxDelay: The maximum delay between retry attempts in seconds.
    ///   - backoffMultiplier: The multiplier for exponential backoff.
    ///   - strategy: The retry strategy to use.
    public init(
        maxRetries: Int,
        baseDelay: TimeInterval,
        maxDelay: TimeInterval,
        backoffMultiplier: Double = 2.0,
        strategy: RetryStrategy
    ) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = backoffMultiplier
        self.strategy = strategy
    }

    /// Creates an exponential backoff retry policy.
    ///
    /// - Parameters:
    ///   - maxRetries: The maximum number of retry attempts. Defaults to 5.
    ///   - baseDelay: The base delay between retry attempts in seconds. Defaults to 1.0.
    ///   - maxDelay: The maximum delay between retry attempts in seconds. Defaults to 60.0.
    ///   - backoffMultiplier: The multiplier for exponential backoff. Defaults to 2.0.
    public static func exponentialBackoff(
        maxRetries: Int = 5,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 60.0,
        backoffMultiplier: Double = 2.0
    ) -> RetryPolicy {
        return RetryPolicy(
            maxRetries: maxRetries,
            baseDelay: baseDelay,
            maxDelay: maxDelay,
            backoffMultiplier: backoffMultiplier,
            strategy: .exponentialBackoff
        )
    }

    /// Creates a fixed delay retry policy.
    ///
    /// - Parameters:
    ///   - maxRetries: The maximum number of retry attempts. Defaults to 3.
    ///   - delay: The fixed delay between retry attempts in seconds. Defaults to 5.0.
    public static func fixedDelay(
        maxRetries: Int = 3,
        delay: TimeInterval = 5.0
    ) -> RetryPolicy {
        return RetryPolicy(
            maxRetries: maxRetries,
            baseDelay: delay,
            maxDelay: delay,
            strategy: .fixedDelay
        )
    }
}
