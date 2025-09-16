import NIOCore
import SocketCommon

/// Represents a client that is connected to the server, identified by a unique `ClientID` and associated with a specific `Channel`.
///
/// - Parameters:
///   - id: The unique identifier for the connected client.
///   - channel: The channel through which the client communicates with the server.
public struct ConnectedClient {
    let id: ClientID
    let channel: Channel
}
