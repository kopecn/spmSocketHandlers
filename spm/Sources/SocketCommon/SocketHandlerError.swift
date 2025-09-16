/// An enumeration representing errors that can occur within a socket handler.
public enum SocketHandlerError: Error {
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
}
