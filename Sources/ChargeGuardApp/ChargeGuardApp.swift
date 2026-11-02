import AppKit
import ChargeCore
import SwiftUI

@main
struct ChargeGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(manager: appDelegate.manager)
        } label: {
            MenuBarLabel(manager: appDelegate.manager)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The App struct doesn't observe the manager, so the label needs its own
/// @ObservedObject to refresh the icon and percentage.
private struct MenuBarLabel: View {
    @ObservedObject var manager: BatteryManager

    var body: some View {
        MenuBarIcon(state: manager.state, percent: manager.snapshot.osPercent)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let manager = BatteryManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only (also set LSUIElement in Info.plist so no Dock icon flashes at launch).
        NSApp.setActivationPolicy(.accessory)
        manager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.shutdown()
    }
}
