import Foundation
import NIOCore
import NIOPosix
import Combine
@testable import NIOHandler

// MARK: - Connection Helpers

func waitForClientConnection(server: NIOSocketHandlerServer, timeout: TimeInterval = 15.0) async throws {
    let startTime = Date()
    var lastLogTime = startTime

    print("🔍 Waiting for client connection...")

    while Date().timeIntervalSince(startTime) < timeout {
        let connectedClients = server.connectedClientIDsPublisher.value
        if !connectedClients.isEmpty {
            print("📡 Client connected! Connected clients: \(connectedClients)")
            return
        }

        // Log progress every 2 seconds
        let currentTime = Date()
        if currentTime.timeIntervalSince(lastLogTime) >= 2.0 {
            print("⏳ Still waiting for client connection... (\(String(format: "%.1f", currentTime.timeIntervalSince(startTime)))s elapsed)")
            lastLogTime = currentTime
        }

        try await Task.sleep(nanoseconds: 100_000_000) // 100ms polling interval
    }

    print("❌ Timeout waiting for client connection after \(timeout)s")
    throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for client connection"])
}

// MARK: - Test Task Functions

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

    // Wait for client to connect before sending messages
    try await waitForClientConnection(server: server)

    try await timeIt(label: "⚡️ stressorTest_clientServerExchange -- SERVER") {
        for message in messagesToSend {
            server.send(message)
            try await Task.sleep(nanoseconds: UInt64.random(in: latencyLower..<latencyUpper))
        }
    }

    try await Task.sleep(nanoseconds: delayAfterConnect)
    server.shutdown() // Use proper shutdown instead of stopListening

    // Add small delay to ensure port is released
    try await Task.sleep(nanoseconds: 200_000_000) // 200ms

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

    // Wait for client to connect before sending messages
    try await waitForClientConnection(server: server)

    try await timeIt(label: "⚡️ deterministicServerTask") {
        for message in messagesToSend {
            server.send(message)
            try await Task.sleep(nanoseconds: fixedLatency)
        }
    }

    try await Task.sleep(nanoseconds: delayAfterConnect)
    server.shutdown() // Use proper shutdown instead of stopListening

    // Add small delay to ensure port is released
    try await Task.sleep(nanoseconds: 200_000_000) // 200ms

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

// MARK: - Timing-Aware Task Functions

func deterministicServerTaskWithTiming(
    port: Int,
    messagesToSend: [String],
    delayBeforeConnect: UInt64,
    delayAfterConnect: UInt64,
    fixedLatency: UInt64
) async throws -> (messages: [String], duration: TimeInterval) {
    let collector = MessageCollector()
    let server = NIOSocketHandlerServer()

    server.listen(
        port: port,
        messageHandler: Handler { message in
            await collector.append(message)
        }
    )

    try await Task.sleep(nanoseconds: delayBeforeConnect)

    // Wait for client to connect before sending messages
    try await waitForClientConnection(server: server)

    let (_, duration) = try await timeItWithDuration(label: "⚡️ deterministicServerTask") {
        for message in messagesToSend {
            server.send(message)
            try await Task.sleep(nanoseconds: fixedLatency)
        }
    }

    try await Task.sleep(nanoseconds: delayAfterConnect)
    server.shutdown() // Use proper shutdown instead of stopListening

    // Add small delay to ensure port is released
    try await Task.sleep(nanoseconds: 200_000_000) // 200ms

    let messages = await collector.getMessages()
    return (messages, duration)
}

