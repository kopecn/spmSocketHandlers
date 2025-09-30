import Foundation
import NIOCore

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
    public let qosClass: QoSClass

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
        qosClass: QoSClass = .default,
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
