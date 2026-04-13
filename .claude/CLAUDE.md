# SocketHandlers — Project Specification

## Overview
A Swift Package Manager library providing a lightweight SwiftNIO wrapper for ASCII/text-based TCP socket communication. Exposes `NIOSocketHandlerServer` and `NIOSocketHandlerClient` as the primary public API surface, built on top of Apple's SwiftNIO for high-performance async networking.

**Package name:** `SocketHandlers`
**Library product:** `NIOHandler` (the exported library target name)
**Swift tools version:** 6.1
**Declared platform:** macOS 14 (Linux ARM/x86 is a required deployment target — `Package.swift` needs updating; see `todo.md`)
**License:** MIT

## Critical Rule — Facade Pattern
The end-user API is a **single-object facade**: one `NIOSocketHandlerServer`, one `NIOSocketHandlerClient`. Do not add types the consumer must instantiate or configure. Internal extractions are always welcome; changes to the public API shape require strong justification. See `specs/philosophy.md` for full context.

## Subspecs — Read These When Needed

| File | What it covers |
|---|---|
| `specs/architecture.md` | Module structure (full file tree), external dependencies, protocol conformances, concurrency model, data flow |
| `specs/build.md` | `make` commands, formatting rules, testing conventions, code style |
| `specs/philosophy.md` | Design philosophy, facade rationale, planned features |
| `specs/checklist.md` | Improvement checklist — correctness, Swift 6 compliance, determinism, performance, SOLID, testing, package/build |

## At a Glance — Key Conventions
- Tests use Swift Testing (`@Test`), not XCTest — always run with `--no-parallel` (fixed ports 1234, 2345–2347)
- Log messages are emoji-prefixed for visual scanning
- Configuration objects are value types (`struct`, `Sendable`) with static `.default` factories
- `weak self` used consistently in async closures to prevent retain cycles
- State enums provide `CustomStringConvertible` and custom `Equatable` (error cases compare equal regardless of payload)
- Both classes expose `send(confirming:) async throws` (confirmed delivery) in addition to fire-and-forget `send(_:) -> Bool`
