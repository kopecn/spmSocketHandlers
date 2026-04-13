import Foundation
import FoundationInterfaces
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import OpenCombine
import SocketCommon

/// A TCP socket server handler built using SwiftNIO.
///
/// This class manages asynchronous TCP socket server operations including:
/// - Accepting multiple concurrent clients
/// - Receiving and sending string-based messages
/// - Publishing connection state changes
/// - Managing its own event loop group (unless externally provided)
///
/// It provides publishers to observe:
/// - Whether the server is currently listening
/// - The set of connected clients
///
/// Use `listen(port:)` to start the server with the server itself as the message handler,
/// or `listen(port:messageHandler:)` for a custom handler.
/// Call `shutdown()` to stop it and release resources cleanly.
public final class NIOSocketHandlerServer: MessageDuplex, @unchecked Sendable {
    // MARK: - Public Publishers
    /// Publishes updates about the current listening state of the socket server.
    ///
    /// This publisher emits values of type `SocketServerListeningState`, indicating whether the server is currently
    /// listening for connections or is turned off. Subscribers can use this to react to changes in the server's
    /// connection state in real time.
    public let serverConnectionStatePublisher = CurrentValueSubject<
        SocketServerListeningState, Never
    >(.off)

    /// Publishes the set of currently connected client IDs.
    ///
    /// This publisher emits a `Set` of `AnyHashable` values representing all clients currently connected to the server.
    /// Subscribers can observe this publisher to be notified whenever clients connect or disconnect.
    public let connectedClientIDsPublisher = CurrentValueSubject<Set<AnyHashable>, Never>([])

    // MARK: - Internal Properties

    /// The name of the server instance.
    public let name: String

    /// The configuration for this server instance.
    public let configuration: ServerConfiguration

    /// Logger instance used for logging server events and messages.
    private let logger: Logger

    /// Dispatch queue used for server operations.
    private let serverDispatchQueue: DispatchQueue

    /// The event loop group managing the server's event loops.
    private let group: EventLoopGroup

    /// Indicates whether this server instance owns the event loop group and is responsible for its lifecycle.
    private let ownsEventLoopGroup: Bool

    /// The channel on which the server is listening for incoming connections.
    private var listenerChannel: Channel?

    /// A dictionary mapping client identifiers to their corresponding channels.
    private var connectedClients: [AnyHashable: Channel] = [:]

    /// The identifier of the most recently connected client.
    private var lastID: (any Identifiable)?

    /// Connection pool management
    private var connectionQueue: [AnyHashable] = []  // FIFO queue for connection order
    private var connectionCountByClient: [AnyHashable: Int] = [:]  // Track messages per client

    /// Message queues per client for handling offline message delivery
    private var clientMessageQueues: [AnyHashable: MessageQueue] = [:]

    /// Message handler closures for MessageReceivable conformance
    private var stringMessageHandler: (@Sendable (String) -> Void)?
    private var dataMessageHandler: (@Sendable (Data) -> Void)?

    /// Metrics tracking
    private var messagesReceived: Int = 0

    /// Initializes a new `NIOSocketHandlerServer` instance.
    ///
    /// - Parameters:
    ///   - name: The name identifier for this server instance. Defaults to `"nio-handler-server"`.
    ///   - configuration: The configuration for this server instance. Defaults to `ServerConfiguration.default`.
    ///   - eventLoopGroup: An optional external event loop group. If `nil`, a new `MultiThreadedEventLoopGroup` will be created.
    ///   - serverDispatchQueue: An optional dispatch queue for server operations. If `nil`, a new queue will be created.
    ///
    /// - Note:
    ///   - If an external event loop group is provided, the server will not shut it down during cleanup.
    ///     The caller is responsible for managing the lifecycle of the external event loop group.
    public init(
        name: String = "nio-handler-server",
        configuration: ServerConfiguration = .default,
        eventLoopGroup: EventLoopGroup? = nil,
        serverDispatchQueue: DispatchQueue? = nil,
    ) {
        self.name = name
        self.configuration = configuration
        self.logger = Logger(label: "com.socket-handlers.nio-handler.\(name)")
        self.serverDispatchQueue =
            serverDispatchQueue
            ?? DispatchQueue(
                label: "com.socket-handlers.nio-handler.\(name)",
                qos: configuration.qosClass.dispatchQoS
            )

        if let group = eventLoopGroup {
            self.group = group
            self.ownsEventLoopGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(
                numberOfThreads: configuration.eventLoopThreads)
            self.ownsEventLoopGroup = true
        }
    }

