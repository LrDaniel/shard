import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppAppearance.apply(
            UserDefaults.standard.string(forKey: "appearance.mode")
                ?? AppAppearance.system.rawValue
        )
#if SWIFT_PACKAGE
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
#endif
        NSApp.activate(ignoringOtherApps: true)
    }
}
