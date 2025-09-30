import Foundation

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
