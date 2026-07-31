import AppKit
import ServiceManagement
import SwiftUI

/// 用户设置：UserDefaults 持久化 + 开机自启 (SMAppService)。
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    @Published var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: "copyToClipboard") }
    }

    @Published var showPreview: Bool {
        didSet { defaults.set(showPreview, forKey: "showPreview") }
    }

    @Published var beautifyWindowCapture: Bool {
        didSet { defaults.set(beautifyWindowCapture, forKey: "beautifyWindowCapture") }
    }

    @Published var beautifyStyle: BeautifyStyle {
        didSet { defaults.set(beautifyStyle.rawValue, forKey: "beautifyStyle") }
    }

    @Published var saveDirectoryPath: String {
        didSet { defaults.set(saveDirectoryPath, forKey: "saveDirectory") }
    }

    @Published var launchAtLogin: Bool {
        didSet { updateLaunchAtLogin() }
    }

    private init() {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory()
        copyToClipboard = defaults.object(forKey: "copyToClipboard") as? Bool ?? true
        showPreview = defaults.object(forKey: "showPreview") as? Bool ?? true
        beautifyWindowCapture = defaults.object(forKey: "beautifyWindowCapture") as? Bool ?? true
        beautifyStyle = BeautifyStyle(rawValue: defaults.string(forKey: "beautifyStyle") ?? "") ?? .indigo
        saveDirectoryPath = defaults.string(forKey: "saveDirectory") ?? desktop
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var saveDirectory: URL {
        URL(fileURLWithPath: saveDirectoryPath)
    }

    func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveDirectory
        panel.prompt = "选择"
        panel.message = "选择截图保存目录"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectoryPath = url.path
        }
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Snip: 开机自启设置失败 \(error)")
        }
    }
}
