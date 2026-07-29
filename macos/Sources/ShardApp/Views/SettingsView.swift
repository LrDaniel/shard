import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var appKitAppearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    @MainActor
    static func apply(_ rawValue: String) {
        let appearance = AppAppearance(rawValue: rawValue) ?? .system
        NSApp.appearance = appearance.appKitAppearanceName.flatMap {
            NSAppearance(named: $0)
        }
    }
}

enum ConnectionSwitcherLocation: String, CaseIterable, Identifiable {
    case toolbar
    case sidebar

    var id: Self { self }

    var title: String {
        switch self {
        case .toolbar: return "Toolbar"
        case .sidebar: return "Sidebar"
        }
    }
}

struct SettingsView: View {
    @AppStorage("appearance.mode") private var appearanceMode = AppAppearance.system.rawValue
    @AppStorage("connectionSwitcher.location")
    private var connectionSwitcherLocation = ConnectionSwitcherLocation.sidebar.rawValue
    @AppStorage("sidebar.showsRecentQueries") private var showsRecentQueries = true
    @AppStorage("history.maximumEntries") private var maximumHistoryEntries = 50
    @AppStorage("editor.lineWrapping") private var lineWrapping = true

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearanceMode) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Navigation") {
                Picker("Connections", selection: $connectionSwitcherLocation) {
                    ForEach(ConnectionSwitcherLocation.allCases) { location in
                        Text(location.title).tag(location.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text("Choose where the connection switcher appears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Show recent queries in sidebar",
                    isOn: $showsRecentQueries
                )
            }
            Section("Editor") {
                Toggle("Wrap long query lines", isOn: $lineWrapping)
            }
            Section("History") {
                Picker("Keep recent queries", selection: historyLimitBinding) {
                    Text("10").tag(10)
                    Text("25").tag(25)
                    Text("50").tag(50)
                    Text("100").tag(100)
                }
            }
            Section("Privacy") {
                Text("Shard stores workspaces locally and keeps connection secrets in Keychain.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 430, height: 400)
        .onAppear {
            maximumHistoryEntries = normalizedHistoryLimit
        }
        .onChange(of: appearanceMode) { value in
            AppAppearance.apply(value)
        }
    }

    private var historyLimitBinding: Binding<Int> {
        Binding(
            get: { normalizedHistoryLimit },
            set: { maximumHistoryEntries = $0 }
        )
    }

    private var normalizedHistoryLimit: Int {
        [10, 25, 50, 100].min {
            abs($0 - maximumHistoryEntries) < abs($1 - maximumHistoryEntries)
        } ?? 50
    }
}
