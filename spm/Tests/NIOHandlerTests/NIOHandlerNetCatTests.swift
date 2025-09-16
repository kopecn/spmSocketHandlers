import Foundation
import NIOPosix
import SocketCommon
import XCTest
import Testing

@testable import NIOHandler

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

    try client.connect(
        host: "localhost",
        port: serverPort,
        messageHandler: Handler { message in
            await collector.append(message)
        }
    )

    let messages = (0..<5).map { "echo-\($0)" }

    for message in messages {
        try client.send(message)
        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 sec delay
    }

    try await Task.sleep(nanoseconds: 500_000_000)
    try client.disconnect()

    // Terminate the netcat process
    ncProcess.terminate()
    ncProcess.waitUntilExit()
    try await Task.sleep(nanoseconds: 200_000_000)  // Give OS time to clean up

    let echoedMessages = await collector.getMessages()
    print("✅ Echoed messages: \(echoedMessages)")

    XCTAssertEqual(echoedMessages.sorted(), messages.sorted(), "Echoed messages don't match input.")

    try? await eventLoopGroup.shutdownGracefully()
}

fileprivate final class Handler: MessageHandling {
    private let handler: @Sendable (String) async -> Void

    init(handler: @Sendable @escaping (String) async -> Void) {
        self.handler = handler
    }

    func handleMessage(_ message: String) async {
        await handler(message)
    }
}