#if canImport(ShardCore)
import ShardCore
#endif
import SwiftUI

struct ConnectionManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var editingProfile: ConnectionProfile?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            connectionTable
            Divider()
            footer
        }
        .frame(width: 820, height: 500)
        .sheet(item: $editingProfile) { profile in
            ConnectionEditorView(profile: profile) { saved, secrets in
                model.saveConnection(saved, secrets: secrets)
                editingProfile = nil
            }
        }
        .alert("Delete Connection?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                model.deleteSelectedConnection()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected connection and its stored secrets will be removed.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("MongoDB Connections")
                    .font(.title2.weight(.semibold))
                Text("Choose a connection to open, or manage your saved connections.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.connectionState == .connecting {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var connectionTable: some View {
        Table(model.connections, selection: $model.selectedConnectionID) {
            TableColumn("Name") { profile in
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionStatusColor(for: profile))
                        .frame(width: 7, height: 7)
                    Text(profile.name)
                        .lineLimit(1)
                }
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            model.selectedConnectionID = profile.id
                            connect()
                        }
                    )
            }
            .width(min: 130, ideal: 180)

            TableColumn("Address") { profile in
                Text(address(for: profile))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 160, ideal: 210)

            TableColumn("Environment") { profile in
                Text(environmentLabel(profile.effectiveEnvironment))
                    .foregroundStyle(
                        profile.effectiveEnvironment == .production
                            ? .red
                            : .secondary
                    )
            }
            .width(min: 80, ideal: 100)

            TableColumn("Options") { profile in
                Text(options(for: profile))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 130, ideal: 180)

            TableColumn("Authentication") { profile in
                Text(authentication(for: profile))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 130, ideal: 180)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .accessibilityLabel("Saved MongoDB connections")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                editingProfile = ConnectionProfile(name: "New Connection")
            } label: {
                Label("Create", systemImage: "plus")
            }

            Button("Edit") {
                editingProfile = model.selectedConnection
            }
            .disabled(model.selectedConnection == nil)

            Button("Duplicate", action: model.duplicateSelectedConnection)
                .disabled(model.selectedConnection == nil)

            Button("Delete", role: .destructive) {
                showingDeleteConfirmation = true
            }
            .disabled(model.selectedConnection == nil)

            Spacer()

            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Connect", action: connect)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    model.selectedConnection == nil
                        || model.connectionState == .connecting
                )
        }
        .controlSize(.small)
        .padding(12)
    }

    private func connect() {
        guard let connectionID = model.selectedConnectionID,
              model.connectionState != .connecting else { return }
        model.switchConnection(to: connectionID)
    }

    private func address(for profile: ConnectionProfile) -> String {
        if let connectionString = profile.connectionString, !connectionString.isEmpty {
            return connectionString
        }
        return "\(profile.host):\(profile.port)"
    }

    private func options(for profile: ConnectionProfile) -> String {
        var values: [String] = []
        if profile.ssh.enabled { values.append("SSH") }
        if profile.tls.enabled { values.append("TLS") }
        if profile.replicaSet != nil { values.append("Replica Set") }
        if profile.directConnection { values.append("Direct") }
        if profile.isReadOnly { values.append("Read-only") }
        return values.isEmpty ? "Standard" : values.joined(separator: ", ")
    }

    private func environmentLabel(
        _ environment: ConnectionProfile.Environment
    ) -> String {
        switch environment {
        case .development: return "Development"
        case .staging: return "Staging"
        case .production: return "Production"
        }
    }

    private func connectionStatusColor(for profile: ConnectionProfile) -> Color {
        switch model.connectionState {
        case .connected where model.workspace.connectionID == profile.id:
            return .green
        case .connecting where model.selectedConnectionID == profile.id:
            return .orange
        case .failed where model.selectedConnectionID == profile.id:
            return .red
        default:
            return .secondary.opacity(0.45)
        }
    }

    private func authentication(for profile: ConnectionProfile) -> String {
        switch profile.authentication {
        case .none:
            return "None"
        case .scramSHA1:
            return "SCRAM-SHA-1 · \(profile.username)"
        case .scramSHA256:
            return "SCRAM-SHA-256 · \(profile.username)"
        case .x509:
            return "X.509 · \(profile.username)"
        }
    }
}
