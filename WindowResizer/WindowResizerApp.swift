import SwiftUI
import AppKit

@main
struct WindowResizerApp: App {

    init() {
        // Menu-bar-only app: hide the Dock icon and app-switcher entry.
        // Use NSApplication.shared (not NSApp) so the singleton is created
        // on demand — NSApp can be nil during the App's init() and would crash.
        NSApplication.shared.setActivationPolicy(.accessory)

        // Fire the system Accessibility prompt once at launch if not yet trusted.
        // (Only shows if macOS hasn't already consumed the one-shot prompt for
        // this app's signature; otherwise grant manually in System Settings.)
        if !WindowResizer.hasPermission() {
            WindowResizer.requestPermission()
        }
    }

    var body: some Scene {
        MenuBarExtra("Resizer", systemImage: "rectangle.dashed") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
