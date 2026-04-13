import Foundation

/// An enumeration representing errors that can occur within a socket handler.
public enum SocketHandlerError: Error, LocalizedError {
    /// Indicates a failure to establish a connection.
    /// - Parameter message: A descriptive message explaining the reason for the failure.
    case connectionFailed(message: String)

    /// Indicates a failure to disconnect properly.
    /// - Parameter message: A descriptive message explaining the reason for the failure.
    case disconnectionFailed(message: String)

    /// Indicates a failure to send data over the socket.
    /// - Parameter message: A descriptive message explaining the reason for the failure.
    case sendFailed(message: String)

    /// Represents an internal error within the socket handler.
    /// - Parameter message: A descriptive message explaining the reason for the internal failure.
    case internalFailure(message: String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .disconnectionFailed(let msg): return "Disconnection failed: \(msg)"
        case .sendFailed(let msg): return "Send failed: \(msg)"
        case .internalFailure(let msg): return "Internal failure: \(msg)"
        }
    }
}
