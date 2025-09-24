import Foundation
import NIOPosix
import SocketCommon
import Testing
import XCTest

@testable import NIOHandler

// MARK: - NetCat Integration Tests

@Test func connectClientToNetCat() async throws {
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

@Test func connectServerToNetCat() async throws {
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
@Test
func netcatEchoTest() async throws {
    // return // This method is not ready
    let serverPort = 4567
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    // Launch netcat server as echo responder
    let ncProcess = Process()
    ncProcess.executableURL = URL(fileURLWithPath: "/bin/sh")

    let ncCommand = "nc -l \(serverPort)"
    let inputPipe = Pipe()
    let outputPipe = Pipe()

    ncProcess.arguments = ["-c", ncCommand]
    ncProcess.standardInput = inputPipe
    ncProcess.standardOutput = outputPipe
    ncProcess.standardError = outputPipe

    try ncProcess.run()
    print("🚀 Launched netcat server on port \(serverPort)")

    // Wait briefly for netcat to bind
    try await Task.sleep(nanoseconds: 300_000_000)

    // Prepare to collect echoed messages
    let collector = MessageCollector()
    let client = NIOSocketHandlerClient(name: "netcat-test", eventLoopGroup: eventLoopGroup)

    client.connect(
        host: "localhost",
        port: serverPort,
        messageHandler: Handler { message in
            await collector.append(message)
        }
    )

    let messages = (0..<5).map { "echo-\($0)" }

    for message in messages {
        client.send(message)
        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 sec delay
    }

    try await Task.sleep(nanoseconds: 500_000_000)
    client.disconnect()

    // Terminate the netcat process
    ncProcess.terminate()
    ncProcess.waitUntilExit()
    try await Task.sleep(nanoseconds: 200_000_000)  // Give OS time to clean up

    let echoedMessages = await collector.getMessages()
    print("✅ Echoed messages: \(echoedMessages)")

    XCTAssertEqual(echoedMessages.sorted(), messages.sorted(), "Echoed messages don't match input.")

    try? await eventLoopGroup.shutdownGracefully()
}
