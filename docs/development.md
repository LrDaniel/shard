# Shard development

Shard is a Swift 6 and SwiftUI application targeting macOS 12 and newer. Its
MongoDB process is isolated in `sidecar`, a versioned newline-delimited JSON
protocol adapter running in a bundled ARM64 Node.js 24 runtime.

## Architecture

- `macos/Sources/ShardApp` contains the SwiftUI application and focused AppKit
  bridges.
- `macos/Sources/ShardCore` contains models, SQLite persistence, Keychain
  access, SSH tunneling, and sidecar supervision.
- `sidecar` contains the MongoDB adapter and protocol tests.

Each connection owns a persistent database process so selected databases and
shell variables survive between executions. Standard output is reserved for
protocol messages. Redacted diagnostics use standard error.

## Current capabilities

- Saved connections with authentication, TLS, SSH, replica sets, direct hosts,
  IPv4/IPv6, and SRV connection strings.
- Database and collection explorer with quick open.
- Query tabs with autocomplete, syntax highlighting, history, favorites,
  pagination, cancellation, and explain plans.
- BSON-preserving tree results and dark syntax-aware document views.
- Insert, edit, delete, restore, and collection operation history.
- Index viewing and management.
- Read-only connections and production query safeguards.
- SQLite workspace restoration and macOS Keychain secret storage.

## Development runtime

Run the Swift executable from the repository root so it can locate the sidecar:

```sh
swift run --package-path macos Shard
```

Set `SHARD_SIDECAR_MOCK=1` to exercise the UI without a MongoDB server.
Set `SHARD_NODE_PATH` or `SHARD_SIDECAR_PATH` to override runtime discovery.

## Release checks

Before distributing a build:

1. Run `./macos/scripts/check.sh`.
2. Test connections, authentication, TLS, SSH, CRUD, pagination, cancellation,
   document history, and explain plans.
3. Confirm every bundled executable is ARM64.
4. Confirm credentials do not appear in arguments, logs, history, or
   diagnostics.
5. Test the DMG on a clean macOS account.
