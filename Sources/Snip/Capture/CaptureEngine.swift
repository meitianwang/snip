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

    static func captureImage(of screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
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
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
