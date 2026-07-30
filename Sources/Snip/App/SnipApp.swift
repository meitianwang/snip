import SwiftUI

@main
struct SnipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Snip", systemImage: "scissors") {
            MenuContent()
        }
    }
}
