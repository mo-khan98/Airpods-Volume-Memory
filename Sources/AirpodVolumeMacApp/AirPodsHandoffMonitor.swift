import Foundation

enum AirPodsAudioOwner: Equatable {
    case mac
    case iPhone
}

struct AirPodsHandoffState {
    private var owners: [String: AirPodsAudioOwner] = [:]
    private var pendingHandoff: (time: TimeInterval, toIPhone: Bool, address: String?)?

    func owner(for address: String) -> AirPodsAudioOwner? {
        Self.normalizedAddress(address).flatMap { owners[$0] }
    }

    @discardableResult
    mutating func consume(_ message: String, at time: TimeInterval) -> Bool {
        let peerPrefix = "_shouldAllowRelinquishOwnership _myModel Mac otherTipiName "
        if message.hasPrefix(peerPrefix) {
            let peer = message.dropFirst(peerPrefix.count)
                .components(separatedBy: " otherTipiVersion ").first
            pendingHandoff = (time, peer == "iPhone", nil)
            return false
        }

        let ownershipPrefix = "Setting ownership via BTHAL for Wx "
        let aacpPrefix = "OwnershipChanged: Received AACP message. Wx "
        if message.hasPrefix(ownershipPrefix) || message.hasPrefix(aacpPrefix) {
            let isAACP = message.hasPrefix(aacpPrefix)
            let fields = message.dropFirst(isAACP ? aacpPrefix.count : ownershipPrefix.count).split(separator: " ")
            guard fields.count == (isAACP ? 3 : 2),
                  let address = Self.normalizedAddress(String(fields[0])),
                  let owned = fields.last else { return false }

            if owned == "yes" {
                return setOwner(.mac, for: address)
            }
            if owned == "no" {
                if !isAACP, let handoff = pendingHandoff, time - handoff.time <= 1 {
                    pendingHandoff?.address = address
                }
                return owners[address] == .mac && setOwner(nil, for: address)
            }
        }

        // The banner and the relinquished owner must refer to the same headphones.
        if message.hasPrefix("PostingBanner: Type ReverseRoute, "),
           let handoff = pendingHandoff, time - handoff.time <= 1,
           let bannerAddress = message.range(of: ", Addr ", options: .backwards),
           let rawAddress = message[bannerAddress.upperBound...].split(separator: ",").first,
           let address = Self.normalizedAddress(String(rawAddress)), address == handoff.address {
            pendingHandoff = nil
            return setOwner(handoff.toIPhone ? .iPhone : nil, for: address)
        }
        return false
    }

    private mutating func setOwner(_ owner: AirPodsAudioOwner?, for address: String) -> Bool {
        guard owners[address] != owner else { return false }
        owners[address] = owner
        return true
    }

    private static func normalizedAddress(_ address: String) -> String? {
        let compact = address.lowercased().filter { $0 != ":" && $0 != "-" }
        guard compact.utf8.count == 12, compact.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { return nil }
        return compact
    }
}

final class AirPodsHandoffMonitor {
    private var process: Process?
    private var pipe: Pipe?
    private var buffer = Data()
    private var state = AirPodsHandoffState()
    var onChange: (() -> Void)?

    func owner(for address: String) -> AirPodsAudioOwner? {
        state.owner(for: address)
    }

    func start() {
        guard process == nil else { return }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--level", "default", "--style", "ndjson", "--ignore-dropped", "--predicate",
            """
            process == "audioaccessoryd" AND category == "BTSmartRoutingDaemon" AND (
                eventMessage BEGINSWITH "_shouldAllowRelinquishOwnership _myModel Mac otherTipiName " OR
                eventMessage BEGINSWITH "Setting ownership via BTHAL for Wx " OR
                eventMessage BEGINSWITH "OwnershipChanged: Received AACP message. Wx " OR
                eventMessage BEGINSWITH "PostingBanner: Type ReverseRoute, "
            )
            """
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        self.process = process
        self.pipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self, weak process] in
                guard let self, let process, self.process === process else { return }
                if chunk.isEmpty {
                    self.stop()
                    self.onChange?()
                } else {
                    self.receive(chunk)
                }
            }
        }
        do {
            try process.run()
        } catch {
            stop()
        }
    }

    func stop() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        pipe = nil
        buffer.removeAll()
        state = AirPodsHandoffState()
    }

    private func receive(_ chunk: Data) {
        buffer.append(chunk)
        var changed = false
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            if let event = try? JSONDecoder().decode(LogEvent.self, from: line) {
                changed = state.consume(event.eventMessage, at: ProcessInfo.processInfo.systemUptime) || changed
            }
            buffer.removeSubrange(...newline)
        }
        if changed { onChange?() }
    }

    private struct LogEvent: Decodable {
        let eventMessage: String
    }

    deinit { stop() }
}
