import Foundation
import IOBluetooth

struct PairedHeadphones {
    let address: String
    let name: String
    let allowsNameMatch: Bool

    static func devices(remembered: [RememberedAirPods], currentOutput: AudioDevice?) -> [Self] {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let knownNames = remembered.map(\.name) + [currentOutput].compactMap {
            $0?.isAirPods == true ? $0?.name : nil
        }

        return devices.compactMap { device -> Self? in
            guard let address = device.addressString, let name = device.name else { return nil }
            let allowsNameMatch = devices.filter {
                $0.name?.caseInsensitiveCompare(name) == .orderedSame
            }.count == 1
            let isKnownAddress = remembered.contains { matchesAddress($0.uid, address: address) }
            let isKnownName = allowsNameMatch && knownNames.contains {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }
            guard name.localizedCaseInsensitiveContains("AirPods") || isKnownAddress
                || (device.deviceClassMajor == kBluetoothDeviceClassMajorAudio &&
                    (isKnownName || device.deviceClassMinor == kBluetoothDeviceClassMinorAudioHeadphones))
            else { return nil }
            return Self(address: address, name: name, allowsNameMatch: allowsNameMatch)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var isConnected: Bool {
        IOBluetoothDevice(addressString: address)?.isConnected() == true
    }

    func matchesOutput(_ output: AudioDevice) -> Bool {
        guard output.isBluetooth else { return false }
        if let outputAddress = Self.addressInUID(output.uid) {
            return outputAddress == Self.normalizedAddress(address)
        }
        return allowsNameMatch && output.name.caseInsensitiveCompare(name) == .orderedSame
    }

    func audioOutput() -> AudioDevice? {
        let outputs = AudioHardware.outputDevices().filter { $0.isBluetooth }
        if let exact = outputs.first(where: { Self.matchesAddress($0.uid, address: address) }) {
            return exact
        }
        let named = outputs.filter(matchesOutput)
        return named.count == 1 ? named.first : nil
    }

    func connect() -> Bool {
        guard let device = IOBluetoothDevice(addressString: address), device.isPaired() else { return false }
        return device.isConnected() || device.openConnection() == kIOReturnSuccess || device.isConnected()
    }

    private static func matchesAddress(_ uid: String, address: String) -> Bool {
        addressInUID(uid) == normalizedAddress(address)
    }

    private static func normalizedAddress(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: ":", with: "-")
    }

    static func addressInUID(_ uid: String) -> String? {
        // CoreAudio Bluetooth UIDs can end in ":output".
        let normalized = normalizedAddress(uid)
        guard let range = normalized.range(
            of: #"^([0-9a-f]{2}-){5}[0-9a-f]{2}(?=-|$)"#,
            options: .regularExpression
        ) else { return nil }
        return String(normalized[range])
    }
}
