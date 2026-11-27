import AudioToolbox
import CoreAudio
import Foundation

struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let manufacturer: String?
    let modelUID: String?
    let transportType: UInt32?

    var isAirPods: Bool {
        [name, modelUID]
            .compactMap { $0 }
            .contains { $0.range(of: "AirPods", options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            || (isBluetooth && manufacturer?.range(
                of: "Apple",
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil)
    }

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

enum AudioDeviceError: LocalizedError {
    case missingProperty(String)
    case osStatus(OSStatus, operation: String)

    var errorDescription: String? {
        switch self {
        case .missingProperty(let name):
            return "Audio property is unavailable: \(name)"
        case .osStatus(let status, let operation):
            return "\(operation) failed with OSStatus \(status)"
        }
    }
}

protocol AudioPropertyListening: AnyObject {
    func invalidate()
}

final class AudioPropertyListener: AudioPropertyListening {
    private let objectID: AudioObjectID
    private let queue: DispatchQueue
    private var registrations: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    init(
        objectID: AudioObjectID,
        addresses: [AudioObjectPropertyAddress],
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) throws {
        self.objectID = objectID
        self.queue = queue
        var lastFailure: OSStatus?

        for originalAddress in addresses {
            var address = originalAddress
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                handler()
            }

            let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
            guard status == noErr else {
                // Some devices advertise both a master control and per-channel controls,
                // but reject listeners for one of them. Keep every usable registration.
                lastFailure = status
                continue
            }

            registrations.append((originalAddress, block))
        }

        if registrations.isEmpty {
            throw AudioDeviceError.osStatus(
                lastFailure ?? kAudioHardwareUnspecifiedError,
                operation: "Add audio property listener"
            )
        }
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, registration.block)
        }

        registrations.removeAll()
    }
}