func deterministicClientTaskWithTiming(
    port: Int,
    messagesToSend: [String],
    delayBeforeConnect: UInt64,
    delayAfterSendingMessages: UInt64,
    eventLoopGroup: EventLoopGroup,
    fixedLatency: UInt64
) async throws -> (messages: [String], duration: TimeInterval) {
    let collector = MessageCollector()

    let client = NIOSocketHandlerClient(
        name: "test-client",
        eventLoopGroup: eventLoopGroup
    )

    _ = client.connectionStatePublisher
        .sink { state in
            print("🔄 Deterministic client state changed:", state)
        }

    print("🔄 Deterministic client starting connection delay (\(Double(delayBeforeConnect) / 1_000_000_000)s)...")
    try await Task.sleep(nanoseconds: delayBeforeConnect)

    print("🔗 Deterministic client attempting connection to localhost:\(port)")
    client.connect(
        host: "localhost",
        port: port,
        messageHandler: Handler { message in
            await collector.append(message)
        }
    )

    // Wait a moment for connection to establish
    try await Task.sleep(nanoseconds: 200_000_000) // 200ms

    let (_, duration) = try await timeItWithDuration(label: "⚡️ deterministicClientTask") {
        for message in messagesToSend {
            client.send(message)
            try await Task.sleep(nanoseconds: fixedLatency)
        }
    }

    try await Task.sleep(nanoseconds: delayAfterSendingMessages)
    client.disconnect()

    let messages = await collector.getMessages()
    return (messages, duration)
}

// MARK: - Variable Timing Task Functions with Timing

func serverTaskWithTiming(
    port: Int,
    messagesToSend: [String],
    delayBeforeConnect: UInt64,
    delayAfterConnect: UInt64,
    latencyLower: UInt64,
    latencyUpper: UInt64
) async throws -> (messages: [String], duration: TimeInterval) {
    let collector = MessageCollector()
    let server = NIOSocketHandlerServer()

    print("🎧 Variable server starting to listen on port \(port)")
    server.listen(
        port: port,
        messageHandler: Handler { message in
            await collector.append(message)
        }
    )

    print("⏱️ Variable server waiting before connection check (\(Double(delayBeforeConnect) / 1_000_000_000)s)...")
    try await Task.sleep(nanoseconds: delayBeforeConnect)

    // Wait for client to connect before sending messages
    try await waitForClientConnection(server: server)

    let (_, duration) = try await timeItWithDuration(label: "⚡️ stressorTest_clientServerExchange -- SERVER") {
        for message in messagesToSend {
            server.send(message)
            try await Task.sleep(nanoseconds: UInt64.random(in: latencyLower..<latencyUpper))
        }
    }

    try await Task.sleep(nanoseconds: delayAfterConnect)
    server.shutdown() // Use proper shutdown instead of stopListening

    // Add small delay to ensure port is released
    try await Task.sleep(nanoseconds: 200_000_000) // 200ms

    let messages = await collector.getMessages()
    return (messages, duration)
}

func clientTaskWithTiming(
    port: Int,
    messagesToSend: [String],
    delayBeforeConnect: UInt64,
    delayAfterSendingMessages: UInt64,
    eventLoopGroup: EventLoopGroup,
    latencyLower: UInt64,
    latencyUpper: UInt64
) async throws -> (messages: [String], duration: TimeInterval) {
    let collector = MessageCollector()

    let client = NIOSocketHandlerClient(
        name: "test-client",
        eventLoopGroup: eventLoopGroup
    )

    _ = client.connectionStatePublisher
        .sink { state in
            print("🔄 Client state changed:", state)
        }

    print("🔄 Client starting connection delay (\(Double(delayBeforeConnect) / 1_000_000_000)s)...")
    try await Task.sleep(nanoseconds: delayBeforeConnect)

    print("🔗 Client attempting connection to localhost:\(port)")
    client.connect(
        host: "localhost",
        port: port,
        messageHandler: Handler { message in
            await collector.append(message)
        }
    )

    // Wait a moment for connection to establish
    try await Task.sleep(nanoseconds: 200_000_000) // 200ms

    let (_, duration) = try await timeItWithDuration(label: "⚡️ stressorTest_clientServerExchange -- CLIENT") {
        for message in messagesToSend {
            client.send(message)
            try await Task.sleep(nanoseconds: UInt64.random(in: latencyLower..<latencyUpper))
        }
    }

    try await Task.sleep(nanoseconds: delayAfterSendingMessages)
    client.disconnect()

    let messages = await collector.getMessages()
    return (messages, duration)
}