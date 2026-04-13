# SocketHandlers — Change History

## Unreleased

### New API
- `send(confirming: String) async throws` and `send(confirming: Data) async throws` added to both
  `NIOSocketHandlerServer` and `NIOSocketHandlerClient`. These overloads suspend the caller until
  the write is flushed to the kernel (via `writeAndFlush().whenComplete`), then resume or throw.
  Use them when delivery confirmation or error propagation is required; use the fire-and-forget
  `send(_:)` overloads for high-throughput best-effort sends.

### Bug Fixes
- **`setupChildChannel` race condition** — all state mutations (`connectedClients`,
  `connectionQueue`, `connectionCountByClient`, `lastID`) inside `setupChildChannel` are now
  dispatched to `serverDispatchQueue.async`. Only `syncOperations.addHandler` (NIO pipeline setup)
  remains on the event loop thread.
- **Pre-capture key descriptions in async closures** — `handleClientDisconnection`,
  `closeAllClients`, and `disconnectOldestClient` now pre-capture `String` descriptions of
  `AnyHashable` keys before entering `@Sendable` async closures, eliminating Swift 6 Sendable
  capture warnings.

### Configuration
- `maxCumulationBufferSize: Int` (default 1 MB) added to `ServerConfiguration` and
  `ClientConfiguration`. `NIOStringHandler` checks readable bytes after each append and closes
  the channel with an error log when the limit is exceeded, preventing unbounded memory growth
  from peers that never send a delimiter.
- `tokenizer: String` (default `"\n"`) added to `ServerConfiguration` and `ClientConfiguration`
  to configure the message frame delimiter.

### Documentation
- Comprehensive docstrings added to all four `send()` variants on both `NIOSocketHandlerServer`
  and `NIOSocketHandlerClient`, clarifying: fire-and-forget vs confirmed, String vs Data, offline
  queuing availability, and when to choose each overload.