enum AudioHardware {
    private static let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private static let outputScope = AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput)
    private static let globalScope = AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal)
    private static let mainElement = AudioObjectPropertyElement(kAudioObjectPropertyElementMain)

    static func defaultOutputDevice() throws -> AudioDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: globalScope,
            mElement: mainElement
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &size, &deviceID)
        guard status == noErr else {
            throw AudioDeviceError.osStatus(status, operation: "Read default output device")
        }

        guard deviceID != kAudioObjectUnknown else {
            return nil
        }

        return try device(for: deviceID)
    }

    static func outputDevices() -> [AudioDevice] {
        objectList(systemObjectID, kAudioHardwarePropertyDevices, globalScope)
            .filter { !objectList($0, kAudioDevicePropertyStreams, outputScope).isEmpty }
            .compactMap { try? device(for: $0) }
    }

    static func setDefaultOutputDevice(_ device: AudioDevice) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: globalScope,
            mElement: mainElement
        )
        var id = device.id
        let status = AudioObjectSetPropertyData(
            systemObjectID, &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
        guard status == noErr else {
            throw AudioDeviceError.osStatus(status, operation: "Set default output device")
        }
    }

    static func outputMuted(for deviceID: AudioDeviceID) -> Bool {
        for element in [mainElement, AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute, mScope: outputScope, mElement: element
            )
            guard hasProperty(objectID: deviceID, address: address) else { continue }
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr,
               muted != 0 { return true }
        }
        return false
    }

    static func outputVolume(for device: AudioDevice) throws -> Float {
        try outputVolume(for: device.id)
    }

    static func outputVolume(for deviceID: AudioDeviceID) throws -> Float {
        if let systemVolume = try? volumeScalar(
            for: deviceID, element: mainElement, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        ) {
            return systemVolume
        }
        if let masterVolume = try volumeScalar(for: deviceID, element: mainElement) {
            return masterVolume
        }

        var channelVolumes: [Float] = []
        for element in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            if let volume = try volumeScalar(for: deviceID, element: element) {
                channelVolumes.append(volume)
            }
        }

        guard !channelVolumes.isEmpty else {
            throw AudioDeviceError.missingProperty("output volume")
        }

        return channelVolumes.reduce(0, +) / Float(channelVolumes.count)
    }

    static func setOutputVolume(_ volume: Float, for device: AudioDevice) throws {
        try setOutputVolume(volume, for: device.id)
    }

    static func setOutputVolume(_ volume: Float, for deviceID: AudioDeviceID) throws {
        let clampedVolume = min(max(volume, 0), 1)

        if (try? setVolumeScalar(
            clampedVolume, for: deviceID, element: mainElement,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        )) == true {
            return
        }

        if try setVolumeScalar(clampedVolume, for: deviceID, element: mainElement) {
            return
        }

        var didSetAnyChannel = false
        for element in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            if try setVolumeScalar(clampedVolume, for: deviceID, element: element) {
                didSetAnyChannel = true
            }
        }

        guard didSetAnyChannel else {
            throw AudioDeviceError.missingProperty("settable output volume")
        }
    }

    static func makeDefaultOutputDeviceListener(handler: @escaping () -> Void) throws -> AudioPropertyListener {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: globalScope,
            mElement: mainElement
        )

        return try AudioPropertyListener(
            objectID: systemObjectID,
            addresses: [address],
            handler: handler
        )
    }

    static func makeVolumeListener(for deviceID: AudioDeviceID, handler: @escaping () -> Void) throws -> AudioPropertyListener {
        let addresses = volumeAddresses(for: deviceID)
        guard !addresses.isEmpty else {
            throw AudioDeviceError.missingProperty("volume listener")
        }

        return try AudioPropertyListener(
            objectID: AudioObjectID(deviceID),
            addresses: addresses,
            handler: handler
        )
    }

    /// True while any process is doing IO on the device.
    static func isRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: globalScope, mElement: mainElement
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(AudioObjectID(deviceID), &address, 0, nil, &size, &running) == noErr
            && running != 0
    }

    static func makeRunningListener(
        for deviceID: AudioDeviceID,
        handler: @escaping () -> Void
    ) throws -> AudioPropertyListener {
        try AudioPropertyListener(
            objectID: AudioObjectID(deviceID),
            addresses: [AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: globalScope, mElement: mainElement
            )],
            handler: handler
        )
    }

    /// Whether some app still reports output on the device, or nil where macOS
    /// (before 14.2) has no per-process audio objects.
    static func anyProcessOutputting(on deviceID: AudioDeviceID) -> Bool? {
        guard #available(macOS 14.2, *) else { return nil }
        let processes = objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, globalScope)
        return processes.contains { process in
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput, mScope: globalScope, mElement: mainElement
            )
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr, running != 0 else {
                return false
            }
            return objectList(process, kAudioProcessPropertyDevices, outputScope).contains(AudioObjectID(deviceID))
        }
    }

    private static func objectList(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: mainElement)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    private static func device(for deviceID: AudioDeviceID) throws -> AudioDevice {
        let name = try stringProperty(
            kAudioDevicePropertyDeviceNameCFString,
            objectID: AudioObjectID(deviceID),
            scope: globalScope,
            propertyName: "device name"
        )
        let uid = try stringProperty(
            kAudioDevicePropertyDeviceUID,
            objectID: AudioObjectID(deviceID),
            scope: globalScope,
            propertyName: "device UID"
        )

        return AudioDevice(
            id: deviceID,
            uid: uid,
            name: name,
            manufacturer: try? stringProperty(
                kAudioObjectPropertyManufacturer,
                objectID: AudioObjectID(deviceID),
                scope: globalScope,
                propertyName: "device manufacturer"
            ),
            modelUID: try? stringProperty(
                kAudioDevicePropertyModelUID,
                objectID: AudioObjectID(deviceID),
                scope: globalScope,
                propertyName: "device model UID"
            ),
            transportType: try? uint32Property(
                kAudioDevicePropertyTransportType,
                objectID: AudioObjectID(deviceID),
                scope: globalScope,
                propertyName: "device transport type"
            )
        )
    }

    private static func volumeAddresses(for deviceID: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        let systemVolume = volumeAddress(
            element: mainElement, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        )
        let virtualMain = hasProperty(objectID: deviceID, address: systemVolume) ? [systemVolume] : []
        let channelAddresses = [mainElement, AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
            .flatMap { element in
                [volumeAddress(element: element), AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyMute, mScope: outputScope, mElement: element
                )]
            }
            .filter { hasProperty(objectID: AudioObjectID(deviceID), address: $0) }
        return virtualMain + channelAddresses
    }

    private static func volumeScalar(
        for deviceID: AudioDeviceID, element: AudioObjectPropertyElement,
        selector: AudioObjectPropertySelector = kAudioDevicePropertyVolumeScalar
    ) throws -> Float? {
        var address = volumeAddress(element: element, selector: selector)
        guard hasProperty(objectID: AudioObjectID(deviceID), address: address) else {
            return nil
        }

        var scalar = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(deviceID),
            &address,
            0,
            nil,
            &size,
            &scalar
        )

        guard status == noErr else {
            throw AudioDeviceError.osStatus(status, operation: "Read output volume")
        }

        return Float(scalar)
    }

    private static func setVolumeScalar(
        _ volume: Float,
        for deviceID: AudioDeviceID,
        element: AudioObjectPropertyElement,
        selector: AudioObjectPropertySelector = kAudioDevicePropertyVolumeScalar
    ) throws -> Bool {
        var address = volumeAddress(element: element, selector: selector)
        guard hasProperty(objectID: AudioObjectID(deviceID), address: address) else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        let settableStatus = AudioObjectIsPropertySettable(AudioObjectID(deviceID), &address, &isSettable)
        guard settableStatus == noErr else {
            throw AudioDeviceError.osStatus(settableStatus, operation: "Check output volume writability")
        }

        guard isSettable.boolValue else {
            return false
        }

        var scalar = Float32(volume)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(deviceID),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &scalar
        )

        guard status == noErr else {
            throw AudioDeviceError.osStatus(status, operation: "Set output volume")
        }

        return true
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        objectID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        propertyName: String
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: mainElement
        )
        guard hasProperty(objectID: objectID, address: address) else {
            throw AudioDeviceError.missingProperty(propertyName)
        }

        var unmanagedValue: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &unmanagedValue)

        guard status == noErr else {
            throw AudioDeviceError.osStatus(status, operation: "Read \(propertyName)")
        }

        guard let value = unmanagedValue?.takeRetainedValue() else {
            throw AudioDeviceError.missingProperty(propertyName)
        }

        return value as String
    }

    private static func uint32Property(
        _ selector: AudioObjectPropertySelector,
        objectID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        propertyName: String
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: mainElement
        )
        guard hasProperty(objectID: objectID, address: address) else {
            throw AudioDeviceError.missingProperty(propertyName)
        }

        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw AudioDeviceError.osStatus(status, operation: "Read \(propertyName)")
        }

        return value
    }

    private static func volumeAddress(
        element: AudioObjectPropertyElement,
        selector: AudioObjectPropertySelector = kAudioDevicePropertyVolumeScalar
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: outputScope,
            mElement: element
        )
    }

    private static func hasProperty(objectID: AudioObjectID, address: AudioObjectPropertyAddress) -> Bool {
        var mutableAddress = address
        return AudioObjectHasProperty(objectID, &mutableAddress)
    }
}

