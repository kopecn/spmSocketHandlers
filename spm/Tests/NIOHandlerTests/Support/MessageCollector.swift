import Foundation

// MARK: - Message Collection

actor MessageCollector {
    private(set) var messages: [String] = []

    func append(_ message: String) {
        messages.append(message)
    }

    func getMessages() -> [String] {
        messages
    }
}
