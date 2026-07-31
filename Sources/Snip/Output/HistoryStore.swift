import AppKit
import SwiftUI

/// 截图历史：最近 10 张，路径持久化，文件被删自动剔除。
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var items: [URL] = []

    private let key = "historyPaths"
    private let capacity = 10

    private init() {
        items = (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ url: URL) {
        items.removeAll { $0 == url }
        items.insert(url, at: 0)
        if items.count > capacity {
            items = Array(items.prefix(capacity))
        }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(items.map(\.path), forKey: key)
    }
}
