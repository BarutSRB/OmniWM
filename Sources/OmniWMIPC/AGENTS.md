# AGENTS.md — Sources/OmniWMIPC

## Purpose

Shared IPC protocol library. Defines all models, wire format, and socket conventions used between the OmniWM daemon and `omniwmctl` CLI. Zero external dependencies.

## Protocol Summary

- **Transport**: Unix domain socket (AF_UNIX, SOCK_STREAM)
- **Wire Format**: NDJSON (newline-delimited JSON, LF-terminated)
- **Max Request Size**: 64 KB
- **Protocol Version**: 4
- **Socket Path**: `~/Library/Caches/com.barut.OmniWM/ipc.sock` (override: `OMNIWM_SOCKET` env)
- **Auth**: Token in `<socket-path>.secret`, included in every request

## File Map (6 files)

- `IPCModels.swift` (2954 lines) — All request/response types, command names (80+), query names (15+), subscription channels (7), error codes
- `IPCAutomationManifest.swift` (1074 lines) — Command/query descriptors with argument kinds, selector definitions, metadata for CLI generation
- `IPCWire.swift` — JSON encoder/decoder for NDJSON protocol
- `IPCSocketPath.swift` — Socket path resolution logic
- `IPCRuleValidator.swift` — Window rule validation utilities
- `WorkspaceAddressing.swift` — Workspace address/identifier helpers

## Conventions

### All Public Types Must Be Sendable
```swift
public enum IPCRequestKind: String, Codable, Equatable, Sendable { ... }
public struct IPCNoPayload: Codable, Equatable, Sendable { ... }
```

### Exhaustive Enums
Command names, query names, subscription channels are all `String`-backed enums for type safety and JSON serialization.

### Versioned Protocol
Protocol version checked on every request. Mismatched versions return `protocol_version_mismatch` error.

## Adding New Commands

1. Add case to `IPCCommandName` enum in `IPCModels.swift`
2. Add descriptor to `IPCAutomationManifest.swift` (arguments, description, selectors)
3. Handle in `IPCCommandRouter` (in `Sources/OmniWM/IPC/`)
4. Add CLI parsing in `Sources/OmniWMCtl/CLIParser.swift`
5. Bump protocol version if breaking change

## Adding New Queries

1. Add case to `IPCQueryName` enum
2. Define response payload struct (must be `Codable, Equatable, Sendable`)
3. Add descriptor to automation manifest
4. Handle in `IPCQueryRouter`
