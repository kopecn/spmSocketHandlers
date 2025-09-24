/// Represents the various connection states of a socket client.
public enum SocketClientConnectionState: Equatable, Sendable, CustomStringConvertible {

    /// The client is currently connected.
    case connected

    /// The client is in the process of establishing a connection.
    case connecting

    /// The client is not connected.
    case disconnected

    /// The client is in the process of disconnecting from a connection.
    case disconnecting

    /// The client encountered an error during connection or communication.
    ///
    /// - Parameter err: An `Error` value describing the issue that occurred.
    case error(err: Error)

    /// Compares two `SocketClientConnectionState` values for equality.
    ///
    /// This implementation considers two `.error` cases equal regardless of the specific error value.
    /// Use a custom `EquatableError` wrapper if you need fine-grained error comparison.
    public static func == (lhs: SocketClientConnectionState, rhs: SocketClientConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.connected, .connected),
            (.connecting, .connecting),
            (.disconnected, .disconnected),
            (.disconnecting, .disconnecting):
            return true
        case (.error, .error):
            return true  // Treat all errors as equal
        default:
            return false
        }
    }

    public var description: String {
        switch self {
        case .connected:
            return "Connected"
        case .disconnected:
            return "Disconnected"
        case .disconnecting:
            return "Disconnecting..."
        case .connecting:
            return "Connecting..."
        case .error(let message):
            return "Error: \(message)"
        }
    }
}
