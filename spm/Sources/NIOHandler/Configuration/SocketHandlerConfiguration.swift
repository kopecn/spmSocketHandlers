import Foundation
import NIOCore
import Dispatch

/// Configuration object for NIOSocketHandlerClient.
///
/// This structure contains all configurable parameters for client behavior,
/// allowing for better customization and testability.
public struct ClientConfiguration: Sendable {
    /// The connection timeout in seconds. Defaults to 30 seconds.
    public let connectTimeout: TimeInterval

    /// The size of the buffer for message allocation. Defaults to 1024 bytes.
    public let bufferSize: Int

    /// Whether to enable automatic reconnection. Defaults to false.
    public let enableAutoReconnect: Bool

    /// The retry policy for automatic reconnection. Only used if enableAutoReconnect is true.
    public let retryPolicy: RetryPolicy

    /// Whether to enable TCP keep-alive. Defaults to true.
    public let enableKeepAlive: Bool

    /// The quality of service for the client's dispatch queue. Defaults to .default.
    public let qosClass: DispatchQoS

    /// Maximum number of messages to queue when disconnected. Defaults to 500.
    public let messageQueueSize: Int

    /// How long to keep queued messages before expiring them (in seconds). Defaults to 600 (10 minutes).
    public let messageExpirationTime: TimeInterval

    /// Creates a new ClientConfiguration with the specified parameters.
    ///
    /// - Parameters:
    ///   - connectTimeout: The connection timeout in seconds.
    ///   - bufferSize: The size of the buffer for message allocation.
    ///   - enableAutoReconnect: Whether to enable automatic reconnection.
    ///   - retryPolicy: The retry policy for automatic reconnection.
    ///   - enableKeepAlive: Whether to enable TCP keep-alive.
    ///   - qosClass: The quality of service for the client's dispatch queue.
    ///   - messageQueueSize: Maximum number of messages to queue when disconnected.
    ///   - messageExpirationTime: How long to keep queued messages before expiring them.
    public init(
        connectTimeout: TimeInterval = 30.0,
        bufferSize: Int = 1024,
        enableAutoReconnect: Bool = false,
        retryPolicy: RetryPolicy = .exponentialBackoff(),
        enableKeepAlive: Bool = true,
        qosClass: DispatchQoS = .default,
        messageQueueSize: Int = 500,
        messageExpirationTime: TimeInterval = 600
    ) {
        self.connectTimeout = connectTimeout
        self.bufferSize = bufferSize
        self.enableAutoReconnect = enableAutoReconnect
        self.retryPolicy = retryPolicy
        self.enableKeepAlive = enableKeepAlive
        self.qosClass = qosClass
        self.messageQueueSize = messageQueueSize
        self.messageExpirationTime = messageExpirationTime
    }

    /// A default configuration with commonly used settings.
    public static let `default` = ClientConfiguration()
}

/// Configuration object for NIOSocketHandlerServer.
///
/// This structure contains all configurable parameters for server behavior,
/// allowing for better customization and scalability.
public struct ServerConfiguration: Sendable {
    /// The default host address to bind to. Defaults to "::1" (IPv6 localhost).
    public let bindHost: String

    /// The maximum number of concurrent client connections. Defaults to 1000.
    public let maxConnections: Int

    /// Whether to enable SO_REUSEADDR socket option. Defaults to true.
    public let reuseAddress: Bool

    /// Whether to enable TCP keep-alive for client connections. Defaults to true.
    public let enableKeepAlive: Bool

    /// The size of the buffer for message allocation. Defaults to 1024 bytes.
    public let bufferSize: Int

    /// The quality of service for the server's dispatch queue. Defaults to .default.
    public let qosClass: DispatchQoS

    /// The number of event loop threads to create. Defaults to System.coreCount.
    public let eventLoopThreads: Int

    /// Maximum number of messages to queue per client when disconnected. Defaults to 100.
    public let clientMessageQueueSize: Int

    /// How long to keep queued messages before expiring them (in seconds). Defaults to 300 (5 minutes).
    public let clientMessageExpirationTime: TimeInterval

    /// Creates a new ServerConfiguration with the specified parameters.
    ///
    /// - Parameters:
    ///   - bindHost: The default host address to bind to.
    ///   - maxConnections: The maximum number of concurrent client connections.
    ///   - reuseAddress: Whether to enable SO_REUSEADDR socket option.
    ///   - enableKeepAlive: Whether to enable TCP keep-alive for client connections.
    ///   - bufferSize: The size of the buffer for message allocation.
    ///   - qosClass: The quality of service for the server's dispatch queue.
    ///   - eventLoopThreads: The number of event loop threads to create.
    ///   - clientMessageQueueSize: Maximum number of messages to queue per client when disconnected.
    ///   - clientMessageExpirationTime: How long to keep queued messages before expiring them.
    public init(
        bindHost: String = "0.0.0.0",
        maxConnections: Int = 1000,
        reuseAddress: Bool = true,
        enableKeepAlive: Bool = true,
        bufferSize: Int = 1024,
        qosClass: DispatchQoS = .default,
        eventLoopThreads: Int = System.coreCount,
        clientMessageQueueSize: Int = 100,
        clientMessageExpirationTime: TimeInterval = 300
    ) {
        self.bindHost = bindHost
        self.maxConnections = maxConnections
        self.reuseAddress = reuseAddress
        self.enableKeepAlive = enableKeepAlive
        self.bufferSize = bufferSize
        self.qosClass = qosClass
        self.eventLoopThreads = eventLoopThreads
        self.clientMessageQueueSize = clientMessageQueueSize
        self.clientMessageExpirationTime = clientMessageExpirationTime
    }

    /// A default configuration with commonly used settings.
    public static let `default` = ServerConfiguration()
}

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

/// Retry strategy for connection attempts.
public enum RetryStrategy: Sendable {
    /// Use exponential backoff with jitter.
    case exponentialBackoff

    /// Use a fixed delay between retries.
    case fixedDelay
}