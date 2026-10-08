import Carbon
import GrokGaugeCore

/// One global shortcut via Carbon's RegisterEventHotKey (works without Accessibility permission).
@MainActor
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()

    /// True when macOS refused the last shortcut (another app probably owns it).
    @Published private(set) var registrationFailed = false

    var action: (() -> Void)?
    private(set) var registered: HotKey?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4752_4B47   // 'GRKG'

    /// Returns false when macOS refuses the combination (usually: another app already owns it).
    @discardableResult
    func register(_ key: HotKey) -> Bool {
        unregister()
        registrationFailed = false
        guard key.enabled, key.isValid else { return true }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(key.keyCode, key.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            registrationFailed = true
            return false
        }
        hotKeyRef = ref
        registered = key
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registered = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard err == noErr, id.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.action?() }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}
