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

    let totalMessages = 100  // Reduced for deterministic timing
    let fixedLatency: UInt64 = 1_000_000  // 1ms fixed

    let allMessages = (0..<totalMessages).map { i in "Message_\(String(format: "%04d", i))" }

    let clientMessagesToSend = Array(allMessages.prefix(totalMessages / 2))
    let serverMessagesToSend = Array(allMessages.suffix(totalMessages / 2))

    let startTime = Date()

    async let serverResults = try deterministicServerTask(
        port: stressorPort,
        messagesToSend: serverMessagesToSend,
        delayBeforeConnect: oneSecond,
        delayAfterConnect: twoSeconds,
        fixedLatency: fixedLatency
    )

    async let clientResults = try deterministicClientTask(
        port: stressorPort,
        messagesToSend: clientMessagesToSend,
        delayBeforeConnect: shortDelay,
        delayAfterSendingMessages: twoSeconds,
        eventLoopGroup: eventLoopGroup,
        fixedLatency: fixedLatency
    )

    let (serverMessages, clientMessages) = try await (serverResults, clientResults)
    let endTime = Date()
    let duration = endTime.timeIntervalSince(startTime)

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

    let totalMessages = 50  // Reduced for testing
    let minLatency: UInt64 = 10_000_000    // 10ms
    let maxLatency: UInt64 = 100_000_000   // 100ms

    let allMessages = (0..<totalMessages).map { i in "Message_\(String(format: "%04d", i))" }

    let clientMessagesToSend = Array(allMessages.prefix(totalMessages / 2))
    let serverMessagesToSend = Array(allMessages.suffix(totalMessages / 2))

    let startTime = Date()

    async let serverResults = try serverTask(
        port: stressorPort,
        messagesToSend: serverMessagesToSend,
        delayBeforeConnect: oneSecond,
        delayAfterConnect: twoSeconds,
        latencyLower: minLatency,
        latencyUpper: maxLatency
    )

    async let clientResults = try clientTask(
        port: stressorPort,
        messagesToSend: clientMessagesToSend,
        delayBeforeConnect: shortDelay,
        delayAfterSendingMessages: twoSeconds,
        eventLoopGroup: eventLoopGroup,
        latencyLower: minLatency,
        latencyUpper: maxLatency
    )

    let (serverMessages, clientMessages) = try await (serverResults, clientResults)
    let endTime = Date()
    let duration = endTime.timeIntervalSince(startTime)

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

