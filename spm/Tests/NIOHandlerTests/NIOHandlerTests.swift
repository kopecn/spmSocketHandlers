import Foundation
import NIOCore
import NIOPosix
import SocketCommon
import Testing
import XCTest

@testable import NIOHandler

// MARK: - Test Configuration

private let serverPort = 1234
private let stressorPort = 2345
private let shortDelay: UInt64 = 500_000_000  // 0.5 sec
private let oneSecond: UInt64 = 1_000_000_000  // 1 sec
private let twoSeconds: UInt64 = 2_000_000_000  // 2 sec
private let fiveSeconds: UInt64 = 5_000_000_000  // 5 sec

// Test environment flags
private let runNetcatTests = ProcessInfo.processInfo.environment["RUN_NETCAT_TESTS"] == "1"

// Test output directory (follows Swift package conventions)
private let testOutputDir = ".build/test-output"
private let metricsOutputPath = "\(testOutputDir)/test_metrics.json"

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
        delayAfterConnect: oneSecond,
        fixedLatency: fixedLatency
    )

    async let clientResults = try deterministicClientTask(
        port: stressorPort,
        messagesToSend: clientMessagesToSend,
        delayBeforeConnect: shortDelay,
        delayAfterSendingMessages: oneSecond,
        eventLoopGroup: eventLoopGroup,
        fixedLatency: fixedLatency
    )

    let (serverReceived, clientReceived) = try await (serverResults, clientResults)
    let duration = Date().timeIntervalSince(startTime)

    // Enhanced validation with detailed message comparison
    XCTAssertEqual(
        Set(serverReceived),
        Set(clientMessagesToSend),
        "Server received messages do not match client sent messages. Missing: \(Set(clientMessagesToSend).subtracting(Set(serverReceived))), Extra: \(Set(serverReceived).subtracting(Set(clientMessagesToSend)))"
    )
    XCTAssertEqual(
        Set(clientReceived),
        Set(serverMessagesToSend),
        "Client received messages do not match server sent messages. Missing: \(Set(serverMessagesToSend).subtracting(Set(clientReceived))), Extra: \(Set(clientReceived).subtracting(Set(serverMessagesToSend)))"
    )

    // Collect and save metrics
    let metrics = TestMetrics(
        testName: "stressorTest_deterministicTiming",
        totalMessages: totalMessages,
        duration: duration,
        messagesPerSecond: Double(totalMessages) / duration,
        serverReceived: serverReceived.count,
        clientReceived: clientReceived.count,
        timestamp: ISO8601DateFormatter().string(from: Date())
    )

    try saveMetrics(metrics)
    print("📊 Test completed in \(String(format: "%.2f", duration))s, \(String(format: "%.2f", metrics.messagesPerSecond)) msg/s")
}

@Test
func stressorTest_variableTiming() async throws {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        Task.detached {
            try? await eventLoopGroup.shutdownGracefully()
        }
    }

    let totalMessages = 1000
    let allMessages = (0..<totalMessages).map { _ in UUID().uuidString }

    let clientMessagesToSend = Array(allMessages.prefix(totalMessages / 2))
    let serverMessagesToSend = Array(allMessages.suffix(totalMessages / 2))

    async let serverResults = try serverTask(
        port: stressorPort + 1,  // Use different port
        messagesToSend: serverMessagesToSend,
        delayBeforeConnect: oneSecond,
        delayAfterConnect: oneSecond,
        latencyLower: 500,
        latencyUpper: 10_000
    )

    async let clientResults = try clientTask(
        port: stressorPort + 1,
        messagesToSend: clientMessagesToSend,
        delayBeforeConnect: shortDelay,
        delayAfterSendingMessages: oneSecond,
        eventLoopGroup: eventLoopGroup,
        latencyLower: 500,
        latencyUpper: 10_000
    )

    let (serverReceived, clientReceived) = try await (serverResults, clientResults)

    // Enhanced validation with detailed message comparison
    XCTAssertEqual(
        Set(serverReceived),
        Set(clientMessagesToSend),
        "Server received messages do not match client sent messages. Missing: \(Set(clientMessagesToSend).subtracting(Set(serverReceived))), Extra: \(Set(serverReceived).subtracting(Set(clientMessagesToSend)))"
    )
    XCTAssertEqual(
        Set(clientReceived),
        Set(serverMessagesToSend),
        "Client received messages do not match server sent messages. Missing: \(Set(serverMessagesToSend).subtracting(Set(clientReceived))), Extra: \(Set(clientReceived).subtracting(Set(serverMessagesToSend)))"
    )

    print("📊 Variable timing test: Server received \(serverReceived.count)/\(clientMessagesToSend.count), Client received \(clientReceived.count)/\(serverMessagesToSend.count)")
}

