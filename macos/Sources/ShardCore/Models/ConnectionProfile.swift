import Foundation

public struct ConnectionProfile: Codable, Identifiable, Equatable, Sendable {
    public enum Environment: String, Codable, CaseIterable, Sendable {
        case development
        case staging
        case production
    }

    public enum Authentication: String, Codable, CaseIterable, Sendable {
        case none
        case scramSHA1
        case scramSHA256
        case x509
    }

    public struct TLS: Codable, Equatable, Sendable {
        public var enabled = false
        public var caFile: String?
        public var certificateKeyFile: String?
        public var certificatePassphraseReference: String?
        public var allowInvalidCertificates = false
        public var allowInvalidHostnames = false

        public init() {}
    }

    public struct SSH: Codable, Equatable, Sendable {
        public enum Authentication: String, Codable, CaseIterable, Sendable {
            case agent
            case password
            case privateKey
        }

        public var enabled = false
        public var host = ""
        public var port = 22
        public var username = ""
        public var authentication: Authentication?
        public var privateKeyFile: String?
        public var passwordSecretReference: String?
        public var privateKeyPassphraseReference: String?
        public var hostKeyFingerprint: String?

        public init() {}
    }

    public let id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var connectionString: String?
    public var defaultDatabase: String
    public var replicaSet: String?
    public var directConnection: Bool
    public var authentication: Authentication
    public var username: String
    public var authenticationDatabase: String
    public var secretReference: String?
    public var tls: TLS
    public var ssh: SSH
    public var environment: Environment?
    public var readOnly: Bool?

    public init(
        id: UUID = UUID(),
        name: String = "Local MongoDB",
        host: String = "localhost",
        port: Int = 27017,
        defaultDatabase: String = "test"
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        connectionString = nil
        self.defaultDatabase = defaultDatabase
        replicaSet = nil
        directConnection = false
        authentication = .none
        username = ""
        authenticationDatabase = "admin"
        secretReference = nil
        tls = TLS()
        ssh = SSH()
        environment = .development
        readOnly = false
    }

    public var effectiveEnvironment: Environment {
        environment ?? .development
    }

    public var isReadOnly: Bool {
        readOnly == true
    }
}
