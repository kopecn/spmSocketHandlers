import Foundation
import NIOPosix
import SocketCommon
import Testing

@testable import NIOHandler

// MARK: - NetCat Integration Tests

@Test
func connectClientToNetCat() async throws {
    guard runNetcatClientTests else {
        print("⏩ Skipping NetCat client test - set RUN_NETCAT_CLIENT_TESTS=1 to run")
        return
    }

    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        Task.detached {
            try? await eventLoopGroup.shutdownGracefully()
        }
    }

    let collector = MessageCollector()
    let client = NIOSocketHandlerClient(name: "netcat-test", eventLoopGroup: eventLoopGroup)

    print("🔗 Connecting to netcat server on localhost:1234")
    print("💡 Make sure to run: nc -l -p 1234")

    client.connect(
        host: "localhost",
        port: 1234,
        messageHandler: Handler { message in
            print("📥 Received from netcat: \(message)")
            await collector.append(message)
        }
    )

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
    for (index, message) in receivedMessages.enumerated() {
        print("📥 Received (\(index + 1)): \(message)")
    }
}

@Test
func connectServerToNetCat() async throws {
    guard runNetcatServerTests else {
        print("⏩ Skipping NetCat server test - set RUN_NETCAT_SERVER_TESTS=1 to run")
        return
    }

    let collector = MessageCollector()

    let server = NIOSocketHandlerServer()

    print("🔗 Starting server and connecting to netcat client on port 4321")
    print("💡 Make sure to run: nc localhost 4321")

    server.listen(
        port: 4321,
        messageHandler: Handler { message in
            print("📥 Server received from netcat: \(message)")
            await collector.append(message)
        }
    )

    try await Task.sleep(nanoseconds: twoSeconds)

    // Send test messages to any connected clients
    let testMessages = ["server hello", "server message 2", "server final message"]
    for (index, message) in testMessages.enumerated() {
        server.send(message)
        print("📤 Sent from server (\(index + 1)/\(testMessages.count)): \(message)")
        try await Task.sleep(nanoseconds: 500_000_000)  // 0.5s between messages
    }

    try await Task.sleep(nanoseconds: fiveSeconds)

    server.stopListening()

    let receivedMessages = await collector.getMessages()
    print("📊 Server test completed. Received \(receivedMessages.count) messages from netcat")
    for (index, message) in receivedMessages.enumerated() {
        print("📥 Server received (\(index + 1)): \(message)")
    }
}
