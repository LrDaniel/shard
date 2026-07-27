import Darwin
import Foundation

public final class SSHTunnel: @unchecked Sendable {
    public enum TunnelError: LocalizedError {
        case invalidConfiguration(String)
        case localPort
        case launch(String)

        public var errorDescription: String? {
            switch self {
            case let .invalidConfiguration(message):
                return message
            case .localPort:
                return "Could not reserve a local port for the SSH tunnel."
            case let .launch(message):
                return "SSH tunnel failed: \(message)"
            }
        }
    }

    private let profile: ConnectionProfile
    private let password: String?
    private let privateKeyPassphrase: String?
    private let process = Process()
    private let diagnostics = Pipe()
    private var askPassURL: URL?
    private var askPassSecretURL: URL?

    public init(
        profile: ConnectionProfile,
        password: String?,
        privateKeyPassphrase: String?
    ) {
        self.profile = profile
        self.password = password
        self.privateKeyPassphrase = privateKeyPassphrase
    }

    deinit {
        stop()
    }

    public func start() async throws -> Int {
        guard profile.ssh.enabled else {
            throw TunnelError.invalidConfiguration("SSH tunneling is not enabled.")
        }
        guard !profile.ssh.host.isEmpty, !profile.ssh.username.isEmpty else {
            throw TunnelError.invalidConfiguration(
                "SSH host and username are required."
            )
        }

        let localPort = try Self.availableLocalPort()
        let knownHostsURL = try Self.knownHostsURL()
        var arguments = [
            "-N",
            "-T",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsURL.path)",
            "-o", "NumberOfPasswordPrompts=1",
            "-p", String(profile.ssh.port),
            "-L", "127.0.0.1:\(localPort):\(profile.host):\(profile.port)"
        ]

        let authentication = profile.ssh.authentication
            ?? (profile.ssh.privateKeyFile == nil ? .agent : .privateKey)
        let promptSecret: String?
        if authentication == .privateKey,
           let privateKeyFile = profile.ssh.privateKeyFile,
           !privateKeyFile.isEmpty {
            arguments.append(contentsOf: ["-i", privateKeyFile])
            promptSecret = privateKeyPassphrase
        } else if authentication == .password, let password, !password.isEmpty {
            arguments.append(contentsOf: [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no"
            ])
            promptSecret = password
        } else {
            arguments.append(contentsOf: ["-o", "BatchMode=yes"])
            promptSecret = nil
        }
        arguments.append("\(profile.ssh.username)@\(profile.ssh.host)")

        var environment = ProcessInfo.processInfo.environment
        if let promptSecret, !promptSecret.isEmpty {
            let helperURL = try Self.makeAskPassHelper()
            let secretURL = try Self.makeSecretFile(promptSecret)
            askPassURL = helperURL
            askPassSecretURL = secretURL
            environment["SSH_ASKPASS"] = helperURL.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "shard:0"
            environment["SHARD_SSH_SECRET_FILE"] = secretURL.path
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = diagnostics
        try process.run()

        try await Task.sleep(nanoseconds: 400_000_000)
        guard process.isRunning else {
            let message = String(
                decoding: diagnostics.fileHandleForReading.availableData,
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw TunnelError.launch(message.isEmpty ? "The SSH process exited." : message)
        }
        return localPort
    }

    public func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        if let askPassURL {
            try? FileManager.default.removeItem(at: askPassURL)
            self.askPassURL = nil
        }
        if let askPassSecretURL {
            try? FileManager.default.removeItem(at: askPassSecretURL)
            self.askPassSecretURL = nil
        }
    }

    private static func availableLocalPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TunnelError.localPort }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindStatus = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindStatus == 0 else { throw TunnelError.localPort }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameStatus == 0 else { throw TunnelError.localPort }
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    private static func supportDirectory() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Shard", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func knownHostsURL() throws -> URL {
        let url = try supportDirectory().appendingPathComponent("ssh_known_hosts")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
        }
        return url
    }

    private static func makeAskPassHelper() throws -> URL {
        let url = try supportDirectory()
            .appendingPathComponent("ssh-askpass-\(UUID().uuidString)")
        let source = """
        #!/bin/sh
        /bin/cat "$SHARD_SSH_SECRET_FILE"
        """
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        return url
    }

    private static func makeSecretFile(_ secret: String) throws -> URL {
        let url = try supportDirectory()
            .appendingPathComponent("ssh-secret-\(UUID().uuidString)")
        try Data(secret.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url
    }
}