// MARK: - Functional Tests

@Test
func basicMessageExchange() async throws {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        Task.detached {
            try? await eventLoopGroup.shutdownGracefully()
        }
    }

    let clientMessagesToSend = ["message_1", "message_2_with_special_chars_!@#$%", "message_3_longer_text_for_testing"]
    let serverMessagesToSend = ["response_1", "response_2_with_numbers_12345", "response_3_final"]

    async let serverResults = try deterministicServerTask(
        port: serverPort,
        messagesToSend: serverMessagesToSend,
        delayBeforeConnect: oneSecond,
        delayAfterConnect: oneSecond,
        fixedLatency: 10_000  // 10ms fixed delay
    )

    async let clientResults = try deterministicClientTask(
        port: serverPort,
        messagesToSend: clientMessagesToSend,
        delayBeforeConnect: shortDelay,
        delayAfterSendingMessages: oneSecond,
        eventLoopGroup: eventLoopGroup,
        fixedLatency: 10_000  // 10ms fixed delay
    )

    let (serverMessages, clientMessages) = try await (serverResults, clientResults)

    // Detailed validation with exact order and content
    XCTAssertEqual(
        serverMessages.count,
        clientMessagesToSend.count,
        "Server received \(serverMessages.count) messages, expected \(clientMessagesToSend.count)"
    )
    XCTAssertEqual(
        clientMessages.count,
        serverMessagesToSend.count,
        "Client received \(clientMessages.count) messages, expected \(serverMessagesToSend.count)"
    )

    // Check message content (order may vary due to async nature)
    XCTAssertEqual(
        Set(serverMessages),
        Set(clientMessagesToSend),
        "Server received different messages than client sent. Received: \(serverMessages), Expected: \(clientMessagesToSend)"
    )
    XCTAssertEqual(
        Set(clientMessages),
        Set(serverMessagesToSend),
        "Client received different messages than server sent. Received: \(clientMessages), Expected: \(serverMessagesToSend)"
    )

    print("✅ Basic message exchange completed successfully")
    print("📧 Server received: \(serverMessages)")
    print("📧 Client received: \(clientMessages)")
}

// MARK: - Netcat Integration Tests (Manual)

