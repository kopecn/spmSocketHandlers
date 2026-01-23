import Foundation

import FoundationInterfaces

// MARK: - Message Handler Helper

final class Handler: MessageReceivable, @unchecked Sendable {
    private var stringHandler: (@Sendable (String) -> Void)?
    private var dataHandler: (@Sendable (Data) -> Void)?
    private let asyncHandler: (@Sendable (String) async -> Void)?

    init(handler: @Sendable @escaping (String) async -> Void) {
        self.asyncHandler = handler
    }

    func setStringMessageHandler(_ handler: (@Sendable (String) -> Void)?) {
        stringHandler = handler
    }

    func setDataMessageHandler(_ handler: (@Sendable (Data) -> Void)?) {
        dataHandler = handler
    }

    func handleMessage(_ message: String) async {
        stringHandler?(message)
        await asyncHandler?(message)
    }
}
