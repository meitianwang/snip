import AppKit
import Carbon.HIToolbox

/// Carbon RegisterEventHotKey 的极简封装，零第三方依赖。
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 0

    private init() {}

    /// keyCode: Carbon 虚拟键码 (如 kVK_ANSI_1)；modifiers: Carbon 修饰键 (如 cmdKey|shiftKey)
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        installEventHandlerIfNeeded()
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_4950), id: nextID) // 'SNIP'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Snip: 快捷键注册失败 keyCode=\(keyCode) status=\(status)")
            return
        }
        handlers[nextID] = handler
        refs[nextID] = ref
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }
}
