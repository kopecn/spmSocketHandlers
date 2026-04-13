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

// MARK: - Regression Tests

/// Verifies that a peer flooding the connection without ever sending the delimiter causes the
/// server to close the channel gracefully rather than growing memory without bound.
@Test
func test_maxCumulationBuffer() async throws {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        Task.detached { try? await eventLoopGroup.shutdownGracefully() }
    }

    let serverConfig = ServerConfiguration(maxCumulationBufferSize: 64)
    let server = NIOSocketHandlerServer(configuration: serverConfig)
    server.listen(port: maxBufferPort, messageHandler: Handler { _ in })

    let client = NIOSocketHandlerClient(name: "buffer-overflow-test", eventLoopGroup: eventLoopGroup)
    client.connect(host: "localhost", port: maxBufferPort, messageHandler: Handler { _ in })

    try await Task.sleep(nanoseconds: shortDelay)

    // Send 100 raw bytes with no newline delimiter — exceeds the 64-byte limit.
    // The server's NIOStringHandler will detect the overflow and close the channel.
    let oversizedPayload = Data(repeating: 0x41, count: 100)
    try? await client.send(confirming: oversizedPayload)

    // Allow the server to process the close and the client to detect the disconnection.
    try await Task.sleep(nanoseconds: oneSecond)

    #expect(!client.isConnected, "Client should be disconnected after server closes the channel")

    server.shutdown()
    try client.shutdown()
}

/// Verifies that N clients can connect simultaneously and each message from each client
/// is received by the server — no messages are dropped under concurrent load.
@Test
func test_concurrentConnections() async throws {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 4)
    defer {
        Task.detached { try? await eventLoopGroup.shutdownGracefully() }
    }

    let clientCount = 5
    let messagesPerClient = 20
    let serverCollector = MessageCollector()

    let server = NIOSocketHandlerServer()
    server.listen(
        port: concurrentPort,
        messageHandler: Handler { message in
            await serverCollector.append(message)
        }
    )

    try await Task.sleep(nanoseconds: shortDelay)

    try await withThrowingTaskGroup(of: Void.self) { group in
        for i in 0..<clientCount {
            group.addTask {
                let client = NIOSocketHandlerClient(
                    name: "concurrent-client-\(i)",
                    eventLoopGroup: eventLoopGroup
                )
                client.connect(host: "localhost", port: concurrentPort, messageHandler: Handler { _ in })
                try await Task.sleep(nanoseconds: 200_000_000)
                for j in 0..<messagesPerClient {
                    client.send("c\(i)-m\(j)")
                }
                try await Task.sleep(nanoseconds: oneSecond)
                client.disconnect()
            }
        }
        try await group.waitForAll()
    }

    try await Task.sleep(nanoseconds: oneSecond)
    server.shutdown()

    let received = await serverCollector.getMessages()
    #expect(
        received.count == clientCount * messagesPerClient,
        "Expected \(clientCount * messagesPerClient) messages, got \(received.count)"
    )
}

/// Verifies that connecting to a port with no listener produces an error state rather
/// than hanging or crashing.
@Test
func test_errorPath_connectionRefused() async throws {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        Task.detached { try? await eventLoopGroup.shutdownGracefully() }
    }

    let client = NIOSocketHandlerClient(name: "refused-test", eventLoopGroup: eventLoopGroup)
    client.connect(host: "localhost", port: 19999, messageHandler: Handler { _ in })

    // Allow time for the connection attempt to fail.
    try await Task.sleep(nanoseconds: twoSeconds)

    #expect(!client.isConnected, "Client should not be connected when the port has no listener")

    try client.shutdown()
}

/// Verifies that fire-and-forget send before connect does not crash, and that confirmed
/// send before connect throws SocketHandlerError.sendFailed.
@Test
func test_errorPath_sendBeforeConnect() async throws {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        Task.detached { try? await eventLoopGroup.shutdownGracefully() }
    }

    let client = NIOSocketHandlerClient(name: "pre-connect-test", eventLoopGroup: eventLoopGroup)

    // Fire-and-forget: should not crash and returns true.
    let sent = client.send("message before connect")
    #expect(sent == true, "Fire-and-forget send should return true even when not connected")

    // Confirmed send: should throw sendFailed.
    do {
        try await client.send(confirming: "message before connect")
        Issue.record("Expected send(confirming:) to throw before connect")
    } catch let error as SocketHandlerError {
        if case .sendFailed = error {
            // Expected path — test passes.
        } else {
            Issue.record("Expected .sendFailed, got: \(error)")
        }
    } catch {
        Issue.record("Expected SocketHandlerError, got: \(error)")
    }

    try client.shutdown()
}
