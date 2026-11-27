import AppKit

final class VolumeKeyMonitor {
    private static let systemDefined = CGEventType(rawValue: 14)!
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var onAdjustment: ((Bool, Bool) -> Void)?
    var onMute: (() -> Void)?
    var isListening: Bool { tap != nil }

    func start() {
        guard tap == nil, let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: 1 << Self.systemDefined.rawValue,
            callback: { _, type, event, context in
                if let context {
                    Unmanaged<VolumeKeyMonitor>.fromOpaque(context).takeUnretainedValue().receive(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return }
        tap = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // NX_SYSDEFINED, NX_SUBTYPE_AUX_CONTROL_BUTTONS, with the key-down state.
        guard type == Self.systemDefined, let key = NSEvent(cgEvent: event),
              key.type == .systemDefined, key.subtype.rawValue == 8,
              (key.data1 >> 8) & 0xff == 0x0a else { return }
        let code = (key.data1 >> 16) & 0xffff
        if code == 7 { // NX_KEYTYPE_MUTE
            onMute?()
            return
        }
        guard code == 0 || code == 1 else { return } // NX_KEYTYPE_SOUND_UP / SOUND_DOWN
        let modifiers = key.modifierFlags.intersection([.shift, .option, .command, .control])
        let fine = modifiers == [.shift, .option]
        guard modifiers.isEmpty || fine else { return }
        onAdjustment?(code == 0, fine)
    }

    deinit { stop() }
}
