/// Represents the state of a server's listener, indicating whether it is off, listening, has active connections, or encountered an error.
public enum SocketServerListeningState: Equatable, Sendable, CustomStringConvertible {

    /// The server is currently turned off and not listening for incoming connections.
    case off

    /// The server is actively listening for incoming connections, but none are currently connected.
    case listening

    /// The server has one or more active client connections.
    case activeConnections

    case shuttingDown

    /// The server encountered an error while listening or managing connections.
    ///
    /// - Parameter err: An `Error` describing the failure.
    case error(err: Error)

    /// Compares two `ServerListenerState` values for equality.
    ///
    /// This implementation treats all `.error` cases as equal regardless of the specific error value.
    /// If you need to compare error contents, use a custom `EquatableError` wrapper instead.
    public static func == (lhs: SocketServerListeningState, rhs: SocketServerListeningState) -> Bool {
        switch (lhs, rhs) {
        case (.off, .off),
            (.listening, .listening),
            (.activeConnections, .activeConnections):
            return true
        case (.error, .error):
            return true  // Treat any error as equal
        default:
            return false
        }
    }

    public var description: String {
        switch self {
        case .off:
            return "Off"
        case .listening:
            return "Listening"
        case .activeConnections:
            return "Active Connections"
        case .shuttingDown:
            return "Shutting Down..."
        case .error(let message):
            return "Error: \(message)"
        }
    }
}
