import Foundation

public struct ImportedConnectionSecrets: Equatable, Sendable {
    public var mongodbPassword: String?
    public var sshPassword: String?
    public var sshPrivateKeyPassphrase: String?
    public var tlsCertificatePassphrase: String?

    public init(
        mongodbPassword: String? = nil,
        sshPassword: String? = nil,
        sshPrivateKeyPassphrase: String? = nil,
        tlsCertificatePassphrase: String? = nil
    ) {
        self.mongodbPassword = mongodbPassword
        self.sshPassword = sshPassword
        self.sshPrivateKeyPassphrase = sshPrivateKeyPassphrase
        self.tlsCertificatePassphrase = tlsCertificatePassphrase
    }
}

public struct ImportedConnection: Equatable, Sendable {
    public var profile: ConnectionProfile
    public var secrets: ImportedConnectionSecrets

    public init(
        profile: ConnectionProfile,
        secrets: ImportedConnectionSecrets
    ) {
        self.profile = profile
        self.secrets = secrets
    }
}

public struct ConnectionImportResult: Equatable, Sendable {
    public var connections: [ImportedConnection]
    public var warnings: [String]

    public init(
        connections: [ImportedConnection],
        warnings: [String]
    ) {
        self.connections = connections
        self.warnings = warnings
    }
}

public enum ConnectionImportError: LocalizedError {
    case unreadableConfiguration
    case invalidConfiguration
    case noConnections

    public var errorDescription: String? {
        switch self {
        case .unreadableConfiguration:
            return "The selected configuration file could not be read."
        case .invalidConfiguration:
            return "The selected file is not a supported connection configuration."
        case .noConnections:
            return "The selected configuration does not contain any connections."
        }
    }
}

public struct ConnectionImportService: Sendable {
    public init() {}

    public func discoverConfiguration(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let roots = [
            homeDirectory.appendingPathComponent(".3T", isDirectory: true),
            homeDirectory.appendingPathComponent(".config", isDirectory: true)
        ]
        let candidates = roots.flatMap(configurationCandidates)
        return candidates.sorted(by: newestConfigurationFirst).first
    }

    public func importConnections(from configurationURL: URL) throws -> ConnectionImportResult {
        guard let data = try? Data(contentsOf: configurationURL) else {
            throw ConnectionImportError.unreadableConfiguration
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawConnections = root["connections"] as? [[String: Any]] else {
            throw ConnectionImportError.invalidConfiguration
        }
        guard !rawConnections.isEmpty else {
            throw ConnectionImportError.noConnections
        }

        let key = encryptionKey(near: configurationURL)
        var warnings: [String] = []
        let connections = rawConnections.compactMap { raw -> ImportedConnection? in
            connection(from: raw, key: key, warnings: &warnings)
        }
        guard !connections.isEmpty else {
            throw ConnectionImportError.noConnections
        }
        return ConnectionImportResult(connections: connections, warnings: warnings)
    }

    private func configurationCandidates(in root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
              ) else {
            return []
        }

        var matches: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "json" {
            guard isConnectionConfiguration(url) else { continue }
            matches.append(url)
        }
        return matches
    }

    private func isConnectionConfiguration(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["connections"] is [[String: Any]] else {
            return false
        }
        return true
    }

    private func newestConfigurationFirst(_ lhs: URL, _ rhs: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let leftDate = try? lhs.resourceValues(forKeys: keys).contentModificationDate
        let rightDate = try? rhs.resourceValues(forKeys: keys).contentModificationDate
        return (leftDate ?? .distantPast) > (rightDate ?? .distantPast)
    }

