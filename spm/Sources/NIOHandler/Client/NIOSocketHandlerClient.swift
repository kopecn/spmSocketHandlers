import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import OpenCombine
import SocketCommon

/// A TCP socket client handler built using SwiftNIO.
///
/// This class manages asynchronous TCP socket client operations including:
/// - Connecting to a remote server
/// - Sending and receiving string-based messages
/// - Publishing connection state changes
/// - Managing its own event loop group (unless externally provided)
///
/// It provides publishers to observe:
/// - Current connection state (connecting, connected, disconnected, error)
/// - Connection status via `isConnected` property
///
/// Use `connect(host:port:messageHandler:)` to establish a connection,
/// `send(_:)` to send messages, `disconnect()` to close the connection,
/// and `shutdown()` to stop the client and release resources cleanly.
///
/// - Important: Call `shutdown()` explicitly to clean up resources when done.
///              The deinitializer will log a warning if shutdown wasn't called.
public class NIOSocketHandlerClient: @unchecked Sendable {
    // MARK: - Public Properties

    /// The name identifier for this client instance.
    public let name: String

    /// The configuration for this client instance.
    public let configuration: ClientConfiguration

    // MARK: - Internal Properties

    /// Logger instance used for logging client events and messages.
    let logger: Logger

    private let socketDispatchQueue: DispatchQueue
    private let group: EventLoopGroup
    private let ownsEventLoopGroup: Bool

    /// Only used for logging/debugging
    private var host: String?
    private var port: Int?

    /// Retry management state
    private var retryCount: Int = 0
    private var retryTimer: DispatchSourceTimer?
    private var lastMessageHandler: MessageHandling?

    /// Message queue for handling messages when disconnected
    private let messageQueue: MessageQueue

    /// Metrics tracking
    private var messagesSent: Int = 0
    private var messagesReceived: Int = 0
    private var connectionAttempts: Int = 0
    private var successfulConnections: Int = 0
    private var connectionStartTime: Date?
    private var lastConnectionTime: Date?

    // MARK: - State

    /// Publishes updates about the current connection state of the socket client.
    ///
    /// This publisher emits values of type `SocketClientConnectionState`, indicating whether the client is
    /// connecting, connected, disconnected, or in an error state. Subscribers can use this to react to
    /// changes in the client's connection state in real time.
    public let connectionStatePublisher = CurrentValueSubject<SocketClientConnectionState, Never>(
        .disconnected
    )

    /// A computed property that returns `true` if the client is currently connected to a server.
    ///
    /// This is a convenience property that checks the current value of `connectionStatePublisher`
    /// to determine if the connection state is `.connected`.
    public var isConnected: Bool {
        if case .connected = connectionStatePublisher.value {
            return true
        }
        return false
    }

    private var channel: Channel?

    // MARK: - Initialization

    /// Initializes a new `NIOSocketHandlerClient` instance.
    ///
    /// - Parameters:
    ///   - name: The name identifier for this client instance. Defaults to `"nio-handler-client"`.
    ///   - configuration: The configuration for this client instance. Defaults to `ClientConfiguration.default`.
    ///   - eventLoopGroup: An optional external event loop group. If `nil`, a new `MultiThreadedEventLoopGroup` will be created.
    ///   - dispatchQueue: An optional dispatch queue for client operations. If `nil`, a new queue will be created.
    ///
    /// - Note:
    ///   - If an external event loop group is provided, the client will not shut it down during cleanup.
    ///     The caller is responsible for managing the lifecycle of the external event loop group.
    public init(
        name: String = "nio-handler-client",
        configuration: ClientConfiguration = .default,
        eventLoopGroup: EventLoopGroup? = nil,
        dispatchQueue: DispatchQueue? = nil
    ) {
        self.name = name
        self.configuration = configuration
        let label = "com.socket-handlers.nio-handler.\(name)"
        self.logger = Logger(label: label)
        self.socketDispatchQueue = dispatchQueue ?? DispatchQueue(label: label, qos: configuration.qosClass.dispatchQoS)

        // Initialize message queue using configuration values
        let queueConfig = MessageQueue.Configuration(
            maxQueueSize: configuration.messageQueueSize,
            persistToDisk: false,
            messageExpirationTime: configuration.messageExpirationTime,
            persistencePath: nil
        )
        self.messageQueue = MessageQueue(configuration: queueConfig)

        if let group = eventLoopGroup {
            self.group = group
            self.ownsEventLoopGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            self.ownsEventLoopGroup = true
        }
    }

