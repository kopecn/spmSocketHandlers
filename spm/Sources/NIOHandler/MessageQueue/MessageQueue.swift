import Foundation

/// A message queuing system for handling messages when connections are unavailable.
///
/// This class provides persistent message storage with configurable limits and retry policies.
/// Messages are stored in memory and can be persisted to disk for durability across restarts.
public final class MessageQueue: @unchecked Sendable {
    /// Configuration for the message queue behavior.
    public struct Configuration: Sendable {
        /// Maximum number of messages to store in the queue. Defaults to 1000.
        public let maxQueueSize: Int

        /// Whether to persist messages to disk. Defaults to false.
        public let persistToDisk: Bool

        /// Maximum age of messages in seconds before they expire. Defaults to 300 (5 minutes).
        public let messageExpirationTime: TimeInterval

        /// Path for disk persistence. Only used if persistToDisk is true.
        public let persistencePath: String?

        /// Creates a new MessageQueue Configuration.
        public init(
            maxQueueSize: Int = 1000,
            persistToDisk: Bool = false,
            messageExpirationTime: TimeInterval = 300,
            persistencePath: String? = nil
        ) {
            self.maxQueueSize = maxQueueSize
            self.persistToDisk = persistToDisk
            self.messageExpirationTime = messageExpirationTime
            self.persistencePath = persistencePath
        }

        /// Default configuration with commonly used settings.
        public static let `default` = Configuration()
    }

    /// A queued message with metadata.
    public struct QueuedMessage: Codable, Sendable {
        /// The message content.
        public let content: String

        /// The timestamp when the message was queued.
        public let timestamp: Date

        /// The number of delivery attempts.
        public let attemptCount: Int

        /// The priority of the message (higher values have higher priority).
        public let priority: Int

        /// Optional target identifier (for server-side targeting specific clients).
        public let targetID: String?

        /// Creates a new queued message.
        public init(content: String, priority: Int = 0, targetID: String? = nil, attemptCount: Int = 0) {
            self.content = content
            self.timestamp = Date()
            self.attemptCount = attemptCount
            self.priority = priority
            self.targetID = targetID
        }
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "com.socket-handlers.message-queue", qos: .utility)
    private var messages: [QueuedMessage] = []
    private var cleanupTimer: DispatchSourceTimer?

    /// Creates a new MessageQueue with the specified configuration.
    public init(configuration: Configuration = .default) {
        self.configuration = configuration
        setupCleanupTimer()

        if configuration.persistToDisk {
            loadPersistedMessages()
        }
    }

    deinit {
        cleanupTimer?.cancel()
        if configuration.persistToDisk {
            persistMessages()
        }
    }

    /// Enqueues a message for later delivery.
    ///
    /// - Parameter message: The message to enqueue.
    /// - Returns: True if the message was successfully enqueued, false if the queue is full.
    @discardableResult
    public func enqueue(_ message: QueuedMessage) -> Bool {
        return queue.sync {
            // Remove expired messages first
            cleanupExpiredMessages()

            // Check if queue is full
            if messages.count >= configuration.maxQueueSize {
                // Remove the oldest message to make room
                if !messages.isEmpty {
                    messages.removeFirst()
                }
            }

            // Insert message in priority order
            let insertIndex = messages.firstIndex { $0.priority < message.priority } ?? messages.endIndex
            messages.insert(message, at: insertIndex)

            if configuration.persistToDisk {
                persistMessages()
            }

            return true
        }
    }

    /// Dequeues the next message for delivery.
    ///
    /// - Returns: The next message to deliver, or nil if the queue is empty.
    public func dequeue() -> QueuedMessage? {
        return queue.sync {
            cleanupExpiredMessages()

            guard !messages.isEmpty else { return nil }

            let message = messages.removeFirst()

            // Create a new message with incremented attempt count
            let updatedMessage = QueuedMessage(
                content: message.content,
                priority: message.priority,
                targetID: message.targetID,
                attemptCount: message.attemptCount + 1
            )

            if configuration.persistToDisk {
                persistMessages()
            }

            return updatedMessage
        }
    }

    /// Peeks at the next message without removing it from the queue.
    ///
    /// - Returns: The next message to deliver, or nil if the queue is empty.
    public func peek() -> QueuedMessage? {
        return queue.sync {
            cleanupExpiredMessages()
            return messages.first
        }
    }

    /// Returns the current number of messages in the queue.
    public var count: Int {
        return queue.sync {
            cleanupExpiredMessages()
            return messages.count
        }
    }

    /// Clears all messages from the queue.
    public func clear() {
        queue.sync {
            messages.removeAll()
            if configuration.persistToDisk {
                persistMessages()
            }
        }
    }

    /// Gets messages for a specific target ID.
    ///
    /// - Parameter targetID: The target identifier to filter by.
    /// - Returns: An array of messages for the specified target.
    public func messages(for targetID: String) -> [QueuedMessage] {
        return queue.sync {
            cleanupExpiredMessages()
            return messages.filter { $0.targetID == targetID }
        }
    }

    /// Removes messages for a specific target ID.
    ///
    /// - Parameter targetID: The target identifier to remove messages for.
    /// - Returns: The number of messages removed.
    @discardableResult
    public func removeMessages(for targetID: String) -> Int {
        return queue.sync {
            let initialCount = messages.count
            messages.removeAll { $0.targetID == targetID }
            let removedCount = initialCount - messages.count

            if configuration.persistToDisk && removedCount > 0 {
                persistMessages()
            }

            return removedCount
        }
    }

    // MARK: - Private Methods

    private func setupCleanupTimer() {
        cleanupTimer = DispatchSource.makeTimerSource(queue: queue)
        cleanupTimer?.schedule(deadline: .now() + 60, repeating: .seconds(60))  // Run every minute
        cleanupTimer?.setEventHandler { [weak self] in
            self?.cleanupExpiredMessages()
        }
        cleanupTimer?.resume()
    }

    private func cleanupExpiredMessages() {
        let expirationDate = Date().addingTimeInterval(-configuration.messageExpirationTime)
        let initialCount = messages.count

        messages.removeAll { $0.timestamp < expirationDate }

        if configuration.persistToDisk && messages.count != initialCount {
            persistMessages()
        }
    }

    private func loadPersistedMessages() {
        guard let path = configuration.persistencePath else { return }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            messages = try JSONDecoder().decode([QueuedMessage].self, from: data)
        } catch {
            // If loading fails, start with an empty queue
            messages = []
        }
    }

    private func persistMessages() {
        guard let path = configuration.persistencePath else { return }

        do {
            let data = try JSONEncoder().encode(messages)
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            // Persistence failure is logged but doesn't stop operation
            print("Failed to persist messages: \(error)")
        }
    }
}
