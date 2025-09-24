import Foundation

// MARK: - Metrics Functions

func saveMetrics(_ metrics: TestMetrics) throws {
    // Create test output directory if it doesn't exist
    let outputDirURL = URL(fileURLWithPath: testOutputDir)
    try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true, attributes: nil)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(metrics)

    let url = URL(fileURLWithPath: metricsOutputPath)
    try data.write(to: url)

    print("📊 Metrics saved to \(metricsOutputPath)")
}

// MARK: - Timing Utilities

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

func timeItWithDuration<T>(
    label: String = "⏱ timeIt",
    _ block: () async throws -> T
) async rethrows -> (result: T, duration: TimeInterval) {
    let start = DispatchTime.now()
    let result = try await block()
    let end = DispatchTime.now()
    let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds
    let duration = Double(nanoTime) / 1_000_000_000  // Convert to seconds
    let ms = Double(nanoTime) / 1_000_000
    print("\(label): \(String(format: "%.2f", ms)) ms")
    return (result, duration)
}