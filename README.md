# Shard

Shard is a native MongoDB client for Apple Silicon Macs. It combines a compact
database explorer, a persistent shell-style query workspace, structured BSON
results, document editing, index management, query history, explain plans, and
production-safety controls in a local-first application.

## Requirements

- Apple Silicon Mac
- macOS 12 or newer
- Xcode with Swift 6
- A MongoDB 4.0–8.x server

The distributable application bundles its own ARM64 Node.js runtime and does
not require Homebrew or a separately installed Node.js runtime.

## Open in Xcode

Open `macos/Shard.xcodeproj`, choose the **Shard** scheme, and press `Cmd+R`.

The project includes two shared schemes:

- **Shard** builds and runs the application.
- **Shard DMG** builds a release DMG in `macos/dist`.

## Build and test

```sh
./macos/scripts/check.sh
```

For local sidecar development:

```sh
nvm use
npm ci --prefix sidecar
npm test --prefix sidecar
swift test --package-path macos
```

## Create a DMG

Use the **Shard DMG** scheme in Xcode, or run:

```sh
nvm use
SHARD_NODE_BINARY="$(command -v node)" ./macos/scripts/package-app.sh
```

Packaging requires an ARM64 Node.js 24 executable. The generated application
and DMG are written to `macos/dist`.

## Privacy and security

- No account, telemetry, analytics, cloud backend, or AI service.
- Connection secrets are stored in macOS Keychain.
- Credentials are sent to the local database runtime through stdin and are
  redacted from logs and diagnostics.
- SSH host keys are stored in an application-specific known-hosts file.
- Application state and bounded query history are stored locally in SQLite.

See [Development](docs/development.md) for architecture and runtime details.

## License

GPL-3.0. See [LICENSE](LICENSE).
