/// Extension for `Task` where `Success` is `Void` and `Failure` is `Error`,
/// providing a method to bridge Swift concurrency with NIO's `EventLoopFuture`.
///
/// - Method: `futureResult(on:)`
///   - Parameters:
///     - eventLoop: The `EventLoop` on which the resulting future will be completed.
///   - Returns: An `EventLoopFuture<Void>` that is completed when the task finishes.
///     If the task succeeds, the future succeeds with `Void`. If the task fails, the future fails with the task's error.
///   - Discussion:
///     This method allows interoperability between Swift's async/await tasks and NIO's future-based APIs,
///     enabling you to await a task and obtain its result as an `EventLoopFuture` on a specified event loop.
import NIOCore

extension Task where Success == Void, Failure == Error {
    func futureResult(on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        Task {
            do {
                _ = try await self.value
                promise.succeed(())
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }
}
