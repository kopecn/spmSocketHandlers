import Foundation
import NIOCore
import NIOPosix
import SocketCommon
import Testing
import XCTest

@testable import NIOHandler

// MARK: - Performance Tests

@Test
func stressorTest_deterministicTiming() async throws {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        Task.detached {
            try? await eventLoopGroup.shutdownGracefully()
        }
    }

    let totalMessages = 10000  // Stress test with 10k messages
    let fixedLatency: UInt64 = 1_000  // 1us fixed

    let allMessages = (0..<totalMessages).map { i in "Message_\(String(format: "%04d", i))" }

    let clientMessagesToSend = Array(allMessages.prefix(totalMessages / 2))
    let serverMessagesToSend = Array(allMessages.suffix(totalMessages / 2))

    async let serverResults = try deterministicServerTaskWithTiming(
        port: deterministicPort,
        messagesToSend: serverMessagesToSend,
        delayBeforeConnect: shortDelay,  // Reduced delay for server start
        delayAfterConnect: twoSeconds,
        fixedLatency: fixedLatency
    )

    async let clientResults = try deterministicClientTaskWithTiming(
        port: deterministicPort,
        messagesToSend: clientMessagesToSend,
        delayBeforeConnect: oneSecond,  // Increased delay to let server start first
        delayAfterSendingMessages: twoSeconds,
        eventLoopGroup: eventLoopGroup,
        fixedLatency: fixedLatency
    )

    let ((serverMessages, serverDuration), (clientMessages, clientDuration)) = try await (serverResults, clientResults)

    // Use combined duration for message exchange only (excluding setup/teardown)
    let duration = max(serverDuration, clientDuration)

    let metrics = TestMetrics(
        testName: "stressorTest_deterministicTiming",
        totalMessages: totalMessages,
        duration: duration,
        messagesPerSecond: Double(totalMessages) / duration,
        serverReceived: serverMessages.count,
        clientReceived: clientMessages.count,
        timestamp: ISO8601DateFormatter().string(from: Date())
    )

    try saveMetrics(metrics)

    print("📊 Deterministic Test Complete:")
    print("  Total messages: \(totalMessages)")
    print("  Duration: \(String(format: "%.2f", duration))s")
    print("  Messages/sec: \(String(format: "%.2f", metrics.messagesPerSecond))")
    print("  Server received: \(serverMessages.count)")
    print("  Client received: \(clientMessages.count)")
}

@Test
func stressorTest_variableTiming() async throws {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        Task.detached {
            try? await eventLoopGroup.shutdownGracefully()
        }
    }

    let totalMessages = 15000  // Stress test with 15k messages
    let minLatency: UInt64 = 1_000  // 1us
    let maxLatency: UInt64 = 100_000  // 100us

    let allMessages = (0..<totalMessages).map { i in "Message_\(String(format: "%04d", i))" }

    let clientMessagesToSend = Array(allMessages.prefix(totalMessages / 2))
    let serverMessagesToSend = Array(allMessages.suffix(totalMessages / 2))

    async let serverResults = try serverTaskWithTiming(
        port: variablePort,
        messagesToSend: serverMessagesToSend,
        delayBeforeConnect: shortDelay,  // Reduced delay for server start
        delayAfterConnect: twoSeconds,
        latencyLower: minLatency,
        latencyUpper: maxLatency
    )

    async let clientResults = try clientTaskWithTiming(
        port: variablePort,
        messagesToSend: clientMessagesToSend,
        delayBeforeConnect: oneSecond,  // Increased delay to let server start first
        delayAfterSendingMessages: twoSeconds,
        eventLoopGroup: eventLoopGroup,
        latencyLower: minLatency,
        latencyUpper: maxLatency
    )

    let ((serverMessages, serverDuration), (clientMessages, clientDuration)) = try await (serverResults, clientResults)

    // Use combined duration for message exchange only (excluding setup/teardown)
    let duration = max(serverDuration, clientDuration)

    let metrics = TestMetrics(
        testName: "stressorTest_variableTiming",
        totalMessages: totalMessages,
        duration: duration,
        messagesPerSecond: Double(totalMessages) / duration,
        serverReceived: serverMessages.count,
        clientReceived: clientMessages.count,
        timestamp: ISO8601DateFormatter().string(from: Date())
    )

    try saveMetrics(metrics)

    print("📊 Variable Timing Test Complete:")
    print("  Total messages: \(totalMessages)")
    print("  Duration: \(String(format: "%.2f", duration))s")
    print("  Messages/sec: \(String(format: "%.2f", metrics.messagesPerSecond))")
    print("  Server received: \(serverMessages.count)")
    print("  Client received: \(clientMessages.count)")
}

@Test
func basicMessageExchange() async throws {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        Task.detached {
            try? await eventLoopGroup.shutdownGracefully()
        }
    }

    let collector = MessageCollector()

    let server = NIOSocketHandlerServer()
    server.listen(
        port: serverPort,
        messageHandler: Handler { message in
            await collector.append(message)
        }
    )

    let client = NIOSocketHandlerClient(name: "basic-test", eventLoopGroup: eventLoopGroup)

    client.connect(
        host: "localhost",
        port: serverPort,
        messageHandler: Handler { message in
            await collector.append(message)
        }
    )

    try await Task.sleep(nanoseconds: shortDelay)

    // Send messages from client to server
    client.send("Hello from client")
    client.send("Second message from client")

    try await Task.sleep(nanoseconds: shortDelay)

    // Send messages from server to client
    server.send("Hello from server")
    server.send("Second message from server")

    try await Task.sleep(nanoseconds: oneSecond)

    client.disconnect()
    server.stopListening()

    let messages = await collector.getMessages()
    print("📨 Total messages exchanged: \(messages.count)")
    for (i, message) in messages.enumerated() {
        print("  \(i + 1): \(message)")
    }
}
