import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import OpenCombine
import SocketCommon

public class NIOSocketHandlerClient {
    // MARK: - Internal Properties

    let logger: Logger
    public let name: String

    private let socketDispatchQueue: DispatchQueue
    private let group: EventLoopGroup
    private let ownsEventLoopGroup: Bool

    /// Only used for logging/debugging
    private var host: String?
    private var port: Int?

    // MARK: - State

    public let connectionStatePublisher = CurrentValueSubject<SocketClientConnectionState, Never>(
        .disconnected)

    public var isConnected: Bool {
        if case .connected = connectionStatePublisher.value {
            return true
        }
        return false
    }

    private var channel: Channel?

    // MARK: - Initialization

    public init(
        name: String = "nio-handler-client",
        eventLoopGroup: EventLoopGroup? = nil,
        dispatchQueue: DispatchQueue? = nil
    ) {
        self.name = name
        let label = "com.socket-handlers.nio-handler.\(name)"
        self.logger = Logger(label: label)
        self.socketDispatchQueue = dispatchQueue ?? DispatchQueue(label: label, qos: .default)

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
            "🟢 NIOSocketHandlerClient deinitialized. Call shutdown() explicitly to clean up.")
    }

    // MARK: - Public API

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

    public func connect(
        host: String,
        port: Int,
        messageHandler: MessageHandling
    ) {
        socketDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self._connect(host: host, port: port, messageHandler: messageHandler)
            } catch {
                self.logger.error("🔴 Connect failed: \(error)")
                self.connectionStatePublisher.send(.error(err: error))
            }
        }
    }

    private func _connect(
        host: String,
        port: Int,
        messageHandler: MessageHandling
    ) throws {
        logger.info("🟢 Attempting to connect to \(host):\(port)")
        connectionStatePublisher.send(.connecting)

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
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
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

        do {
            let connectedChannel = try bootstrap.connect(host: host, port: port).wait()
            setChannel(connectedChannel)
            self.host = host
            self.port = port
            logger.info("🟢 \(self) Connected to \(host):\(port)")
        } catch {
            setChannel(nil)
            logger.error("🔴 \(self) Connection failed: \(error)")
            connectionStatePublisher.send(.error(err: error))
            throw error
        }
    }

    public func disconnect() {
        socketDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.disconnectInternal(completion: nil)
        }
    }

    /// Disconnect logic isolated internally, completion called after disconnect finished.
    private func disconnectInternal(completion: (() -> Void)?) {
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

    public func send(_ message: String) {
        socketDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            guard let channel = self.channel, channel.isActive else {
                self.logger.error("🔴 Channel is not connected")
                return
            }

            var buffer = channel.allocator.buffer(capacity: message.utf8.count + 1)
            buffer.writeString(message + "\n")

            channel.writeAndFlush(buffer, promise: nil)
            self.logger.debug("🔵 Message sent: \(message)")
        }
    }

    private func onStateChange(state: SocketClientConnectionState) {
        connectionStatePublisher.send(state)
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
}

extension NIOSocketHandlerClient: CustomStringConvertible {
    public var description: String {
        return
            "\(name):\(String(describing: host)):\(String(describing: port)), state: \(connectionStatePublisher.value)"
    }
}
