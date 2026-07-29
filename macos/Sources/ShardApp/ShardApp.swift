import SwiftUI

@main
struct ShardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage("appearance.mode") private var appearanceMode = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 560)
                .preferredColorScheme(
                    (AppAppearance(rawValue: appearanceMode) ?? .system).colorScheme
                )
                .onChange(of: appearanceMode) { value in
                    AppAppearance.apply(value)
                }
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Query", action: model.addQuery)
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Connection…") {
                    model.showingConnectionEditor = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Quick Open Collection…", action: model.showCollectionQuickOpen)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .saveItem) {
                Button("Open Query…", action: model.openQueryFile)
                    .keyboardShortcut("o", modifiers: .command)
                Button("Save Query", action: model.saveSelectedQuery)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.selectedDocument == nil)
            }

            CommandMenu("Query") {
                Button("Close Query Tab", action: model.closeSelectedQuery)
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(model.selectedDocument == nil)
                Divider()
                Button("Run Query", action: model.executeSelectedQuery)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.connectionState == .disconnected || model.isExecuting)
                Button("Run Entire Editor", action: model.executeSelectedQuery)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(model.connectionState == .disconnected || model.isExecuting)
                Button("Explain Query", action: model.explainSelectedQuery)
                    .disabled(
                        model.connectionState == .disconnected ||
                        model.isExecuting ||
                        model.isExplaining
                    )
                Button("Stop", action: model.stopExecution)
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isExecuting)
                Divider()
                Button("Query History & Favorites…", action: model.showQueryHistory)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Command Palette…") {
                    model.showingCommandPalette = true
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            CommandMenu("Connections") {
                ForEach(
                    Array(model.connections.prefix(9).enumerated()),
                    id: \.element.id
                ) { index, connection in
                    Button(connection.name) {
                        model.switchConnection(to: connection.id)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character(String(index + 1))),
                        modifiers: .command
                    )
                }

                if !model.connections.isEmpty {
                    Divider()
                }

                if model.connectionState.isConnected ||
                    model.connectionState == .connecting {
                    Button("Disconnect", action: model.disconnect)
                    Divider()
                }

                Button("Manage Connections…") {
                    model.showingConnectionManager = true
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }

            CommandGroup(after: .sidebar) {
                Button(model.sidebarVisible ? "Hide Database Sidebar" : "Show Database Sidebar") {
                    model.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
