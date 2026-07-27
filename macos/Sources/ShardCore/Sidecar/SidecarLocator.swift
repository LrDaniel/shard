import Foundation

public enum SidecarLocator {
    public static func configuration(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> SidecarProcess.Configuration {
        if let explicitPath = environment["SHARD_SIDECAR_PATH"] {
            return nodeConfiguration(
                scriptURL: URL(fileURLWithPath: explicitPath),
                environment: environment
            )
        }

        if let resourceURL = bundle.resourceURL {
            let bundledNode = resourceURL.appendingPathComponent("runtime/node")
            let bundledSidecar = resourceURL.appendingPathComponent("sidecar/index.js")
            if FileManager.default.isExecutableFile(atPath: bundledNode.path),
               FileManager.default.fileExists(atPath: bundledSidecar.path) {
                return SidecarProcess.Configuration(
                    executableURL: bundledNode,
                    arguments: [bundledSidecar.path]
                )
            }
        }

        let candidates = [
            workingDirectory.appendingPathComponent("../sidecar/index.js"),
            workingDirectory.appendingPathComponent("sidecar/index.js"),
            sourceTreeSidecarURL
        ]
        if let scriptURL = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.standardizedFileURL.path)
        }) {
            return nodeConfiguration(
                scriptURL: scriptURL.standardizedFileURL,
                environment: environment
            )
        }

        throw SidecarError(
            code: "runtime_not_found",
            message: "Could not find the Shard MongoDB runtime."
        )
    }

    private static func nodeConfiguration(
        scriptURL: URL,
        environment: [String: String]
    ) -> SidecarProcess.Configuration {
        if let nodePath = environment["SHARD_NODE_PATH"] {
            return SidecarProcess.Configuration(
                executableURL: URL(fileURLWithPath: nodePath),
                arguments: [scriptURL.path]
            )
        }

        if let nodeURL = developmentNodeURL(environment: environment) {
            return SidecarProcess.Configuration(
                executableURL: nodeURL,
                arguments: [scriptURL.path]
            )
        }

        return SidecarProcess.Configuration(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", scriptURL.path]
        )
    }

    private static var sourceTreeSidecarURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sidecar
            .deletingLastPathComponent() // ShardCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // repository
            .appendingPathComponent("sidecar/index.js")
    }

    private static func developmentNodeURL(environment: [String: String]) -> URL? {
        let fileManager = FileManager.default
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
        let standardCandidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node")
        ]

        if let candidate = (pathCandidates + standardCandidates).first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) {
            return candidate
        }

        let versionsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let installedVersions = (try? fileManager.contentsOfDirectory(
            at: versionsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return installedVersions
            .sorted { $0.lastPathComponent.compare(
                $1.lastPathComponent,
                options: .numeric
            ) == .orderedDescending }
            .map { $0.appendingPathComponent("bin/node") }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
