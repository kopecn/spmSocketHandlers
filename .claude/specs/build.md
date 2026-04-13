# SocketHandlers — Build & Development

## Commands
```bash
make build                    # swift build -c release
make test                     # swift test --no-parallel
make test-netcat-client-only  # RUN_NETCAT_CLIENT_TESTS=1 swift test (env-gated integration)
make test-netcat-server-only  # RUN_NETCAT_SERVER_TESTS=1 swift test (env-gated integration)
make update-packages          # swift package update
make format                   # swift-format with .swift-format.json config
make mermaid                  # Generate dependency graph
make clean                    # Remove .build/
make bump-patch               # Tag and push patch version bump
make bump-minor               # Tag and push minor version bump
make bump-major               # Tag and push major version bump
make version                  # Show current git tag
make release                  # clean → build → test full release flow
```

## Formatting
- **Tool:** swift-format with `.swift-format.json`
- **Indentation:** 4 spaces
- **Line length:** 120 characters
- **Key rules:** OrderedImports, UseTripleSlashForDocumentation, NoBlockComments, lineBreakBeforeEachArgument

## Testing
- Tests use Swift Testing (`@Test`) framework, not XCTest assertions
- `--no-parallel` required (tests bind to fixed ports: 1234, 2345, 2346, 2347)
- Netcat tests are env-gated: `RUN_NETCAT_CLIENT_TESTS=1` / `RUN_NETCAT_SERVER_TESTS=1`
- Stress tests validate 10k-15k message throughput with deterministic and variable timing
- `netcatEchoTest()` contains an early `return` and is dead code — do not rely on it

## Conventions
- Emoji prefixed log messages for visual scanning in console output
- `weak self` pattern used consistently in async closures to prevent retain cycles
- Configuration objects are value types (`struct`, `Sendable`) with static `.default` factories
- State enums provide `CustomStringConvertible` and custom `Equatable` (errors compare as equal regardless of payload)