    deinit {
        logger.info("NIOSocketHandlerServer deinitialized. Call shutdown() explicitly to clean up.")
    }

    // MARK: - Helpers

    /// Converts any Identifiable to an AnyHashable key using its id.
    private func makeKey(from identifiable: any Identifiable) -> AnyHashable {
        func helper<T: Identifiable>(_ value: T) -> AnyHashable {
            return AnyHashable(value.id)
        }
        return helper(identifiable)
    }

    // MARK: - Public API

    /// Starts the server listening on the specified port using this server as the message handler.
    ///
    /// This simplified method uses the server itself as the message handler. Set up message
    /// handling by calling `setStringMessageHandler(_:)` or `setDataMessageHandler(_:)` before listening.
    ///
    /// - Parameters:
    ///   - port: The port number on which to listen for incoming connections.
    ///   - defaultHost: The default host address the server binds to. Defaults to configuration value.
    ///
    /// - Note:
    ///   - This method executes asynchronously on the server's dispatch queue.
    ///   - The `serverConnectionStatePublisher` will emit `.listening` upon successful binding,
    ///     or `.error(err:)` if binding fails.
    ///   - Use `"0.0.0.0"` or `"::"` to bind to all available interfaces (IPv4 or IPv6 respectively).
    public func listen(
        port: Int,
        defaultHost: String? = nil
    ) {
        listen(port: port, messageHandler: self, defaultHost: defaultHost)
    }

    /// Starts the server listening on the specified port.
    ///
    /// This method binds the server to the default host (::1) and the specified port,
    /// then begins accepting incoming client connections asynchronously.
    ///
    /// - Parameters:
    ///   - port: The port number on which to listen for incoming connections.
    ///   - messageHandler: A message handler conforming to `MessageReceivable` protocol
    ///                     that will process incoming messages from connected clients.
    ///   - defaultHost: The default host address the server binds to when calling `listen(port:messageHandler:)`.
    ///                  This can be an IPv4 or IPv6 address, e.g., `"127.0.0.1"` or `"::1"`. Defaults to `"::1"` (IPv6 localhost).
    ///
    ///
    /// - Note:
    ///   - This method executes asynchronously on the server's dispatch queue.
    ///         The `serverConnectionStatePublisher` will emit `.listening` upon successful binding,
    ///         or `.error(err:)` if binding fails.
    ///   - Use `"0.0.0.0"` or `"::"` to bind to all available interfaces (IPv4 or IPv6 respectively).
    public func listen(
        port: Int,
        messageHandler: MessageReceivable,
        defaultHost: String? = nil
    ) {
        let host = defaultHost ?? configuration.bindHost
        serverDispatchQueue.async { [weak self] in
            guard let self = self else { return }

            self.logger.info("🟢 Starting server on [\(host)]:\(port)")

            let bootstrap = ServerBootstrap(group: self.group)
                .serverChannelOption(
                    ChannelOptions.socketOption(.so_reuseaddr),
                    value: self.configuration.reuseAddress ? 1 : 0
                )
                .childChannelOption(
                    ChannelOptions.socketOption(.so_reuseaddr),
                    value: self.configuration.reuseAddress ? 1 : 0
                )
                .childChannelOption(
                    ChannelOptions.socketOption(.so_keepalive),
                    value: self.configuration.enableKeepAlive ? 1 : 0
                )
                .childChannelInitializer { [weak self] channel in
                    guard let self = self else {
                        return channel.eventLoop.makeFailedFuture(
                            SocketHandlerError.internalFailure(message: "Server deallocated")
                        )
                    }
                    return self.setupChildChannel(channel, messageHandler: messageHandler)
                }

            bootstrap.bind(host: host, port: port).whenComplete { [weak self] result in
                guard let self = self else { return }

                self.serverDispatchQueue.async {
                    switch result {
                    case .success(let channel):
                        self.listenerChannel = channel
                        self.serverConnectionStatePublisher.send(.listening)
                        self.logger.info("🟢 Server is now listening on port \(port)")
                    case .failure(let error):
                        self.serverConnectionStatePublisher.send(.error(err: error))
                        self.logger.error("🔴 Failed to bind server to port \(port): \(error)")
                    }
                }
            }
        }
    }

