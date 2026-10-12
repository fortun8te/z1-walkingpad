import AppKit
import Carbon.HIToolbox

/// ⌃⌥W from anywhere: start or stop the belt.
///
/// Carbon's `RegisterEventHotKey` is still the only system-wide shortcut API
/// that needs no Accessibility permission. One key, registered while the
/// setting is on, gone when it is off.
@MainActor
final class GlobalHotKey {
    static let display = "⌃⌥W"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// The C callback cannot capture; it reaches the action through here.
    nonisolated(unsafe) private static var action: (() -> Void)?

    func register(_ action: @escaping @MainActor () -> Void) {
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
        guard status == noErr else { return }
        let id = EventHotKeyID(signature: OSType(0x5A31_574B), id: 1) // 'Z1WK'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_W),
            UInt32(controlKey | optionKey),
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        Self.action = nil
    }
}