    private func connection(
        from raw: [String: Any],
        key: UInt64?,
        warnings: inout [String]
    ) -> ImportedConnection? {
        let name = string(raw["connectionName"]) ?? "Imported Connection"
        let host = string(raw["serverHost"]) ?? "localhost"
        let port = integer(raw["serverPort"]) ?? 27017
        guard (1...65_535).contains(port) else {
            warnings.append("\(name): invalid port; connection was skipped.")
            return nil
        }

        var profile = ConnectionProfile(
            name: name,
            host: host,
            port: port,
            defaultDatabase: nonempty(string(raw["defaultDatabase"])) ?? "test"
        )
        var importedSecrets = ImportedConnectionSecrets()

        if bool(raw["isReplicaSet"]),
           let replica = raw["replicaSet"] as? [String: Any] {
            profile.replicaSet = nonempty(string(replica["setNameUserEntered"]))
                ?? nonempty(string(replica["cachedSetName"]))
        }

        if let credentials = raw["credentials"] as? [[String: Any]],
           let credential = credentials.first(where: { bool($0["enabled"]) }) {
            profile.username = string(credential["userName"]) ?? ""
            profile.authenticationDatabase = nonempty(string(credential["databaseName"])) ?? "admin"
            profile.authentication = authentication(
                from: string(credential["mechanism"])
            )
            importedSecrets.mongodbPassword = secret(
                plaintext: string(credential["userPassword"]),
                encrypted: string(credential["userPasswordEncrypted"]),
                key: key,
                connectionName: name,
                label: "database password",
                warnings: &warnings
            )
        }

        if let ssh = raw["ssh"] as? [String: Any], bool(ssh["enabled"]) {
            profile.ssh.enabled = true
            profile.ssh.host = string(ssh["host"]) ?? ""
            profile.ssh.port = integer(ssh["port"]) ?? 22
            profile.ssh.username = string(ssh["userName"]) ?? ""
            profile.ssh.privateKeyFile = nonempty(string(ssh["privateKeyFile"]))
            let method = string(ssh["method"])?.lowercased()
            profile.ssh.authentication = method == "password" ? .password : .privateKey
            importedSecrets.sshPassword = secret(
                plaintext: string(ssh["userPassword"]),
                encrypted: string(ssh["userPasswordEncrypted"]),
                key: key,
                connectionName: name,
                label: "SSH password",
                warnings: &warnings
            )
            importedSecrets.sshPrivateKeyPassphrase = secret(
                plaintext: string(ssh["passphrase"]),
                encrypted: string(ssh["passphraseEncrypted"]),
                key: key,
                connectionName: name,
                label: "SSH key passphrase",
                warnings: &warnings
            )
            warnIfMissingFile(
                profile.ssh.privateKeyFile,
                connectionName: name,
                label: "SSH private key",
                warnings: &warnings
            )
        }

        if let tls = raw["ssl"] as? [String: Any], bool(tls["sslEnabled"]) {
            profile.tls.enabled = true
            profile.tls.caFile = nonempty(string(tls["caFile"]))
            profile.tls.certificateKeyFile = nonempty(string(tls["pemKeyFile"]))
            profile.tls.allowInvalidCertificates = bool(tls["allowInvalidCertificates"])
            profile.tls.allowInvalidHostnames = bool(tls["allowInvalidHostnames"])
            importedSecrets.tlsCertificatePassphrase = secret(
                plaintext: string(tls["pemPassPhrase"]),
                encrypted: string(tls["pemPassPhraseEncrypted"]),
                key: key,
                connectionName: name,
                label: "TLS certificate passphrase",
                warnings: &warnings
            )
            warnIfMissingFile(
                profile.tls.caFile,
                connectionName: name,
                label: "TLS CA file",
                warnings: &warnings
            )
            warnIfMissingFile(
                profile.tls.certificateKeyFile,
                connectionName: name,
                label: "TLS certificate",
                warnings: &warnings
            )
        }

        return ImportedConnection(profile: profile, secrets: importedSecrets)
    }

    private func authentication(from mechanism: String?) -> ConnectionProfile.Authentication {
        switch mechanism?.uppercased() {
        case "SCRAM-SHA-256":
            return .scramSHA256
        case "MONGODB-X509":
            return .x509
        default:
            return .scramSHA1
        }
    }

    private func secret(
        plaintext: String?,
        encrypted: String?,
        key: UInt64?,
        connectionName: String,
        label: String,
        warnings: inout [String]
    ) -> String? {
        if let plaintext = nonempty(plaintext) {
            return plaintext
        }
        guard let encrypted = nonempty(encrypted) else { return nil }
        guard let key,
              let decrypted = LegacySecretDecoder.decrypt(encrypted, key: key) else {
            warnings.append("\(connectionName): \(label) must be entered again.")
            return nil
        }
        return decrypted
    }

    private func encryptionKey(near configurationURL: URL) -> UInt64? {
        var folder = configurationURL.deletingLastPathComponent()
        for _ in 0..<4 {
            if let files = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for file in files where file.pathExtension.lowercased() == "key" {
                    guard let value = try? String(contentsOf: file, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                          let key = UInt64(value) else {
                        continue
                    }
                    return key
                }
            }
            let parent = folder.deletingLastPathComponent()
            guard parent != folder else { break }
            folder = parent
        }
        return nil
    }

    private func warnIfMissingFile(
        _ path: String?,
        connectionName: String,
        label: String,
        warnings: inout [String]
    ) {
        guard let path = nonempty(path),
              !FileManager.default.fileExists(atPath: path) else {
            return
        }
        warnings.append("\(connectionName): \(label) was not found.")
    }

    private func string(_ value: Any?) -> String? {
        value as? String
    }

    private func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func bool(_ value: Any?) -> Bool {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return ["1", "true", "yes"].contains(string.lowercased())
        }
        return false
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private enum LegacySecretDecoder {
    private static let compressionFlag: UInt8 = 0x01
    private static let checksumFlag: UInt8 = 0x02
    private static let hashFlag: UInt8 = 0x04

    static func decrypt(_ encoded: String, key: UInt64) -> String? {
        guard let cipher = Data(base64Encoded: encoded),
              cipher.count >= 3,
              cipher[0] == 3 else {
            return nil
        }
        let flags = cipher[1]
        guard flags & compressionFlag == 0 else {
            return nil
        }

        let keyBytes = (0..<8).map { offset in
            UInt8(truncatingIfNeeded: key >> UInt64(offset * 8))
        }
        let encrypted = Array(cipher.dropFirst(2))
        var decrypted = [UInt8]()
        decrypted.reserveCapacity(encrypted.count)
        var previous: UInt8 = 0
        for (index, byte) in encrypted.enumerated() {
            decrypted.append(byte ^ previous ^ keyBytes[index % keyBytes.count])
            previous = byte
        }
        guard !decrypted.isEmpty else { return nil }
        decrypted.removeFirst()
        if flags & checksumFlag != 0 {
            guard decrypted.count >= 2 else { return nil }
            decrypted.removeFirst(2)
        } else if flags & hashFlag != 0 {
            guard decrypted.count >= 20 else { return nil }
            decrypted.removeFirst(20)
        }
        return String(bytes: decrypted, encoding: .utf8)
    }
}
