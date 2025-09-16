import Foundation

/// Represents a unique identifier for a client, which can be either a UUID or a name.
///
/// - uuid: Identifies the client using a universally unique identifier.
/// - name: Identifies the client using a string-based name.
///
/// Conforms to `Hashable` and `Sendable` for use in hashed collections and safe concurrency.
public enum ClientID: Hashable, Sendable {
    case uuid(UUID)
    case name(String)
}