    deinit {
        logger.info(
            "🟢 NIOSocketHandlerClient deinitialized. Call shutdown() explicitly to clean up."
        )
    }

    // MARK: - Public API

    /// Performs a complete shutdown of the client and releases all resources.
    ///
    /// This method performs the following operations in sequence:
    /// 1. Disconnects from the server if connected
    /// 2. Shuts down the event loop group (if owned by this client instance)
    ///
    /// - Throws: An error if the event loop group shutdown fails.
    ///
    /// - Note: This method blocks until all shutdown operations are complete.
    ///         It uses a semaphore to ensure synchronous completion of the asynchronous shutdown process.
    ///         After calling this method, the client instance should not be used for further operations.
    public func shutdown() throws {
        // We do the disconnect and shutdown synchronously to avoid races or queue starvation.
        var caughtError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        socketDispatchQueue.async { [weak self] in
            guard let self = self else {
                semaphore.signal()
                return
            }
            self.disconnectInternal {
                semaphore.signal()
            }
            self.cancelRetryTimer()
        }

        semaphore.wait()

        if ownsEventLoopGroup {
            do {
                try group.syncShutdownGracefully()
                logger.info("🟢 \(self) EventLoopGroup shut down.")
            } catch {
                caughtError = error
            }
        }
        if let error = caughtError {
            throw error
        }
    }