@Test func connectClientToNetCat() async throws {
    // Skip this test unless explicitly enabled
    guard runNetcatTests else {
        print("⏭️ Skipping netcat client test (set RUN_NETCAT_TESTS=1 to enable)")
        return
    }

    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        Task.detached {
            try? await eventLoopGroup.shutdownGracefully()
        }
    }

    let collector = MessageCollector()

    let client = NIOSocketHandlerClient(
        name: "netcat-client",
        eventLoopGroup: eventLoopGroup
    )

    var connectionStates: [SocketClientConnectionState] = []
    let _ = client.connectionStatePublisher
        .sink { state in
            connectionStates.append(state)
            print("📡 Client state changed:", state)
        }

    print("🔗 Connecting to netcat server on localhost:1234")
    print("💡 Make sure to run: nc -l -p 1234")

    client.connect(
        host: "localhost",
        port: 1234,
        messageHandler: Handler { message in
            await collector.append(message)
            print("📨 Received from netcat: \(message)")
        }
    )

    try await Task.sleep(nanoseconds: oneSecond)

    // Send a series of test messages
    let testMessages = ["hello from test", "message 2", "final message"]
    for (index, message) in testMessages.enumerated() {
        client.send(message)
        print("📤 Sent to netcat (\(index + 1)/\(testMessages.count)): \(message)")
        try await Task.sleep(nanoseconds: 500_000_000)  // 0.5s between messages
    }

    try await Task.sleep(nanoseconds: twoSeconds)

    client.disconnect()

    let receivedMessages = await collector.getMessages()
    print("📊 Test completed. Received \(receivedMessages.count) messages from netcat")
    print("📈 Connection states observed: \(connectionStates.map { "\($0)" }.joined(separator: " → "))")
}

@Test func connectServerToNetCat() async throws {
    // Skip this test unless explicitly enabled
    guard runNetcatTests else {
        print("⏭️ Skipping netcat server test (set RUN_NETCAT_TESTS=1 to enable)")
        return
    }

    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        Task.detached {
            try? await eventLoopGroup.shutdownGracefully()
        }
    }

    let collector = MessageCollector()

    let server = NIOSocketHandlerServer()

    print("🚀 Starting server on port 1234")
    print("💡 Connect with: nc localhost 1234")

    server.listen(
        port: 1234,
        messageHandler: Handler { message in
            await collector.append(message)
            print("📨 Server received from netcat: \(message)")
        }
    )

    // Wait for connection and send test messages
    for n in 0..<5 {
        try await Task.sleep(nanoseconds: twoSeconds)
        let message = "server_ping_\(n)_\(Date().timeIntervalSince1970)"
        print("📤 Server sending: \(message)")
        server.send(message)

        // Check if we received any messages from netcat
        let currentMessages = await collector.getMessages()
        if !currentMessages.isEmpty {
            print("📨 Total messages received so far: \(currentMessages.count)")
        }
    }

    server.stopListening()

    let finalMessages = await collector.getMessages()
    print("📊 Test completed. Server received \(finalMessages.count) messages from netcat")
    if !finalMessages.isEmpty {
        print("📝 Messages: \(finalMessages)")
    }
}

// MARK: - Test Data Structures

struct TestMetrics: Codable {
    let testName: String
    let totalMessages: Int
    let duration: TimeInterval
    let messagesPerSecond: Double
    let serverReceived: Int
    let clientReceived: Int
    let timestamp: String
}

// MARK: - Helpers

private final class Handler: MessageHandling {
    private let handler: @Sendable (String) async -> Void

    init(handler: @Sendable @escaping (String) async -> Void) {
        self.handler = handler
    }

    func handleMessage(_ message: String) async {
        await handler(message)
    }
}

actor MessageCollector {
    private(set) var messages: [String] = []

    func append(_ message: String) {
        messages.append(message)
    }

    func getMessages() -> [String] {
        messages
    }
}

func serverTask(
    port: Int,
    messagesToSend: [String],
    delayBeforeConnect: UInt64,
    delayAfterConnect: UInt64,
    latencyLower: UInt64,
    latencyUpper: UInt64,
) async throws -> [String] {
    let collector = MessageCollector()
    let server = NIOSocketHandlerServer()

    server.listen(
        port: port,
        messageHandler: Handler { message in
            await collector.append(message)
        }
    )

    try await Task.sleep(nanoseconds: delayBeforeConnect)

    try await timeIt(label: "⚡️ stressorTest_clientServerExchange -- SERVER") {
        for message in messagesToSend {
            server.send(message)
            try await Task.sleep(nanoseconds: UInt64.random(in: latencyLower..<latencyUpper))
        }
    }

    try await Task.sleep(nanoseconds: delayAfterConnect)
    server.stopListening()

    return await collector.getMessages()
}

