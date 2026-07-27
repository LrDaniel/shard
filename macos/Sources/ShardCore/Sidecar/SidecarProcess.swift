import Foundation

public final class SidecarProcess: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let executableURL: URL
        public let arguments: [String]
        public let environment: [String: String]

        public init(
            executableURL: URL,
            arguments: [String],
            environment: [String: String] = [:]
        ) {
            self.executableURL = executableURL
            self.arguments = arguments
            self.environment = environment
        }
    }

    private let configuration: Configuration
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let diagnostics = Pipe()
    private let requestLock = NSLock()
    private var readBuffer = Data()

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        stop()
    }

    public var isRunning: Bool {
        process.isRunning
    }

    public func start() throws {
        guard !process.isRunning else { return }
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics
        process.environment = ProcessInfo.processInfo.environment.merging(
            configuration.environment,
            uniquingKeysWith: { _, configured in configured }
        )
        try process.run()
    }

    public func stop() {
        guard process.isRunning else { return }
        input.fileHandleForWriting.closeFile()
        process.terminate()
        process.waitUntilExit()
    }

    public func request(_ request: SidecarRequest) async throws -> SidecarResponse {
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)

        return try await Task.detached(priority: .userInitiated) { [self] in
            try performRequest(request, encodedRequest: data)
        }.value
    }

    private func performRequest(
        _ request: SidecarRequest,
        encodedRequest: Data
    ) throws -> SidecarResponse {
        requestLock.lock()
        defer { requestLock.unlock() }

        guard process.isRunning else {
            throw SidecarClientError.notRunning
        }
        try input.fileHandleForWriting.write(contentsOf: encodedRequest)
        let responseData = try readResponseLine()
        guard !responseData.isEmpty else {
            throw SidecarClientError.processExited(process.terminationStatus)
        }

        let response: SidecarResponse
        do {
            response = try JSONDecoder().decode(SidecarResponse.self, from: responseData)
        } catch {
            throw SidecarClientError.invalidResponse
        }
        guard response.protocolVersion == SidecarRequest.protocolVersion else {
            throw SidecarClientError.protocolMismatch(response.protocolVersion)
        }
        guard response.id == request.id else {
            throw SidecarClientError.invalidResponse
        }
        if let error = response.error {
            throw SidecarClientError.remote(error)
        }
        return response
    }

    public func recentDiagnostics(maximumBytes: Int = 8_192) -> String {
        let data = diagnostics.fileHandleForReading.availableData
        return String(decoding: data.suffix(maximumBytes), as: UTF8.self)
    }

    private func readResponseLine() throws -> Data {
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[..<newline]
                readBuffer.removeSubrange(...newline)
                return Data(line)
            }

            let next = output.fileHandleForReading.availableData
            if next.isEmpty {
                return Data()
            }
            readBuffer.append(next)
        }
    }
}
