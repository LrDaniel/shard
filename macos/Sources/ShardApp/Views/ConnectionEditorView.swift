import AppKit
#if canImport(ShardCore)
import ShardCore
#endif
import SwiftUI

struct ConnectionEditorSecrets {
    var mongodbPassword: String?
    var sshPassword: String?
    var sshPrivateKeyPassphrase: String?
    var tlsCertificatePassphrase: String?
}

struct ConnectionEditorView: View {
    private static let labelWidth: CGFloat = 142

    private enum TestState: Equatable {
        case idle
        case testing
        case succeeded(String)
        case failed(String)
    }

    private enum Pane: String, CaseIterable, Identifiable {
        case connection = "Connection"
        case authentication = "Authentication"
        case ssh = "SSH"
        case tls = "TLS"
        case advanced = "Advanced"

        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var draft: ConnectionProfile
    @State private var selectedSection = Pane.connection
    @State private var mongodbPassword = ""
    @State private var sshPassword = ""
    @State private var sshKeyPassphrase = ""
    @State private var tlsPassphrase = ""
    @State private var testState = TestState.idle

    let save: (ConnectionProfile, ConnectionEditorSecrets) -> Void

    init(
        profile: ConnectionProfile,
        save: @escaping (ConnectionProfile, ConnectionEditorSecrets) -> Void
    ) {
        _draft = State(initialValue: profile)
        self.save = save
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Picker("Connection settings section", selection: $selectedSection) {
                ForEach(Pane.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollView {
                sectionContent
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
        }
        .frame(width: 680, height: 520)
        .background(ShardTheme.canvas)
        .onChange(of: draft) { _ in resetTestResult() }
        .onChange(of: mongodbPassword) { _ in resetTestResult() }
        .onChange(of: sshPassword) { _ in resetTestResult() }
        .onChange(of: sshKeyPassphrase) { _ in resetTestResult() }
        .onChange(of: tlsPassphrase) { _ in resetTestResult() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("Connection Settings")
                    .font(.title3.weight(.semibold))
                Text(draft.name.isEmpty ? "Configure a MongoDB connection" : draft.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Test Connection", action: testConnection)
                .disabled(!isValid || testState == .testing)

            testStatus

            Spacer()

            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Save") {
                save(draft, editorSecrets)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!isValid)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(ShardTheme.raised.opacity(0.45))
    }

    private var testStatus: some View {
        Group {
            switch testState {
            case .idle:
                Label(
                    validationHint,
                    systemImage: isValid ? "key.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundColor(isValid ? .secondary : .orange)
            case .testing:
                ProgressView()
                    .controlSize(.small)
                Text("Testing…")
                    .foregroundStyle(.secondary)
            case let .succeeded(message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case let .failed(message):
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(message)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .connection:
            connectionSection
        case .authentication:
            authenticationSection
        case .ssh:
            sshSection
        case .tls:
            tlsSection
        case .advanced:
            advancedSection
        }
    }

    private var connectionSection: some View {
        settingsGroup(
            "MongoDB Server",
            description: "Where Shard should connect."
        ) {
            fieldRow("Connection name") {
                TextField("", text: $draft.name)
                    .accessibilityLabel("Connection name")
            }
            fieldRow("Host") {
                TextField("", text: $draft.host)
                    .accessibilityLabel("Host")
            }
            fieldRow("Port") {
                TextField(
                    "",
                    value: $draft.port,
                    format: .number.grouping(.never)
                )
                .accessibilityLabel("Port")
            }
            fieldRow("Default database") {
                TextField("", text: $draft.defaultDatabase)
                    .accessibilityLabel("Default database")
            }
            fieldRow("Connection string") {
                TextField(
                    "",
                    text: optionalBinding(
                        get: { draft.connectionString },
                        set: { draft.connectionString = $0 }
                    )
                )
                .accessibilityLabel("Connection string")
            }
            fieldNote("Optional. A mongodb:// or mongodb+srv:// URI overrides Host and Port.")
        }
    }

    private var authenticationSection: some View {
        settingsGroup(
            "MongoDB Authentication",
            description: "Credentials are stored in macOS Keychain."
        ) {
            fieldRow("Method") {
                Picker("", selection: $draft.authentication) {
                    ForEach(ConnectionProfile.Authentication.allCases, id: \.self) { method in
                        Text(authenticationLabel(method)).tag(method)
                    }
                }
                .labelsHidden()
            }
            fieldRow("Username") {
                TextField("", text: $draft.username)
                    .accessibilityLabel("Username")
                    .disabled(draft.authentication == .none)
            }
            fieldRow("Password") {
                SecureField("", text: $mongodbPassword)
                    .accessibilityLabel("Password")
                    .disabled(draft.authentication == .none)
            }
            if draft.secretReference != nil {
                fieldNote("Leave the password blank to keep the value already stored in Keychain.")
            }
            fieldRow("Authentication database") {
                TextField("", text: $draft.authenticationDatabase)
                    .accessibilityLabel("Authentication database")
                    .disabled(draft.authentication == .none)
            }
        }
    }

    private var sshSection: some View {
        settingsGroup(
            "SSH Tunnel",
            description: "Forward MongoDB traffic through an SSH server."
        ) {
            fieldRow("SSH tunnel") {
                Toggle("Connect through SSH", isOn: $draft.ssh.enabled)
            }
            fieldRow("Host") {
                TextField("", text: $draft.ssh.host)
                    .accessibilityLabel("SSH host")
                    .disabled(!draft.ssh.enabled)
            }
            fieldRow("Port") {
                TextField(
                    "",
                    value: $draft.ssh.port,
                    format: .number.grouping(.never)
                )
                .accessibilityLabel("SSH port")
                .disabled(!draft.ssh.enabled)
            }
            fieldRow("Username") {
                TextField("", text: $draft.ssh.username)
                    .accessibilityLabel("SSH username")
                    .disabled(!draft.ssh.enabled)
            }
            fieldRow("Authentication") {
                Picker("", selection: sshAuthenticationBinding) {
                    Text("SSH Agent").tag(ConnectionProfile.SSH.Authentication.agent)
                    Text("Password").tag(ConnectionProfile.SSH.Authentication.password)
                    Text("Private Key").tag(ConnectionProfile.SSH.Authentication.privateKey)
                }
                .labelsHidden()
                .disabled(!draft.ssh.enabled)
            }

            if sshAuthentication == .password {
                fieldRow("Password") {
                    SecureField("", text: $sshPassword)
                        .accessibilityLabel("SSH password")
                        .disabled(!draft.ssh.enabled)
                }
            } else if sshAuthentication == .privateKey {
                fileField(
                    "Private key",
                    value: optionalBinding(
                        get: { draft.ssh.privateKeyFile },
                        set: { draft.ssh.privateKeyFile = $0 }
                    )
                )
                .disabled(!draft.ssh.enabled)
                fieldRow("Key passphrase") {
                    SecureField("", text: $sshKeyPassphrase)
                        .accessibilityLabel("Private key passphrase")
                        .disabled(!draft.ssh.enabled)
                }
            }

            fieldNote("New SSH hosts are saved to Shard’s private known-hosts file.")
        }
    }

    private var tlsSection: some View {
        settingsGroup(
            "TLS",
            description: "Encrypt the connection and configure certificates."
        ) {
            fieldRow("TLS") {
                Toggle("Use TLS", isOn: $draft.tls.enabled)
            }
            fileField(
                "CA certificate",
                value: optionalBinding(
                    get: { draft.tls.caFile },
                    set: { draft.tls.caFile = $0 }
                )
            )
            .disabled(!draft.tls.enabled)
            fileField(
                "Client certificate/key",
                value: optionalBinding(
                    get: { draft.tls.certificateKeyFile },
                    set: { draft.tls.certificateKeyFile = $0 }
                )
            )
            .disabled(!draft.tls.enabled)
            fieldRow("Passphrase") {
                SecureField("", text: $tlsPassphrase)
                    .accessibilityLabel("Certificate passphrase")
                    .disabled(!draft.tls.enabled)
            }
            fieldRow("Certificate checks") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Allow invalid certificates",
                        isOn: $draft.tls.allowInvalidCertificates
                    )
                    Toggle(
                        "Allow invalid hostnames",
                        isOn: $draft.tls.allowInvalidHostnames
                    )
                }
                .disabled(!draft.tls.enabled)
            }
        }
    }

    private var advancedSection: some View {
        settingsGroup(
            "Connection Options",
            description: "Control safety and server discovery behavior."
        ) {
            fieldRow("Environment") {
                Picker("", selection: environmentBinding) {
                    Text("Development").tag(ConnectionProfile.Environment.development)
                    Text("Staging").tag(ConnectionProfile.Environment.staging)
                    Text("Production").tag(ConnectionProfile.Environment.production)
                }
                .labelsHidden()
            }
            fieldRow("Safety") {
                Toggle("Read-only connection", isOn: readOnlyBinding)
            }
            fieldRow("Replica set") {
                TextField(
                    "",
                    text: optionalBinding(
                        get: { draft.replicaSet },
                        set: { draft.replicaSet = $0 }
                    )
                )
                .accessibilityLabel("Replica set name")
            }
            fieldRow("Connection mode") {
                Toggle("Direct connection", isOn: $draft.directConnection)
            }
            fieldNote("Production warns before high-risk commands; read-only blocks writes.")
            fieldNote("SSH tunnels use a direct MongoDB connection through the forwarded port.")
        }
    }

    private var environmentBinding: Binding<ConnectionProfile.Environment> {
        Binding(
            get: { draft.effectiveEnvironment },
            set: { draft.environment = $0 }
        )
    }

    private var readOnlyBinding: Binding<Bool> {
        Binding(
            get: { draft.isReadOnly },
            set: { draft.readOnly = $0 }
        )
    }

    private var sshAuthentication: ConnectionProfile.SSH.Authentication {
        draft.ssh.authentication
            ?? (draft.ssh.privateKeyFile == nil ? .agent : .privateKey)
    }

    private var sshAuthenticationBinding: Binding<ConnectionProfile.SSH.Authentication> {
        Binding(
            get: { sshAuthentication },
            set: { draft.ssh.authentication = $0 }
        )
    }

    private var isValid: Bool {
        guard !draft.name.isEmpty,
              !draft.host.isEmpty,
              (1...65_535).contains(draft.port) else {
            return false
        }
        if draft.ssh.enabled {
            return !draft.ssh.host.isEmpty
                && !draft.ssh.username.isEmpty
                && (1...65_535).contains(draft.ssh.port)
        }
        return true
    }

    private var validationHint: String {
        isValid ? "Secrets are stored in macOS Keychain." : "Complete the required fields."
    }

    private func testConnection() {
        guard isValid, testState != .testing else { return }
        let testedProfile = draft
        let testedSecrets = editorSecrets
        testState = .testing
        Task {
            do {
                let message = try await model.testConnection(
                    testedProfile,
                    secrets: testedSecrets
                )
                guard draft == testedProfile else {
                    testState = .idle
                    return
                }
                testState = .succeeded(message)
            } catch {
                guard draft == testedProfile else {
                    testState = .idle
                    return
                }
                testState = .failed(error.localizedDescription)
            }
        }
    }

    private func resetTestResult() {
        guard testState != .testing else { return }
        testState = .idle
    }

    private var editorSecrets: ConnectionEditorSecrets {
        ConnectionEditorSecrets(
            mongodbPassword: nonempty(mongodbPassword),
            sshPassword: nonempty(sshPassword),
            sshPrivateKeyPassphrase: nonempty(sshKeyPassphrase),
            tlsCertificatePassphrase: nonempty(tlsPassphrase)
        )
    }

    private func authenticationLabel(
        _ method: ConnectionProfile.Authentication
    ) -> String {
        switch method {
        case .none: return "None"
        case .scramSHA1: return "SCRAM-SHA-1"
        case .scramSHA256: return "SCRAM-SHA-256"
        case .x509: return "X.509"
        }
    }

    private func optionalBinding(
        get: @escaping () -> String?,
        set: @escaping (String?) -> Void
    ) -> Binding<String> {
        Binding(
            get: { get() ?? "" },
            set: { set(nonempty($0)) }
        )
    }

    private func nonempty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private func settingsGroup<Content: View>(
        _ title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ShardTheme.raised.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private func fieldRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fieldNote(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Color.clear
                .frame(width: Self.labelWidth, height: 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func fileField(_ title: String, value: Binding<String>) -> some View {
        fieldRow(title) {
            HStack(spacing: 8) {
                TextField("", text: value)
                    .accessibilityLabel(title)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK {
                        value.wrappedValue = panel.url?.path ?? ""
                    }
                }
            }
        }
    }
}
