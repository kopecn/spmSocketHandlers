/// A protocol that defines an asynchronous message handler.
///
/// Conforming types are expected to handle incoming messages represented as `String` values.
/// The handler method is asynchronous and can be used in concurrent contexts.
///
/// - Note: Conforming types must be classes (`AnyObject`) and support concurrency (`Sendable`).
public protocol MessageHandling: AnyObject, Sendable {
    /// Handles an incoming message asynchronously.
    ///
    /// - Parameter message: The message to be handled, represented as a `String`.
    func handleMessage(_ message: String) async
}
