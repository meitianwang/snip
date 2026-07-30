import AppKit
import ScreenCaptureKit

enum CaptureError: Error {
    case displayNotFound
    case permissionDenied
}

/// ScreenCaptureKit 封装：截取指定屏幕的一帧全分辨率图像。
enum CaptureEngine {
    /// 检查/请求「屏幕录制」权限
    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    static func captureImage(of screen: NSScreen) async throws -> CGImage {
        try await captureImage(of: screen, content: shareableContent())
    }

    static func captureImage(of screen: NSScreen, content: SCShareableContent) async throws -> CGImage {
        guard let displayID = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        config.captureResolution = .best

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// 单独截取一个窗口（不含遮挡它的内容）
    static func captureWindow(_ window: SCWindow, scale: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// 可供用户点选的普通应用窗口（过滤自身/菜单栏等系统层）
    static func pickableWindows(from content: SCShareableContent) -> [SCWindow] {
        content.windows.filter { window in
            window.isOnScreen
                && window.windowLayer == 0
                && window.frame.width >= 40 && window.frame.height >= 40
                && window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }
    }
}

enum CaptureMode {
    case region
    case window
}

/// 区域截取的用途：普通截图 / OCR 取字
enum CapturePurpose {
    case image
    case text
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