func clientTask(
    port: Int,
    messagesToSend: [String],
    delayBeforeConnect: UInt64,
    delayAfterSendingMessages: UInt64,
    eventLoopGroup: EventLoopGroup,
    latencyLower: UInt64,
    latencyUpper: UInt64,
) async throws -> [String] {
    let collector = MessageCollector()

    let client = NIOSocketHandlerClient(
        name: "test-client",
        eventLoopGroup: eventLoopGroup
    )

    _ = client.connectionStatePublisher
        .sink { state in
            print("Client state:", state)
        }

    try await Task.sleep(nanoseconds: delayBeforeConnect)

    client.connect(
        host: "localhost",
        port: port,
        messageHandler: Handler { message in
            await collector.append(message)
        }
    )

    try await timeIt(label: "⚡️ stressorTest_clientServerExchange -- CLIENT") {
        for message in messagesToSend {
            client.send(message)
            try await Task.sleep(nanoseconds: UInt64.random(in: latencyLower..<latencyUpper))
        }
    }

    try await Task.sleep(nanoseconds: delayAfterSendingMessages)
    client.disconnect()

    return await collector.getMessages()
}

// MARK: - Deterministic Task Functions

func deterministicServerTask(
    port: Int,
    messagesToSend: [String],
    delayBeforeConnect: UInt64,
    delayAfterConnect: UInt64,
    fixedLatency: UInt64
) async throws -> [String] {
    let collector = MessageCollector()
    let server = NIOSocketHandlerServer()

    server.listen(
        port: port,
        messageHandler: Handler { message in
            await collector.append(message)
        }
    )

    try await Task.sleep(nanoseconds: delayBeforeConnect)

    try await timeIt(label: "⚡️ deterministicServerTask") {
        for message in messagesToSend {
            server.send(message)
            try await Task.sleep(nanoseconds: fixedLatency)
        }
    }

    try await Task.sleep(nanoseconds: delayAfterConnect)
    server.stopListening()

    return await collector.getMessages()
}

func deterministicClientTask(
    port: Int,
    messagesToSend: [String],
    delayBeforeConnect: UInt64,
    delayAfterSendingMessages: UInt64,
    eventLoopGroup: EventLoopGroup,
    fixedLatency: UInt64
) async throws -> [String] {
    let collector = MessageCollector()

    let client = NIOSocketHandlerClient(
        name: "test-client",
        eventLoopGroup: eventLoopGroup
    )

    _ = client.connectionStatePublisher
        .sink { state in
            print("Client state:", state)
        }

    try await Task.sleep(nanoseconds: delayBeforeConnect)

    client.connect(
        host: "localhost",
        port: port,
        messageHandler: Handler { message in
            await collector.append(message)
        }
    )

    try await timeIt(label: "⚡️ deterministicClientTask") {
        for message in messagesToSend {
            client.send(message)
            try await Task.sleep(nanoseconds: fixedLatency)
        }
    }

    try await Task.sleep(nanoseconds: delayAfterSendingMessages)
    client.disconnect()

    return await collector.getMessages()
}

// MARK: - Metrics Functions

func saveMetrics(_ metrics: TestMetrics) throws {
    // Create test output directory if it doesn't exist
    let outputDirURL = URL(fileURLWithPath: testOutputDir)
    try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true, attributes: nil)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(metrics)

    let url = URL(fileURLWithPath: metricsOutputPath)
    try data.write(to: url)

    print("📊 Metrics saved to \(metricsOutputPath)")
}

// MARK: - Timing Utilities

func timeIt<T>(
    label: String = "⏱ timeIt",
    _ block: () async throws -> T
) async rethrows -> T {
    let start = DispatchTime.now()
    let result = try await block()
    let end = DispatchTime.now()
    let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds
    let ms = Double(nanoTime) / 1_000_000
    print("\(label): \(String(format: "%.2f", ms)) ms")
    return result
}