    /// Fire-and-forget binary send to a specific client. Returns immediately; does not wait
    /// for the write to flush.
    ///
    /// Use this when sending binary/byte-framed payloads and you do not need delivery
    /// confirmation. No delimiter is appended — bytes are written to the channel as-is.
    ///
    /// **When to use `send(to:_:Data:_:_:)` vs `send(confirming:to:)` with Data:**
    /// - Use this overload for high-throughput or best-effort sends where a dropped write is
    ///   acceptable and you want to stay on the non-async call path.
    /// - Use `send(confirming: Data, to:)` when you need to `await` delivery confirmation or
    ///   surface a write error to the caller.
    ///
    /// **Data vs String:**
    /// - Use this overload for binary protocols, packed structs, or any payload where
    ///   appending a newline would corrupt the data.
    /// - Use `send(to:_:String:_:_:)` for newline-delimited text protocols; that overload
    ///   appends `\n` automatically and supports per-client offline queuing.
    ///
    /// - Note: Data queuing is not supported. If `queueIfDisconnected` is `true` and the
    ///   client is disconnected, a warning is logged and the data is dropped.
    ///
    /// - Parameters:
    ///   - id: The target client ID. If `nil`, targets the most recently connected client.
    ///   - data: The raw bytes to send.
    ///   - priority: Message priority. Unused for data sends (no queuing support).
    ///   - queueIfDisconnected: If `true` and disconnected, logs a warning (data queuing unsupported).
    /// - Returns: `true` always — the return value reflects dispatch initiation, not delivery.
    @discardableResult
    public func send(
        to id: (any Identifiable)? = nil,
        _ data: Data,
        _ priority: Int,
        _ queueIfDisconnected: Bool
    ) -> Bool {
        serverDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            guard let clientID = id ?? self.lastID else {
                self.logger.error("🔴 No client ID provided and no last connected client available.")
                return
            }

            let key = self.makeKey(from: clientID)

            if let channel = self.connectedClients[key], channel.isActive {
                // Send immediately if client is connected - write raw bytes without string conversion
                var buffer = channel.allocator.buffer(
                    capacity: max(self.configuration.bufferSize, data.count))
                buffer.writeBytes(data)

                channel.writeAndFlush(buffer, promise: nil)
                self.logger.debug("🔵 Data sent to client \(key): \(data.count) bytes")
                self.connectionCountByClient[key] = (self.connectionCountByClient[key] ?? 0) + 1
            } else if queueIfDisconnected {
                // MessageQueue only supports String content - Data queuing not supported
                self.logger.warning(
                    "⚠️ Data queuing not supported. Message queue only accepts String content.")
            } else {
                self.logger.error(
                    "🔴 Client \(key) is not connected and message queuing is disabled.")
            }
        }
        return true
    }

    /// Fire-and-forget text send to a specific client. Returns immediately; does not wait
    /// for the write to flush.
    ///
    /// Use this for newline-delimited text protocols where you don't need delivery
    /// confirmation. A `\n` terminator is appended automatically. If the client is
    /// temporarily disconnected, the message can be queued for delivery on reconnect.
    ///
    /// **When to use `send(to:_:String:_:_:)` vs `send(confirming:to:)` with String:**
    /// - Use this overload for high-throughput or best-effort sends, or when the call site
    ///   is non-async and you cannot `await`. Queuing on disconnect is available here only.
    /// - Use `send(confirming: String, to:)` when you need to `await` delivery confirmation
    ///   or surface a write error to the caller. That overload does not queue on disconnect.
    ///
    /// **String vs Data:**
    /// - Use this overload for ASCII / UTF-8 text protocols. A `\n` delimiter is appended
    ///   and queuing is supported when `queueIfDisconnected` is `true`.
    /// - Use `send(to:_:Data:_:_:)` for binary protocols where appending a newline would
    ///   corrupt the payload. Note that Data sends do not support offline queuing.
    ///
    /// - Parameters:
    ///   - id: The target client ID. If `nil`, targets the most recently connected client.
    ///   - message: The UTF-8 string to send. A `\n` terminator is appended automatically.
    ///   - priority: Queue priority (higher = dequeued first). Ignored when client is connected.
    ///   - queueIfDisconnected: If `true` and the client is disconnected, the message is
    ///     queued for delivery on reconnect. If `false`, the message is dropped with an error log.
    /// - Returns: `true` always — the return value reflects dispatch initiation, not delivery.
    @discardableResult
    public func send(
        to id: (any Identifiable)? = nil,
        _ message: String,
        _ priority: Int = 0,
        _ queueIfDisconnected: Bool = true
    ) -> Bool {
        serverDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            guard let clientID = id ?? self.lastID else {
                self.logger.error("🔴 No client ID provided and no last connected client available.")
                return
            }

            let key = self.makeKey(from: clientID)

            if let channel = self.connectedClients[key], channel.isActive {
                // Send immediately if client is connected
                var buffer = channel.allocator.buffer(
                    capacity: max(self.configuration.bufferSize, message.utf8.count + 1)
                )
                buffer.writeString(message + "\n")
                channel.writeAndFlush(buffer, promise: nil)

                self.logger.debug("🔵 Sent message to client \(key): \(message)")
                self.connectionCountByClient[key] = (self.connectionCountByClient[key] ?? 0) + 1
            } else if queueIfDisconnected {
                // Queue for later delivery if client is disconnected
                let queuedMessage = MessageQueue.QueuedMessage(
                    content: message,
                    priority: priority,
                    targetID: String(describing: key)
                )

                // Ensure we have a message queue for this client
                if self.clientMessageQueues[key] == nil {
                    let queueConfig = MessageQueue.Configuration(
                        maxQueueSize: self.configuration.clientMessageQueueSize,
                        persistToDisk: false,
                        messageExpirationTime: self.configuration.clientMessageExpirationTime,
                        persistencePath: nil
                    )
                    self.clientMessageQueues[key] = MessageQueue(configuration: queueConfig)
                }

                if self.clientMessageQueues[key]?.enqueue(queuedMessage) == true {
                    self.logger.info("📥 Message queued for client \(key): \(message)")
                } else {
                    self.logger.warning(
                        "⚠️ Failed to queue message for client \(key) (queue full): \(message)")
                }
            } else {
                self.logger.error(
                    "🔴 Client \(key) is not connected and message queuing is disabled.")
            }
        }
        return true
    }

    /// Confirmed text send to a specific client. Suspends until the write is flushed to the
    /// kernel, then resumes. Throws on connection failure or write error.
    ///
    /// Use this when you need to know that the bytes left the process before continuing —
    /// for example, in a request/response flow where the next step depends on delivery.
    /// A `\n` terminator is appended automatically.
    ///
    /// **When to use `send(confirming:to:)` with String vs `send(to:_:String:_:_:)`:**
    /// - Use this overload when the call site is `async` and delivery confirmation or
    ///   error propagation is required.
    /// - Use `send(to:_:String:_:_:)` for fire-and-forget sends, non-async call sites,
    ///   or when you want the message queued if the client is temporarily disconnected
    ///   (offline queuing is only available on the non-confirming overload).
    ///
    /// **String vs Data:**
    /// - Use this overload for UTF-8 text protocols; `\n` is appended automatically.
    /// - Use `send(confirming: Data, to:)` for binary payloads where a newline would
    ///   corrupt the data. No delimiter is appended in that overload.
    ///
    /// - Parameters:
    ///   - message: The UTF-8 string to send. A `\n` terminator is appended automatically.
    ///   - id: The client to send to. If `nil`, targets the most recently connected client.
    /// - Throws: `SocketHandlerError.sendFailed` if the client is not connected or the write fails.
    public func send(confirming message: String, to id: (any Identifiable)? = nil) async throws {
        try await _sendConfirming(to: id) { allocator, bufferSize in
            var buf = allocator.buffer(capacity: max(bufferSize, message.utf8.count + 1))
            buf.writeString(message + "\n")
            return buf
        }
    }

    /// Confirmed binary send to a specific client. Suspends until the write is flushed to
    /// the kernel, then resumes. Throws on connection failure or write error.
    ///
    /// Use this when you need delivery confirmation for binary payloads — for example,
    /// when sending packed structs or binary-framed protocol messages and the next step
    /// depends on successful dispatch. No delimiter is appended; bytes are written as-is.
    ///
    /// **When to use `send(confirming:to:)` with Data vs `send(to:_:Data:_:_:)`:**
    /// - Use this overload when the call site is `async` and you need to `await` delivery
    ///   or propagate a write error.
    /// - Use `send(to:_:Data:_:_:)` for fire-and-forget binary sends or non-async call
    ///   sites. Note: neither Data overload supports offline queuing.
    ///
    /// **Data vs String:**
    /// - Use this overload for binary protocols, packed structs, or any payload where
    ///   appending a newline would corrupt the data. No delimiter is added.
    /// - Use `send(confirming: String, to:)` for UTF-8 text protocols; that overload
    ///   appends `\n` automatically.
    ///
    /// - Parameters:
    ///   - data: The raw bytes to send. Written to the channel as-is with no delimiter.
    ///   - id: The client to send to. If `nil`, targets the most recently connected client.
    /// - Throws: `SocketHandlerError.sendFailed` if the client is not connected or the write fails.
    public func send(confirming data: Data, to id: (any Identifiable)? = nil) async throws {
        try await _sendConfirming(to: id) { allocator, bufferSize in
            var buf = allocator.buffer(capacity: max(bufferSize, data.count))
            buf.writeBytes(data)
            return buf
        }
    }

    private func _sendConfirming(
        to id: (any Identifiable)?,
        _ makeBuffer: @escaping @Sendable (ByteBufferAllocator, Int) -> ByteBuffer
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            serverDispatchQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(
                        throwing: SocketHandlerError.sendFailed(message: "Server deallocated"))
                    return
                }
                guard let clientID = id ?? self.lastID else {
                    continuation.resume(
                        throwing: SocketHandlerError.sendFailed(message: "No client ID available"))
                    return
                }
                let key = self.makeKey(from: clientID)
                guard let channel = self.connectedClients[key], channel.isActive else {
                    continuation.resume(
                        throwing: SocketHandlerError.sendFailed(
                            message: "Client \(String(describing: key)) is not connected"
                        )
                    )
                    return
                }
                let buffer = makeBuffer(channel.allocator, self.configuration.bufferSize)
                channel.writeAndFlush(buffer).whenComplete { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Stops the server from accepting new connections while keeping existing connections active.
    ///
    /// This method closes the listener channel, preventing new client connections,
    /// but does not disconnect existing clients. To fully shut down the server
    /// and disconnect all clients, use `shutdown()` instead.
    ///
    /// - Note: This method executes asynchronously on the server's dispatch queue.
    ///         The `serverConnectionStatePublisher` will emit `.off` after the listener is closed.
    ///         If no listener is active, this method will log a warning and return early.
    public func stopListening() {
        serverDispatchQueue.async { [weak self] in
            guard let self = self else { return }

            guard let listener = self.listenerChannel else {
                self.logger.info("🟡 stopListening() called, but no active listenerChannel.")
                return
            }

            listener.close().whenComplete { [weak self] result in
                guard let self = self else { return }

                self.serverDispatchQueue.async {
                    switch result {
                    case .success:
                        self.logger.info("🟢 Listener channel closed.")
                    case .failure(let error):
                        self.logger.error("🔴 Failed to close listener channel: \(error)")
                    }
                }
            }

            self.listenerChannel = nil
            self.serverConnectionStatePublisher.send(.off)
        }
    }

    /// Performs a complete shutdown of the server and releases all resources.
    ///
    /// This method performs the following operations in sequence:
    /// 1. Sets the connection state to `.shuttingDown`
    /// 2. Closes the listener channel (stops accepting new connections)
    /// 3. Closes all active client connections
    /// 4. Shuts down the event loop group (if owned by this server instance)
    /// 5. Sets the connection state to `.off`
    ///
    /// - Note: This method blocks until all shutdown operations are complete.
    ///         It uses a semaphore to ensure synchronous completion of the asynchronous shutdown process.
    ///         After calling this method, the server instance should not be used for further operations.
    public func shutdown() {
        let semaphore = DispatchSemaphore(value: 0)

        serverDispatchQueue.async { [weak self] in
            guard let self = self else {
                semaphore.signal()
                return
            }

            self.serverConnectionStatePublisher.send(.shuttingDown)

            self.closeListener()
            self.closeAllClients()
            self.shutdownEventLoopIfNeeded()

            self.serverConnectionStatePublisher.send(.off)
            semaphore.signal()
        }

        semaphore.wait()
    }

    // MARK: - Private Helpers

    /// Sets up a newly connected client channel with the necessary handlers.
    ///
    /// This method configures the channel pipeline for a new client connection by:
    /// 1. Generating a unique client ID
    /// 2. Storing the client in the connected clients dictionary
    /// 3. Setting up connection state monitoring
    /// 4. Adding string message handling and connection state handlers to the pipeline
    ///
    /// - Parameters:
    ///   - channel: The NIO channel representing the client connection.
    ///   - messageHandler: The message handler to process incoming messages from this client.
    ///
    /// - Returns: An EventLoopFuture that completes when the channel setup is finished.
    ///
    /// - Note: If setup fails, the future will fail with the encountered error.
    private func setupChildChannel(
        _ channel: Channel,
        messageHandler: MessageReceivable
    )
        -> EventLoopFuture<Void>
    {
        // Approximate max-connections guard. This read races with serverDispatchQueue mutations
        // by a narrow window, but blocking the event loop with sync is worse. Over-acceptance
        // of one extra connection in a race is acceptable for this soft limit.
        if connectedClients.count >= configuration.maxConnections {
            logger.warning(
                "🔴 Maximum connections (\(configuration.maxConnections)) reached. Rejecting new connection."
            )

            // Send a rejection message and close the connection
            let rejectionMessage = "Server at maximum capacity. Connection rejected.\n"
            var buffer = channel.allocator.buffer(capacity: rejectionMessage.utf8.count)
            buffer.writeString(rejectionMessage)

            return channel.writeAndFlush(buffer).flatMap {
                channel.close()
            }.flatMapError { _ in
                // Even if write fails, still close the channel
                channel.close()
            }
        }

        let clientID = ClientID.uuid(UUID())
        let key = makeKey(from: clientID)

        // All mutable server state is owned by serverDispatchQueue; dispatch mutations there.
        // The pipeline setup below must stay on the event loop thread.
        serverDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.lastID = clientID
            self.connectedClients[key] = channel
            self.connectionQueue.append(key)
            self.connectionCountByClient[key] = 0

            let queueConfig = MessageQueue.Configuration(
                maxQueueSize: self.configuration.clientMessageQueueSize,
                persistToDisk: false,
                messageExpirationTime: self.configuration.clientMessageExpirationTime,
                persistencePath: nil
            )
            self.clientMessageQueues[key] = MessageQueue(configuration: queueConfig)

            self.addConnectedClient(key)
            self.sendQueuedMessages(for: key)
        }

        channel.closeFuture.whenComplete { [weak self] _ in
            self?.handleClientDisconnection(key)
        }

        do {
            let stateHandler = NIOServerConnectionStateHandler(
                logger: self.logger,
                onStateChange: { [weak self] state in
                    guard let self = self else { return }
                    self.logger.info("🔁 Client \(clientID) state changed: \(state)")
                    self.serverConnectionStatePublisher.send(.activeConnections)
                }
            )

            let stringHandler = NIOStringHandler(
                self.logger,
                channel.eventLoop,
                messageHandler,
                tokenizer: self.configuration.tokenizer,
                maxBufferSize: self.configuration.maxCumulationBufferSize
            )

            try channel.pipeline.syncOperations.addHandler(stringHandler)
            try channel.pipeline.syncOperations.addHandler(stateHandler)

            return channel.eventLoop.makeSucceededFuture(())
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

    /// Handles the disconnection of a client.
    ///
    /// This method performs cleanup when a client disconnects by:
    /// 1. Removing the client from the connected clients dictionary
    /// 2. Updating the connected clients publisher
    /// 3. Clearing the last client ID if it matches the disconnected client
    /// 4. Logging the disconnection event
    ///
    /// - Parameter key: The unique identifier key of the client that disconnected.
    ///
    /// - Note: This method executes on the server's dispatch queue to ensure thread safety.
    private func handleClientDisconnection(_ key: AnyHashable) {
        let keyDescription = String(describing: key)
        serverDispatchQueue.async {
            self.connectedClients.removeValue(forKey: key)
            self.removeConnectedClient(key)

            // Clean up connection pool management state
            if let index = self.connectionQueue.firstIndex(of: key) {
                self.connectionQueue.remove(at: index)
            }
            self.connectionCountByClient.removeValue(forKey: key)

            // Note: We don't remove the message queue here to preserve offline messages
            // The queue will be cleaned up naturally through expiration or when the client reconnects

            if let lastID = self.lastID, self.makeKey(from: lastID) == key {
                // Set last ID to nil - we can't easily convert AnyHashable back to Identifiable
                self.lastID = nil
            }
            self.logger.info("🟢 Client \(keyDescription) disconnected")
        }
    }

    /// Adds a client ID to the set of connected clients and updates publishers.
    ///
    /// This method updates both the connected clients publisher and the server connection state publisher
    /// to reflect the new client connection.
    ///
    /// - Parameter key: The unique identifier key of the newly connected client.
    ///
    /// - Note: The server connection state will be updated to `.activeConnections` to indicate
    ///         that the server now has active client connections.
    private func addConnectedClient(_ key: AnyHashable) {
        var current = connectedClientIDsPublisher.value
        current.insert(key)
        connectedClientIDsPublisher.send(current)

        serverConnectionStatePublisher.send(.activeConnections)
    }

    /// Removes a client ID from the set of connected clients and updates publishers.
    ///
    /// This method updates the connected clients publisher and adjusts the server connection state
    /// based on whether any clients remain connected.
    ///
    /// - Parameter key: The unique identifier key of the client to remove.
    ///
    /// - Note: If no clients remain connected after removal, the server connection state
    ///         will be updated to `.listening` to indicate the server is waiting for connections.
    private func removeConnectedClient(_ key: AnyHashable) {
        var current = connectedClientIDsPublisher.value
        current.remove(key)
        connectedClientIDsPublisher.send(current)

        if connectedClients.isEmpty {
            serverConnectionStatePublisher.send(.listening)
        }
    }

    /// Closes the listener channel if it exists.
    ///
    /// This method synchronously closes the listener channel and cleans up the reference.
    /// It's typically called during server shutdown to stop accepting new connections.
    ///
    /// - Note: If closing the listener fails, a warning is logged but the operation continues.
    ///         The listener channel reference is set to nil regardless of the close operation result.
    private func closeListener() {
        if let listener = self.listenerChannel {
            listener.close().whenComplete { [weak self] result in
                switch result {
                case .success:
                    self?.logger.info("🟢 Listener channel closed during shutdown.")
                case .failure(let error):
                    self?.logger.warning("⚠️ Error closing listener channel: \(error)")
                }
            }
            self.listenerChannel = nil
        }
    }

    /// Closes all active client connections and clears the client tracking data structures.
    ///
    /// This method iterates through all connected clients, closes their channels synchronously,
    /// and then clears the connected clients dictionary and updates the publisher.
    ///
    /// - Note: If closing individual client connections fails, warnings are logged but the operation continues.
    ///         This ensures that the server can complete shutdown even if some client disconnections fail.
    private func closeAllClients() {
        for (id, channel) in self.connectedClients {
            let idDescription = String(describing: id)
            channel.close().whenComplete { [weak self] result in
                switch result {
                case .success:
                    self?.logger.info("🟢 Closed connection to client \(idDescription)")
                case .failure(let error):
                    self?.logger.warning("⚠️ Error closing client \(idDescription): \(error)")
                }
            }
        }

        self.connectedClients.removeAll()
        self.connectionQueue.removeAll()
        self.connectionCountByClient.removeAll()
        self.clientMessageQueues.removeAll()
        self.connectedClientIDsPublisher.send([])
    }

    /// Gets connection statistics for monitoring and debugging.
    ///
    /// - Returns: A dictionary containing connection statistics including total connections,
    ///           connection limit, and per-client message counts.
    public func getConnectionStats() -> [String: Any] {
        var stats: [String: Any] = [:]

        serverDispatchQueue.sync {
            stats["totalConnections"] = connectedClients.count
            stats["maxConnections"] = configuration.maxConnections
            stats["connectionUtilization"] =
                Double(connectedClients.count) / Double(configuration.maxConnections)
            stats["connectionQueue"] = connectionQueue
            stats["messageCountsByClient"] = connectionCountByClient
            stats["oldestConnection"] = connectionQueue.first
            stats["newestConnection"] = connectionQueue.last
        }

        return stats
    }

    /// Disconnects the oldest connected client to make room for new connections.
    ///
    /// This method can be used when implementing custom connection management policies.
    /// It disconnects the client that has been connected the longest.
    ///
    /// - Returns: The ID key of the disconnected client, or nil if no clients are connected.
    @discardableResult
    public func disconnectOldestClient() -> AnyHashable? {
        var disconnectedClient: AnyHashable?

        serverDispatchQueue.sync {
            guard let oldestClientKey = connectionQueue.first,
                let channel = connectedClients[oldestClientKey]
            else {
                return
            }

            disconnectedClient = oldestClientKey
            let keyDescription = String(describing: oldestClientKey)
            logger.info(
                "🔄 Disconnecting oldest client \(keyDescription) to make room for new connections")

            channel.close().whenComplete { [weak self] result in
                switch result {
                case .success:
                    self?.logger.info("🟢 Successfully disconnected oldest client \(keyDescription)")
                case .failure(let error):
                    self?.logger.warning(
                        "⚠️ Error disconnecting oldest client \(keyDescription): \(error)")
                }
            }
        }

        return disconnectedClient
    }

    /// Sends queued messages for a specific client when they reconnect.
    ///
    /// - Parameter key: The ID key of the client to send queued messages to.
    private func sendQueuedMessages(for key: AnyHashable) {
        guard let channel = connectedClients[key], channel.isActive,
            let messageQueue = clientMessageQueues[key]
        else {
            return
        }

        let queueCount = messageQueue.count
        guard queueCount > 0 else { return }

        logger.info("📤 Sending \(queueCount) queued messages to client \(key)")

        while let queuedMessage = messageQueue.dequeue() {
            guard channel.isActive else {
                // If connection is lost while sending queued messages, re-queue the message
                messageQueue.enqueue(queuedMessage)
                break
            }

            var buffer = channel.allocator.buffer(
                capacity: max(configuration.bufferSize, queuedMessage.content.utf8.count + 1)
            )
            buffer.writeString(queuedMessage.content + "\n")

            channel.writeAndFlush(buffer, promise: nil)
            logger.debug("📤 Queued message sent to client \(key): \(queuedMessage.content)")
            connectionCountByClient[key] = (connectionCountByClient[key] ?? 0) + 1
        }

        let remainingCount = messageQueue.count
        if remainingCount == 0 {
            logger.info("✅ All queued messages sent to client \(key)")
        } else {
            logger.warning(
                "⚠️ \(remainingCount) messages remain in queue for client \(key) after connection lost"
            )
        }
    }

    /// Gets the number of queued messages for a specific client.
    ///
    /// - Parameter clientID: The ID of the client.
    /// - Returns: The number of queued messages for the client.
    public func getQueuedMessageCount(for clientID: any Identifiable) -> Int {
        let key = makeKey(from: clientID)
        return serverDispatchQueue.sync {
            return clientMessageQueues[key]?.count ?? 0
        }
    }

    /// Clears all queued messages for a specific client.
    ///
    /// - Parameter clientID: The ID of the client.
    /// - Returns: The number of messages that were cleared.
    @discardableResult
    public func clearQueuedMessages(for clientID: any Identifiable) -> Int {
        let key = makeKey(from: clientID)
        return serverDispatchQueue.sync {
            guard let messageQueue = clientMessageQueues[key] else { return 0 }
            let count = messageQueue.count
            messageQueue.clear()
            logger.info("🗑️ Cleared \(count) queued messages for client \(key)")
            return count
        }
    }

    /// Gets statistics about all client message queues.
    ///
    /// - Returns: A dictionary mapping client IDs to their queued message counts.
    public func getAllQueueStats() -> [String: Int] {
        return serverDispatchQueue.sync {
            var stats: [String: Int] = [:]
            for (clientID, queue) in clientMessageQueues {
                stats[String(describing: clientID)] = queue.count
            }
            return stats
        }
    }

    /// Shuts down the event loop group if this server instance owns it.
    ///
    /// This method performs a graceful shutdown of the event loop group, but only if the server
    /// created and owns the event loop group. If an external event loop group was provided during
    /// initialization, this method does nothing, leaving lifecycle management to the external owner.
    ///
    /// - Note: If the shutdown fails, an error is logged but the operation continues.
    ///         This ensures that server shutdown completes even if event loop shutdown encounters issues.
    private func shutdownEventLoopIfNeeded() {
        guard ownsEventLoopGroup else { return }

        do {
            try group.syncShutdownGracefully()
            logger.info("🟢 EventLoopGroup shut down.")
        } catch {
            logger.error("🔴 Failed to shut down EventLoopGroup: \(error)")
        }
    }
}

// MARK: - MessageReceivable Conformance

extension NIOSocketHandlerServer {
    /// Assigns a handler for incoming string messages.
    ///
    /// - Parameter handler: The handler to receive string messages, or nil to clear.
    public func setStringMessageHandler(_ handler: (@Sendable (String) -> Void)?) {
        serverDispatchQueue.async { [weak self] in
            self?.stringMessageHandler = handler
        }
    }

    /// Assigns a handler for incoming data.
    ///
    /// - Parameter handler: The handler to receive data, or nil to clear.
    public func setDataMessageHandler(_ handler: (@Sendable (Data) -> Void)?) {
        serverDispatchQueue.async { [weak self] in
            self?.dataMessageHandler = handler
        }
    }

    /// Handles an incoming message asynchronously.
    ///
    /// This method is called by the underlying NIO handler when a message is received from any client.
    /// It increments the messages received counter and invokes the registered string message handler.
    ///
    /// - Parameter message: The message to be handled, represented as a `String`.
    public func handleMessage(_ message: String) async {
        serverDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.messagesReceived += 1
            self.stringMessageHandler?(message)
        }
    }
}
