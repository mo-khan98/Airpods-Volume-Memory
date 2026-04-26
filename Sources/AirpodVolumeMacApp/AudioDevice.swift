import CoreAudio
import Foundation

struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    var isAirPods: Bool {
        name.range(of: "AirPods", options: [.caseInsensitive, .diacriticInsensitive]) != nil
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

final class AudioPropertyListener {
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

        for originalAddress in addresses {
            var address = originalAddress
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                handler()
            }

            let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
            guard status == noErr else {
                invalidate()
                throw AudioDeviceError.osStatus(status, operation: "Add audio property listener")
            }

            registrations.append((originalAddress, block))
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

    static func outputVolume(for device: AudioDevice) throws -> Float {
        try outputVolume(for: device.id)
    }

    static func outputVolume(for deviceID: AudioDeviceID) throws -> Float {
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

        return AudioDevice(id: deviceID, uid: uid, name: name)
    }

    private static func volumeAddresses(for deviceID: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        [mainElement, AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
            .map { volumeAddress(element: $0) }
            .filter { hasProperty(objectID: AudioObjectID(deviceID), address: $0) }
    }

    private static func volumeScalar(for deviceID: AudioDeviceID, element: AudioObjectPropertyElement) throws -> Float? {
        var address = volumeAddress(element: element)
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
        element: AudioObjectPropertyElement
    ) throws -> Bool {
        var address = volumeAddress(element: element)
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

    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: outputScope,
            mElement: element
        )
    }

    private static func hasProperty(objectID: AudioObjectID, address: AudioObjectPropertyAddress) -> Bool {
        var mutableAddress = address
        return AudioObjectHasProperty(objectID, &mutableAddress)
    }
}
