import Foundation

// MARK: - Test Configuration

let serverPort = 1234
let stressorPort = 2345
let shortDelay: UInt64 = 500_000_000  // 0.5 sec
let oneSecond: UInt64 = 1_000_000_000  // 1 sec
let twoSeconds: UInt64 = 2_000_000_000  // 2 sec
let fiveSeconds: UInt64 = 5_000_000_000  // 5 sec

// Test environment flags
let runNetcatTests = ProcessInfo.processInfo.environment["RUN_NETCAT_TESTS"] == "1"
let runNetcatClientTests = ProcessInfo.processInfo.environment["RUN_NETCAT_CLIENT_TESTS"] == "1"
let runNetcatServerTests = ProcessInfo.processInfo.environment["RUN_NETCAT_SERVER_TESTS"] == "1"

// Test output directory (follows Swift package conventions)
let testOutputDir = ".build/test-output"
let metricsOutputPath = "\(testOutputDir)/test_metrics.json"