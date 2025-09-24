import Foundation
import SocketCommon

// MARK: - Message Handler Helper

final class Handler: MessageHandling {
    private let handler: @Sendable (String) async -> Void

    init(handler: @Sendable @escaping (String) async -> Void) {
        self.handler = handler
    }

    func handleMessage(_ message: String) async {
        await handler(message)
    }
}