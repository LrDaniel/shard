import Foundation

public enum SidecarOperation: String, Codable, Sendable {
    case connect
    case disconnect
    case ping
    case execute
    case fetchCursorPage
    case cancel
    case autocomplete
    case explain
    case listDatabases
    case listCollections
    case listIndexes
    case sampleSchema
    case createIndex
    case dropIndex
    case parseShellDocument
}

public struct SidecarRequest: Codable, Identifiable, Sendable {
    public static let protocolVersion = 1

    public let protocolVersion: Int
    public let id: UUID
    public let operation: SidecarOperation
    public let payload: JSONValue

    public init(
        id: UUID = UUID(),
        operation: SidecarOperation,
        payload: JSONValue = .object([:])
    ) {
        protocolVersion = Self.protocolVersion
        self.id = id
        self.operation = operation
        self.payload = payload
    }
}

public struct SidecarError: Codable, LocalizedError, Equatable, Sendable {
    public let code: String
    public let message: String
    public let details: JSONValue?
    public let retryable: Bool
    public let connected: Bool

    public init(
        code: String,
        message: String,
        details: JSONValue? = nil,
        retryable: Bool = false,
        connected: Bool = false
    ) {
        self.code = code
        self.message = message
        self.details = details
        self.retryable = retryable
        self.connected = connected
    }

    public var errorDescription: String? {
        message
    }
}

public struct SidecarResponse: Codable, Sendable {
    public let protocolVersion: Int
    public let id: UUID
    public let result: JSONValue?
    public let error: SidecarError?

    public init(
        protocolVersion: Int = SidecarRequest.protocolVersion,
        id: UUID,
        result: JSONValue? = nil,
        error: SidecarError? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.result = result
        self.error = error
    }
}

public enum SidecarClientError: LocalizedError, Sendable {
    case notRunning
    case invalidResponse
    case protocolMismatch(Int)
    case processExited(Int32)
    case remote(SidecarError)

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return "The MongoDB runtime is not running."
        case .invalidResponse:
            return "The MongoDB runtime returned an invalid response."
        case let .protocolMismatch(version):
            return "Unsupported MongoDB runtime protocol version \(version)."
        case let .processExited(code):
            return "The MongoDB runtime exited with status \(code)."
        case let .remote(error):
            return error.message
        }
    }
}
