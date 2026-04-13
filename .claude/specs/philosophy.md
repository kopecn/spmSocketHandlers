# SocketHandlers — Design Philosophy

## Facade Pattern — Intentional Simplicity
The end-user API is deliberately a **single-object facade**: one `NIOSocketHandlerServer` to run a server,
one `NIOSocketHandlerClient` to connect to one. The consumer should never need to touch NIO channels,
event loops, byte buffers, or handler pipelines directly. This is the primary design goal.

This means the facade classes intentionally consolidate responsibilities (connection lifecycle,
message dispatch, queuing, metrics, state publishing) behind a single entry point. Internally,
these responsibilities can and should be decomposed into focused types — but the **public API
surface stays minimal**. Refactoring for SOLID applies to the internal architecture, not the
consumer-facing shape.

**Guiding rule:** If a refactor adds a type the end-user must instantiate or configure, it needs
strong justification. Internal extractions (used only inside the facade) are always welcome.

## Planned Features
- Timeout and reconnect handling improvements
- `MessageFramer` protocol abstraction to enable Modbus / length-prefixed / binary stream tokenization as plug-in conformances
- Community examples for easier adoption
