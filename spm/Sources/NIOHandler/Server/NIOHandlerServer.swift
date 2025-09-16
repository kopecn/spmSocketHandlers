import Foundation
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
/// Use `listen(port:messageHandler:)` to start the server,
/// and `shutdown()` to stop it and release resources cleanly.
public final class NIOSocketHandlerServer {
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
    /// This publisher emits a `Set` of `ClientID` values representing all clients currently connected to the server.
    /// Subscribers can observe this publisher to be notified whenever clients connect or disconnect.
    public let connectedClientIDsPublisher = CurrentValueSubject<Set<ClientID>, Never>([])

    // MARK: - Internal Properties

    /// The name of the server instance.
    public let name: String

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
    private var connectedClients: [ClientID: Channel] = [:]

    /// The identifier of the most recently connected client.
    private var lastID: ClientID?

    /// Initializes a new `NIOSocketHandlerServer` instance.
    ///
    /// - Parameters:
    ///   - name: The name identifier for this server instance. Defaults to `"nio-handler-server"`.
    ///   - eventLoopGroup: An optional external event loop group. If `nil`, a new `MultiThreadedEventLoopGroup` will be created.
    ///   - serverDispatchQueue: An optional dispatch queue for server operations. If `nil`, a new queue will be created.
    ///
    /// - Note:
    ///   - If an external event loop group is provided, the server will not shut it down during cleanup.
    ///     The caller is responsible for managing the lifecycle of the external event loop group.
    public init(
        name: String = "nio-handler-server",
        eventLoopGroup: EventLoopGroup? = nil,
        serverDispatchQueue: DispatchQueue? = nil,
    ) {
        self.name = name
        self.logger = Logger(label: "com.socket-handlers.nio-handler.\(name)")
        self.serverDispatchQueue =
            serverDispatchQueue
            ?? DispatchQueue(
                label: "com.socket-handlers.nio-handler.\(name)",
                qos: .default
            )

        if let group = eventLoopGroup {
            self.group = group
            self.ownsEventLoopGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            self.ownsEventLoopGroup = true
        }
    }

    deinit {
        logger.info("NIOSocketHandlerServer deinitialized. Call shutdown() explicitly to clean up.")
    }

    // MARK: - Public API

    /// Starts the server listening on the specified port.
    ///
    /// This method binds the server to the default host (::1) and the specified port,
    /// then begins accepting incoming client connections asynchronously.
    ///
    /// - Parameters:
    ///   - port: The port number on which to listen for incoming connections.
    ///   - messageHandler: A message handler conforming to `MessageHandling` protocol
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
        messageHandler: MessageHandling,
        defaultHost: String = "::1"
    ) {
        serverDispatchQueue.async { [weak self] in
            guard let self = self else { return }

            self.logger.info("🟢 Starting server on [\(defaultHost)]:\(port)")

            let bootstrap = ServerBootstrap(group: self.group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { [weak self] channel in
                    guard let self = self else {
                        return channel.eventLoop.makeFailedFuture(
                            SocketHandlerError.internalFailure(message: "Server deallocated")
                        )
                    }
                    return self.setupChildChannel(channel, messageHandler: messageHandler)
                }

            do {
                self.listenerChannel = try bootstrap.bind(host: defaultHost, port: port).wait()
                self.serverConnectionStatePublisher.send(.listening)
                self.logger.info("🟢 Server is now listening on port \(port)")
            } catch {
                self.serverConnectionStatePublisher.send(.error(err: error))
                self.logger.error("🔴 Failed to bind server to port \(port): \(error)")
            }
        }
    }

    /// Sends a message to a specific client or the most recently connected client.
    ///
    /// - Parameters:
    ///   - message: The string message to send to the client.
    ///   - id: The specific client ID to send the message to. If nil, the message
    ///         will be sent to the most recently connected client.
    ///
    /// - Note: This method executes asynchronously on the server's dispatch queue.
    ///         If the specified client is not connected or no client ID is available,
    ///         an error will be logged and the message will not be sent.
    ///         Messages are automatically terminated with a newline character.
    public func send(_ message: String, to id: ClientID? = nil) {
        serverDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            guard let clientID = id ?? self.lastID else {
                self.logger.error("🔴 No client ID provided and no last connected client available.")
                return
            }
            guard let channel = self.connectedClients[clientID], channel.isActive else {
                self.logger.error("🔴 Channel for client \(clientID) is not connected.")
                return
            }

            var buffer = channel.allocator.buffer(capacity: message.utf8.count + 1)
            buffer.writeString(message + "\n")
            channel.writeAndFlush(buffer, promise: nil)

            self.logger.debug("🔵 Sent message to client \(clientID): \(message)")
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

            do {
                try listener.close().wait()
                self.logger.info("🟢 Listener channel closed.")
            } catch {
                self.logger.error("🔴 Failed to close listener channel: \(error)")
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
        messageHandler: MessageHandling
    )
        -> EventLoopFuture<Void>
    {
        let clientID = ClientID.uuid(UUID())
        self.lastID = clientID
        self.connectedClients[clientID] = channel
        self.addConnectedClient(clientID)

        channel.closeFuture.whenComplete { [weak self] _ in
            self?.handleClientDisconnection(clientID)
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

            let stringHandler = NIOStringHandler(self.logger, channel.eventLoop, messageHandler)

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
    /// - Parameter clientID: The unique identifier of the client that disconnected.
    ///
    /// - Note: This method executes on the server's dispatch queue to ensure thread safety.
    private func handleClientDisconnection(_ clientID: ClientID) {
        serverDispatchQueue.async {
            self.connectedClients.removeValue(forKey: clientID)
            self.removeConnectedClient(clientID)

            if self.lastID == clientID {
                self.lastID = nil
            }
            self.logger.info("🟢 Client \(clientID) disconnected")
        }
    }

    /// Adds a client ID to the set of connected clients and updates publishers.
    ///
    /// This method updates both the connected clients publisher and the server connection state publisher
    /// to reflect the new client connection.
    ///
    /// - Parameter id: The unique identifier of the newly connected client.
    ///
    /// - Note: The server connection state will be updated to `.activeConnections` to indicate
    ///         that the server now has active client connections.
    private func addConnectedClient(_ id: ClientID) {
        var current = connectedClientIDsPublisher.value
        current.insert(id)
        connectedClientIDsPublisher.send(current)

        serverConnectionStatePublisher.send(.activeConnections)
    }

    /// Removes a client ID from the set of connected clients and updates publishers.
    ///
    /// This method updates the connected clients publisher and adjusts the server connection state
    /// based on whether any clients remain connected.
    ///
    /// - Parameter id: The unique identifier of the client to remove.
    ///
    /// - Note: If no clients remain connected after removal, the server connection state
    ///         will be updated to `.listening` to indicate the server is waiting for connections.
    private func removeConnectedClient(_ id: ClientID) {
        var current = connectedClientIDsPublisher.value
        current.remove(id)
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
            do {
                try listener.close().wait()
                self.logger.info("🟢 Listener channel closed during shutdown.")
            } catch {
                self.logger.warning("⚠️ Error closing listener channel: \(error)")
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
            do {
                try channel.close().wait()
                self.logger.info("🟢 Closed connection to client \(id)")
            } catch {
                self.logger.warning("⚠️ Error closing client \(id): \(error)")
            }
        }

        self.connectedClients.removeAll()
        self.connectedClientIDsPublisher.send([])
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
