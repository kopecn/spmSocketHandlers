import Foundation
import NIOCore
import NIOPosix
@testable import NIOHandler

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