    /// Initiates a connection to the specified server.
    ///
    /// This method asynchronously connects to the server at the given host and port,
    /// then begins handling incoming messages using the provided message handler.
    ///
    /// - Parameters:
    ///   - host: The hostname or IP address of the server to connect to.
    ///   - port: The port number on which the server is listening.
    ///   - messageHandler: A message handler conforming to `MessageHandling` protocol
    ///                     that will process incoming messages from the server.
    ///
    /// - Note:
    ///   - This method executes asynchronously on the client's dispatch queue.
    ///   - The `connectionStatePublisher` will emit `.connecting` immediately,
    ///     followed by `.connected` upon successful connection, or `.error(err:)` if connection fails.
    ///   - Connection state changes can be observed through the `connectionStatePublisher`.
    public func connect(
        host: String,
        port: Int,
        messageHandler: MessageHandling
    ) {
        socketDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self._connect(host: host, port: port, messageHandler: messageHandler)
        }
    }

    /// Initiates a connection to the specified server with completion handling.
    ///
    /// This method asynchronously connects to the server at the given host and port,
    /// then calls the completion handler with the result of the connection attempt.
    ///
    /// - Parameters:
    ///   - host: The hostname or IP address of the server to connect to.
    ///   - port: The port number on which the server is listening.
    ///   - messageHandler: A message handler conforming to `MessageHandling` protocol
    ///                     that will process incoming messages from the server.
    ///   - completion: A completion handler called with the result of the connection attempt.
    ///                 `.success(())` indicates successful connection, `.failure(Error)` indicates failure.
    ///
    /// - Note:
    ///   - This method executes asynchronously on the client's dispatch queue.
    ///   - The completion handler is called on the client's dispatch queue.
    ///   - Connection state changes can also be observed through the `connectionStatePublisher`.
    public func connect(
        host: String,
        port: Int,
        messageHandler: MessageHandling,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        socketDispatchQueue.async { [weak self] in
            guard let self = self else {
                completion(.failure(SocketHandlerError.internalFailure(message: "Client deallocated")))
                return
            }
            self._connect(host: host, port: port, messageHandler: messageHandler, completion: completion)
        }
    }

    private func _connect(
        host: String,
        port: Int,
        messageHandler: MessageHandling,
        completion: (@Sendable (Result<Void, Error>) -> Void)? = nil
    ) {
        logger.info("🟢 Attempting to connect to \(host):\(port)")
        connectionStatePublisher.send(.connecting)

        // Track connection attempt
        connectionAttempts += 1
        connectionStartTime = Date()

        // Store the message handler for potential retry attempts
        self.lastMessageHandler = messageHandler

        let stateHandler = NIOClientConnectionStateHandler(
            logger: self.logger,
            onStateChange: { [weak self] state in
                guard let self = self else { return }
                self.socketDispatchQueue.async {
                    self.onStateChange(state: state)
                }
            }
        )
        let logger = self.logger

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [weak self] channel in

                do {
                    let handler = NIOStringHandler(
                        logger,
                        channel.eventLoop,
                        messageHandler
                    )

                    try channel.pipeline.syncOperations.addHandler(handler)
                    try channel.pipeline.syncOperations.addHandler(stateHandler)

                    return channel.eventLoop.makeSucceededFuture(())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        bootstrap.connect(host: host, port: port).whenComplete { [weak self] (result: Result<Channel, Error>) in
            guard let self = self else {
                completion?(.failure(SocketHandlerError.internalFailure(message: "Client deallocated")))
                return
            }

            self.socketDispatchQueue.async {
                switch result {
                case .success(let connectedChannel):
                    self.setChannel(connectedChannel)
                    self.host = host
                    self.port = port
                    self.successfulConnections += 1
                    self.lastConnectionTime = Date()
                    self.logger.info("🟢 Connected to \(host):\(port)")
                    completion?(.success(()))
                case .failure(let error):
                    self.setChannel(nil)
                    self.logger.error("🔴 Connection failed: \(error)")
                    self.connectionStatePublisher.send(.error(err: error))
                    completion?(.failure(error))
                }
            }
        }
    }

    /// Disconnects from the currently connected server.
    ///
    /// This method closes the connection to the server and updates the connection state.
    /// The connection can be re-established later by calling `connect(host:port:messageHandler:)` again.
    ///
    /// - Note:
    ///   - This method executes asynchronously on the client's dispatch queue.
    ///   - The `connectionStatePublisher` will emit `.disconnecting` followed by `.disconnected`.
    ///   - If no connection is active, this method safely does nothing.
    public func disconnect() {
        socketDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.disconnectInternal(completion: nil)
        }
    }

    /// Disconnect logic isolated internally, completion called after disconnect finished.
    private func disconnectInternal(completion: (@Sendable () -> Void)?) {
        // Cancel any pending reconnection attempts
        cancelRetryTimer()

        guard let currentChannel = self.channel else {
            logger.info("🟢 Disconnect called but channel was nil.")
            completion?()
            return
        }
        logger.info("🟢 Disconnecting")
        connectionStatePublisher.send(.disconnecting)

        // Close asynchronously without blocking the queue.
        currentChannel.close().whenComplete { [weak self] result in
            guard let self = self else {
                completion?()
                return
            }
            self.socketDispatchQueue.async {
                self.setChannel(nil)
                self.connectionStatePublisher.send(.disconnected)
                self.logger.info("🟢 Disconnected from server.")
                completion?()
            }
        }
    }

    /// Sends a string message to the connected server.
    ///
    /// - Parameters:
    ///   - message: The string message to send to the server.
    ///   - priority: The priority of the message (higher values have higher priority). Defaults to 0.
    ///   - queueIfDisconnected: Whether to queue the message if not connected. Defaults to true.
    ///
    /// - Note:
    ///   - This method executes asynchronously on the client's dispatch queue.
    ///   - Messages are automatically terminated with a newline character.
    ///   - If the client is not connected and queueIfDisconnected is true, the message will be queued for later delivery.
    ///   - If the client is not connected and queueIfDisconnected is false, an error will be logged.
    public func send(_ message: String, priority: Int = 0, queueIfDisconnected: Bool = true) {
        socketDispatchQueue.async { [weak self] in
            guard let self = self else { return }

            if let channel = self.channel, channel.isActive {
                // Send immediately if connected
                var buffer = channel.allocator.buffer(capacity: max(configuration.bufferSize, message.utf8.count + 1))
                buffer.writeString(message + "\n")

                channel.writeAndFlush(buffer, promise: nil)
                self.messagesSent += 1
                self.logger.debug("🔵 Message sent: \(message)")
            } else if queueIfDisconnected {
                // Queue for later delivery if disconnected
                let queuedMessage = MessageQueue.QueuedMessage(content: message, priority: priority)
                if self.messageQueue.enqueue(queuedMessage) {
                    self.logger.info("📥 Message queued for delivery when reconnected: \(message)")
                } else {
                    self.logger.warning("⚠️ Failed to queue message (queue full): \(message)")
                }
            } else {
                self.logger.error("🔴 Channel is not connected and message queuing is disabled")
            }
        }
    }

    /// Gets the current number of queued messages waiting to be sent.
    ///
    /// - Returns: The number of messages in the send queue.
    public var queuedMessageCount: Int {
        return messageQueue.count
    }

    /// Clears all queued messages.
    public func clearMessageQueue() {
        messageQueue.clear()
        logger.info("🗑️ Message queue cleared")
    }

    /// Gets current connection metrics.
    ///
    /// - Returns: A dictionary containing connection and message statistics.
    public func getMetrics() -> [String: Any] {
        return socketDispatchQueue.sync {
            var metrics: [String: Any] = [:]
            metrics["messagesSent"] = messagesSent
            metrics["messagesReceived"] = messagesReceived
            metrics["connectionAttempts"] = connectionAttempts
            metrics["successfulConnections"] = successfulConnections
            metrics["retryCount"] = retryCount
            metrics["queuedMessages"] = messageQueue.count
            metrics["isConnected"] = isConnected
            metrics["lastConnectionTime"] = lastConnectionTime?.timeIntervalSince1970

            if let startTime = connectionStartTime, isConnected {
                metrics["connectionDuration"] = Date().timeIntervalSince(startTime)
            }

            if connectionAttempts > 0 {
                metrics["connectionSuccessRate"] = Double(successfulConnections) / Double(connectionAttempts)
            }

            return metrics
        }
    }

    /// Resets all metrics counters.
    public func resetMetrics() {
        socketDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.messagesSent = 0
            self.messagesReceived = 0
            self.connectionAttempts = 0
            self.successfulConnections = 0
            self.connectionStartTime = nil
            self.lastConnectionTime = nil
            self.logger.info("📊 Metrics have been reset")
        }
    }

    /// Resets the retry count and cancels any pending reconnection attempts.
    ///
    /// This method can be used to reset the client's retry state, allowing for a fresh
    /// start when reconnection attempts have been exhausted or when you want to
    /// restart the retry sequence.
    ///
    /// - Note: This method executes asynchronously on the client's dispatch queue.
    public func resetRetryState() {
        socketDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.retryCount = 0
            self.cancelRetryTimer()
            self.logger.info("🔄 Retry state has been reset")
        }
    }

    private func onStateChange(state: SocketClientConnectionState) {
        connectionStatePublisher.send(state)

        // Handle automatic reconnection if enabled
        if case .error = state, configuration.enableAutoReconnect {
            scheduleReconnection()
        } else if case .disconnected = state, configuration.enableAutoReconnect {
            // Only retry if we were previously connected (not if we never connected)
            if retryCount > 0 || channel != nil {
                scheduleReconnection()
            }
        } else if case .connected = state {
            // Reset retry count on successful connection
            retryCount = 0
            cancelRetryTimer()

            // Send any queued messages
            sendQueuedMessages()
        }
    }

    private func setChannel(_ channel: Channel?) {
        self.channel = channel

        if let isActive = channel?.isActive {
            connectionStatePublisher.send(isActive ? .connected : .disconnected)
        } else {
            connectionStatePublisher.send(.disconnected)
        }

        // Handle channel close notification, ensure it runs on socketDispatchQueue
        channel?.closeFuture.whenComplete { [weak self] _ in
            guard let self = self else { return }
            self.socketDispatchQueue.async {
                self.connectionStatePublisher.send(.disconnected)
                self.channel = nil
            }
        }
    }

    /// Schedules a reconnection attempt based on the retry policy.
    private func scheduleReconnection() {
        guard configuration.enableAutoReconnect,
              let host = self.host,
              let port = self.port,
              let messageHandler = self.lastMessageHandler else {
            return
        }

        let policy = configuration.retryPolicy

        // Check if we've exceeded the maximum retry attempts
        if policy.maxRetries > 0 && retryCount >= policy.maxRetries {
            logger.warning("🔴 Maximum retry attempts (\(policy.maxRetries)) exceeded. Giving up.")
            return
        }

        retryCount += 1
        let delay = calculateRetryDelay(attempt: retryCount, policy: policy)

        logger.info("🔄 Scheduling reconnection attempt \(retryCount) in \(delay) seconds")

        cancelRetryTimer()

        retryTimer = DispatchSource.makeTimerSource(queue: socketDispatchQueue)
        retryTimer?.schedule(deadline: .now() + delay)
        retryTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.logger.info("🔄 Attempting reconnection (attempt \(self.retryCount))")
            self._connect(host: host, port: port, messageHandler: messageHandler)
        }
        retryTimer?.resume()
    }

    /// Calculates the delay for the next retry attempt based on the retry policy.
    private func calculateRetryDelay(attempt: Int, policy: RetryPolicy) -> TimeInterval {
        switch policy.strategy {
        case .exponentialBackoff:
            let delay = policy.baseDelay * pow(policy.backoffMultiplier, Double(attempt - 1))
            return min(delay, policy.maxDelay)
        case .fixedDelay:
            return policy.baseDelay
        }
    }

    /// Cancels any pending retry timer.
    private func cancelRetryTimer() {
        retryTimer?.cancel()
        retryTimer = nil
    }

    /// Sends all queued messages after reconnection.
    private func sendQueuedMessages() {
        guard let channel = self.channel, channel.isActive else { return }

        let queueCount = messageQueue.count
        guard queueCount > 0 else { return }

        logger.info("📤 Sending \(queueCount) queued messages")

        while let queuedMessage = messageQueue.dequeue() {
            guard channel.isActive else {
                // If connection is lost while sending queued messages, re-queue the message
                messageQueue.enqueue(queuedMessage)
                break
            }

            var buffer = channel.allocator.buffer(capacity: max(configuration.bufferSize, queuedMessage.content.utf8.count + 1))
            buffer.writeString(queuedMessage.content + "\n")

            channel.writeAndFlush(buffer, promise: nil)
            messagesSent += 1
            logger.debug("📤 Queued message sent: \(queuedMessage.content)")
        }

        let remainingCount = messageQueue.count
        if remainingCount == 0 {
            logger.info("✅ All queued messages sent successfully")
        } else {
            logger.warning("⚠️ \(remainingCount) messages remain in queue after connection lost")
        }
    }
}

extension NIOSocketHandlerClient: CustomStringConvertible {
    public var description: String {

        "\(name):\(String(describing: host)):\(String(describing: port)), state: \(connectionStatePublisher.value)"
    }
}