protocol AudioHardwareControlling {
    func defaultOutputDevice() throws -> AudioDevice?
    func outputVolume(for device: AudioDevice) throws -> Float
    func setOutputVolume(_ volume: Float, for device: AudioDevice) throws
    func isOutputActive(for device: AudioDevice) -> Bool?
    func makeOutputActivityListener(for device: AudioDevice, handler: @escaping () -> Void) throws -> AudioPropertyListening
    func makeDefaultOutputDeviceListener(handler: @escaping () -> Void) throws -> AudioPropertyListening
    func makeVolumeListener(for deviceID: AudioDeviceID, handler: @escaping () -> Void) throws -> AudioPropertyListening
}

struct SystemAudioHardware: AudioHardwareControlling {
    func defaultOutputDevice() throws -> AudioDevice? {
        try AudioHardware.defaultOutputDevice()
    }

    func outputVolume(for device: AudioDevice) throws -> Float {
        try AudioHardware.outputVolume(for: device)
    }

    func setOutputVolume(_ volume: Float, for device: AudioDevice) throws {
        try AudioHardware.setOutputVolume(volume, for: device)
    }

    func isOutputActive(for device: AudioDevice) -> Bool? {
        AudioHardware.anyProcessOutputting(on: device.id) ?? AudioHardware.isRunningSomewhere(device.id)
    }

    func makeOutputActivityListener(
        for device: AudioDevice, handler: @escaping () -> Void
    ) throws -> AudioPropertyListening {
        try AudioHardware.makeRunningListener(for: device.id, handler: handler)
    }

    func makeDefaultOutputDeviceListener(handler: @escaping () -> Void) throws -> AudioPropertyListening {
        try AudioHardware.makeDefaultOutputDeviceListener(handler: handler)
    }

    func makeVolumeListener(
        for deviceID: AudioDeviceID,
        handler: @escaping () -> Void
    ) throws -> AudioPropertyListening {
        try AudioHardware.makeVolumeListener(for: deviceID, handler: handler)
    }
}

/// Opens an output-only stream for an explicit request to take back the AirPods audio route.
final class SilentAudioOutput {
    private let unit: AudioUnit

    init(device: AudioDevice) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioDeviceError.missingProperty("HAL output audio unit")
        }
        var instance: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &instance), "Create HAL output")
        guard let instance else { throw AudioDeviceError.missingProperty("HAL output instance") }
        do {
            var disabled: UInt32 = 0
            try Self.check(AudioUnitSetProperty(
                instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                &disabled, UInt32(MemoryLayout.size(ofValue: disabled))
            ), "Disable HAL input")
            var deviceID = device.id
            try Self.check(AudioUnitSetProperty(
                instance, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout.size(ofValue: deviceID))
            ), "Select HAL output")
            var callback = AURenderCallbackStruct(inputProc: { _, _, _, _, _, buffers in
                if let buffers {
                    for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                    }
                }
                return noErr
            }, inputProcRefCon: nil)
            try Self.check(AudioUnitSetProperty(
                instance, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                &callback, UInt32(MemoryLayout.size(ofValue: callback))
            ), "Set silent output callback")
            try Self.check(AudioUnitInitialize(instance), "Initialize HAL output")
            try Self.check(AudioOutputUnitStart(instance), "Start HAL output")
        } catch {
            AudioUnitUninitialize(instance)
            AudioComponentInstanceDispose(instance)
            throw error
        }
        unit = instance
    }

    deinit {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw AudioDeviceError.osStatus(status, operation: operation) }
    }
}
