import NIOCore
import NIOPosix
import SocketCommon
import Testing
import XCTest

@testable import NIOHandler

private let serverPort = 1234
private let shortDelay: UInt64 = 500_000_000  // 0.5 sec
private let oneSecond: UInt64 = 1_000_000_000  // 1 sec
private let fiveSecond: UInt64 = 1_000_000_000  // 1 sec

@Test
func stressorTest_clientServerExchange() async throws {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        Task.detached {
            try? await eventLoopGroup.shutdownGracefully()
        }
    }

    let totalMessages = 1000
    let latency: UInt64 = 100_000  // ~0.1ms
    let serverPort = 2345

    let allMessages = (0..<totalMessages).map { _ in UUID().uuidString }

    let clientMessagesToSend = Array(allMessages.prefix(totalMessages / 2))
    let serverMessagesToSend = Array(allMessages.suffix(totalMessages / 2))

    async let serverResults = try serverTask(
        port: serverPort,
        messagesToSend: serverMessagesToSend,
        delayBeforeConnect: oneSecond,
        delayAfterConnect: oneSecond,
        latencyLower: 500,
        latencyUpper: 10_000
    )

    async let clientResults = try clientTask(
        port: serverPort,
        messagesToSend: clientMessagesToSend,
        delayBeforeConnect: shortDelay,
        delayAfterSendingMessages: oneSecond,
        eventLoopGroup: eventLoopGroup,
        latencyLower: 500,
        latencyUpper: 10_000
    )

    let (serverReceived, clientReceived) = try await (serverResults, clientResults)

    print("serverResults: \(serverReceived.count)")
    print("clientResults: \(clientReceived.count)")

    // Validation
    XCTAssertEqual(
        serverReceived.sorted(),
        clientMessagesToSend.sorted(),
        "Server did not receive all client messages."
    )
    XCTAssertEqual(
        clientReceived.sorted(),
        serverMessagesToSend.sorted(),
        "Client did not receive all server messages."
    )
}

@Test
func bounceMessagesBetweenServerAndClient() async throws {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        Task.detached {
            try? await eventLoopGroup.shutdownGracefully()
        }
    }

    let clientMessagesToSend = ["bob", "243erfw43q", "Blam"]
    let serverMessagesToSend = ["hello", "{}@#4reqafg4", "bla"]

    async let serverResults = try serverTask(
        port: serverPort,
        messagesToSend: serverMessagesToSend,
        delayBeforeConnect: oneSecond,
        delayAfterConnect: oneSecond,
        latencyLower: 1_000,
        latencyUpper: 1_000_000
    )

    async let clientResults = try clientTask(
        port: serverPort,
        messagesToSend: clientMessagesToSend,
        delayBeforeConnect: shortDelay,
        delayAfterSendingMessages: oneSecond,
        eventLoopGroup: eventLoopGroup,
        latencyLower: 1_000,
        latencyUpper: 1_000_000
    )

    let (serverMessages, clientMessages) = try await (serverResults, clientResults)

    print("serverResults: \(serverMessages)")
    print("clientResults: \(clientMessages)")

    XCTAssertEqual(
        serverMessages,
        clientMessagesToSend,
        "Server did not receive expected client messages"
    )
    XCTAssertEqual(
        clientMessages,
        serverMessagesToSend,
        "Client did not receive expected server messages"
    )

    print("fini")
}

@Test func connectClientToNetCat() async throws {
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

    let _ = client.connectionStatePublisher
        .sink { isConnected in
            print("Client connected:", isConnected)
        }

    try client.connect(
        host: "localhost",
        port: 1234,
        messageHandler: Handler { message in
            await collector.append(message)
        }
    )

    try await Task.sleep(nanoseconds: 1_000_000_000)

    try client.send("hello from test")

    try await Task.sleep(nanoseconds: 5_000_000_000)

    try client.disconnect()

    print("fini")
}

@Test func connectServerToNetCat() async throws {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        Task.detached {
            try? await eventLoopGroup.shutdownGracefully()
        }
    }

    let collector = MessageCollector()

    let server = NIOSocketHandlerServer()

    try server.listen(
        port: 1234,
        messageHandler: Handler { message in
            await collector.append(message)
        }
    )

    for n in 0..<5 {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        let message = "ping \(n)"
        print("Server sending: \(message)")
        try server.send(message)
    }

    try server.stopListening()

    print("fini")
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

    try server.listen(
        port: port,
        messageHandler: Handler { message in
            await collector.append(message)
        }
    )

    try await Task.sleep(nanoseconds: delayBeforeConnect)

    try await timeIt(label: "⚡️ stressorTest_clientServerExchange -- SERVER") {
        for message in messagesToSend {
            try server.send(message)
            try await Task.sleep(nanoseconds: UInt64.random(in: latencyLower..<latencyUpper))
        }
    }

    try await Task.sleep(nanoseconds: delayAfterConnect)
    try server.stopListening()

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

    try client.connect(
        host: "localhost",
        port: port,
        messageHandler: Handler { message in
            await collector.append(message)
        }
    )

    try await timeIt(label: "⚡️ stressorTest_clientServerExchange -- CLIENT") {
        for message in messagesToSend {
            try client.send(message)
            try await Task.sleep(nanoseconds: UInt64.random(in: latencyLower..<latencyUpper))
        }
    }

    try await Task.sleep(nanoseconds: delayAfterSendingMessages)
    try client.disconnect()

    return await collector.getMessages()
}

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
