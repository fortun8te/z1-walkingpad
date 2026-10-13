import AppKit
import Carbon.HIToolbox

/// ⌃⌥W from anywhere: start or stop the belt.
///
/// Carbon's `RegisterEventHotKey` is still the only system-wide shortcut API
/// that needs no Accessibility permission. One key, registered while the
/// app runs. A conflict is reported so the UI never promises a dead shortcut.
@MainActor
final class GlobalHotKey {
    static let display = "⌃⌥W"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// The C callback cannot capture; it reaches the action through here.
    nonisolated(unsafe) private static var action: (() -> Void)?

    @discardableResult
    func register(_ action: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        Self.action = { MainActor.assumeIsolated { action() } }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                DispatchQueue.main.async { GlobalHotKey.action?() }
                return noErr
            },
            1,
            &spec,
            nil,
            &handlerRef
        )
        guard status == noErr else {
            unregister()
            NSLog("Z1App: global shortcut handler failed (%d)", status)
            return false
        }
        let id = EventHotKeyID(signature: OSType(0x5A31_574B), id: 1) // 'Z1WK'
        let registration = RegisterEventHotKey(
            UInt32(kVK_ANSI_W),
            UInt32(controlKey | optionKey),
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registration == noErr else {
            // An installed handler is not a registered key. Remove it too,
            // especially when another app already owns this combination.
            unregister()
            NSLog("Z1App: global shortcut registration failed (%d)", registration)
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        Self.action = nil
    }
}
