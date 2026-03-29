import Foundation

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
    public let qosClass: QoSClass

    /// Maximum number of messages to queue when disconnected. Defaults to 500.
    public let messageQueueSize: Int

    /// How long to keep queued messages before expiring them (in seconds). Defaults to 600 (10 minutes).
    public let messageExpirationTime: TimeInterval

    /// The tokenizer string used to split incoming messages. Defaults to "\n".
    public let tokenizer: String

    /// Maximum number of bytes allowed in the cumulation buffer before the connection is closed.
    /// Protects against unbounded memory growth from peers that never send the delimiter.
    /// Defaults to 1 MB (1_048_576 bytes).
    public let maxCumulationBufferSize: Int

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
    ///   - tokenizer: The tokenizer string used to split incoming messages.
    ///   - maxCumulationBufferSize: Maximum bytes in the cumulation buffer before closing the connection.
    public init(
        connectTimeout: TimeInterval = 30.0,
        bufferSize: Int = 1024,
        enableAutoReconnect: Bool = false,
        retryPolicy: RetryPolicy = .exponentialBackoff(),
        enableKeepAlive: Bool = true,
        qosClass: QoSClass = .default,
        messageQueueSize: Int = 500,
        messageExpirationTime: TimeInterval = 600,
        tokenizer: String = "\n",
        maxCumulationBufferSize: Int = 1_048_576
    ) {
        self.connectTimeout = connectTimeout
        self.bufferSize = bufferSize
        self.enableAutoReconnect = enableAutoReconnect
        self.retryPolicy = retryPolicy
        self.enableKeepAlive = enableKeepAlive
        self.qosClass = qosClass
        self.messageQueueSize = messageQueueSize
        self.messageExpirationTime = messageExpirationTime
        self.tokenizer = tokenizer
        self.maxCumulationBufferSize = maxCumulationBufferSize
    }

    /// A default configuration with commonly used settings.
    public static let `default` = ClientConfiguration()
}
