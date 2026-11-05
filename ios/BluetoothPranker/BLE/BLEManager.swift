import Foundation
import Observation
@preconcurrency import CoreBluetooth

enum PrankerUUID {
    static let service = CBUUID(string: "B10E0000-7A5C-4F3B-9E2D-5C0FFEE0B10E")
    static let config  = CBUUID(string: "B10E0001-7A5C-4F3B-9E2D-5C0FFEE0B10E")
    static let command = CBUUID(string: "B10E0002-7A5C-4F3B-9E2D-5C0FFEE0B10E")
    static let status  = CBUUID(string: "B10E0003-7A5C-4F3B-9E2D-5C0FFEE0B10E")
    static let audio   = CBUUID(string: "B10E0004-7A5C-4F3B-9E2D-5C0FFEE0B10E")
    static let log     = CBUUID(string: "B10E0005-7A5C-4F3B-9E2D-5C0FFEE0B10E")
    static let targets = CBUUID(string: "B10E0006-7A5C-4F3B-9E2D-5C0FFEE0B10E")
}

struct DiscoveredDevice: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
    var lastSeen: Date
    let peripheral: CBPeripheral
}

enum BLEError: LocalizedError {
    case notConnected
    case timeout(String)
    case device(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the device."
        case .timeout(let cmd): return "The device didn't answer (\(cmd))."
        case .device(let msg): return "Device error: \(msg)"
        }
    }
}

/// Talks to the Pranker firmware over Bluetooth LE. Everything runs on the main
/// queue/actor, so SwiftUI can observe it directly. See DemoMode.swift for the
/// simulated device used in the simulator and for screenshots.
@Observable
@MainActor
final class BLEManager: NSObject {
    enum Phase: Equatable {
        case bluetoothOff, unauthorized, unsupported
        case idle, scanning
        case connecting(String)
        case connected
    }

    // Setters are internal (not private) so DemoMode.swift can drive them.
    var phase: Phase = .idle
    var devices: [DiscoveredDevice] = []
    var deviceName = ""
    var config: DeviceConfig?
    var status: DeviceStatus?
    var targets: [TargetInfo] = []
    var targetStatus: [Int: TargetStatus] = [:]
    var statusSeq = 0
    var info: DeviceInfo?
    var history: [RSSIPoint] = []
    var events: [DeviceEvent] = []
    var log: [LogEntry] = []
    var uploadProgress: Double?
    var lastError: String?
    var isDemo = false

    /// This phone's connection RSSI, smoothed like the firmware smooths targets.
    var phoneSmoothed: Double?

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var chars: [CBUUID: CBCharacteristic] = [:]
    @ObservationIgnored private var ackWaiters: [String: [(id: UUID, cont: CheckedContinuation<Ack, Error>)]] = [:]
    @ObservationIgnored private var ackBuffer: [String: Ack] = [:]
    @ObservationIgnored private var writeWaiters: [(id: UUID, cont: CheckedContinuation<Void, Never>)] = []
    @ObservationIgnored private var userDisconnected = false
    @ObservationIgnored private var lastTargetsVersion = -1
    @ObservationIgnored var demo: DemoDevice?

    private let lastDeviceKey = "lastDeviceID"
    let historySeconds: TimeInterval = 120

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func targetName(_ id: Int) -> String {
        targets.first { $0.id == id }?.name ?? "Target \(id)"
    }

    var enabledTargets: [TargetInfo] { targets.filter(\.enabled) }

    // MARK: - Scanning / connecting

    func startScan() {
        guard central.state == .poweredOn, !isDemo else { return }
        devices.removeAll()
        phase = .scanning
        central.scanForPeripherals(withServices: [PrankerUUID.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        central.stopScan()
        if phase == .scanning { phase = .idle }
    }

    func connect(_ device: DiscoveredDevice) {
        connect(device.peripheral, name: device.name)
    }

    private func connect(_ p: CBPeripheral, name: String?) {
        central.stopScan()
        userDisconnected = false
        peripheral = p
        p.delegate = self
        deviceName = name ?? p.name ?? "Pranker"
        phase = .connecting(deviceName)
        UserDefaults.standard.set(p.identifier.uuidString, forKey: lastDeviceKey)
        central.connect(p)
    }

    /// Disconnects and forgets the device (no auto-reconnect).
    func disconnect() {
        if isDemo {
            stopDemo()
            return
        }
        userDisconnected = true
        UserDefaults.standard.removeObject(forKey: lastDeviceKey)
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        resetSession()
        phase = .idle
        startScan()
    }

    func resetSession() {
        chars = [:]
        config = nil
        status = nil
        info = nil
        targets = []
        targetStatus = [:]
        history = []
        events = []
        log = []
        phoneSmoothed = nil
        uploadProgress = nil
        lastTargetsVersion = -1
        ackBuffer = [:]
        for (_, list) in ackWaiters { list.forEach { $0.cont.resume(throwing: BLEError.notConnected) } }
        ackWaiters = [:]
        writeWaiters.forEach { $0.cont.resume() }
        writeWaiters = []
    }

    // MARK: - Commands

    /// Runs an async operation and surfaces any error in `lastError`.
    func perform(_ op: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await op() } catch { self.lastError = error.localizedDescription }
        }
    }

    @discardableResult
    func command(_ body: [String: Any], timeout: Double = 5) async throws -> Ack {
        if let demo { return try await demo.handle(body, on: self) }
        guard phase == .connected, let p = peripheral, let ch = chars[PrankerUUID.command] else {
            throw BLEError.notConnected
        }
        let name = body["cmd"] as? String ?? "?"
        ackBuffer[name] = nil
        let data = try JSONSerialization.data(withJSONObject: body)
        p.writeValue(data, for: ch, type: .withResponse)
        let ack = try await waitForAck(name, timeout: timeout)
        if !ack.ok { throw BLEError.device(ack.error ?? "\(name) failed") }
        return ack
    }

    func play(_ slot: ClipSlot) async throws { try await command(["cmd": "play", "clip": slot.wireID]) }
    func stopSound() async throws { try await command(["cmd": "stop"]) }
    func restartHideTimer() async throws { try await command(["cmd": "hide"]) }
    func deleteClip(_ slot: ClipSlot) async throws { try await command(["cmd": "delete", "clip": slot.wireID]) }
    func reboot() async throws { try await command(["cmd": "reboot"]) }

    func removeTarget(_ id: Int) async throws {
        try await command(["cmd": "removeTarget", "id": id])
        refreshTargets()
    }

    func renameTarget(_ id: Int, to name: String) async throws {
        try await command(["cmd": "renameTarget", "id": id, "name": name])
        refreshTargets()
    }

    func setTarget(_ id: Int, enabled: Bool) async throws {
        try await command(["cmd": "enableTarget", "id": id, "on": enabled])
        refreshTargets()
    }

    func clearLog() async throws {
        try await command(["cmd": "clearLog"])
        log = []
    }

    /// Reboots the device into "keyboard" pairing mode for a new target. It
    /// drops the connection; we reconnect automatically when it comes back.
    func startEnrollment(name: String) async throws {
        try await command(["cmd": "enroll", "name": name])
    }

    func saveConfig(_ newConfig: DeviceConfig) async throws {
        if isDemo {
            config = newConfig
            return
        }
        guard phase == .connected, let p = peripheral, let ch = chars[PrankerUUID.config] else {
            throw BLEError.notConnected
        }
        ackBuffer["config"] = nil
        let data = try JSONEncoder().encode(newConfig)
        p.writeValue(data, for: ch, type: .withResponse)
        let ack = try await waitForAck("config", timeout: 5)
        if !ack.ok { throw BLEError.device(ack.error ?? "config rejected") }
        config = newConfig
        p.readValue(for: ch)  // pick up any values the firmware clamped
    }

    func update(_ change: (inout DeviceConfig) -> Void) async throws {
        guard var c = config else { throw BLEError.notConnected }
        change(&c)
        try await saveConfig(c)
    }

    func refreshLog() {
        guard !isDemo, let p = peripheral, let ch = chars[PrankerUUID.log] else { return }
        p.readValue(for: ch)
    }

    func refreshTargets() {
        guard !isDemo, let p = peripheral, let ch = chars[PrankerUUID.targets] else { return }
        p.readValue(for: ch)
    }

    /// Streams a WAV file to the device. Chunks are [UInt32 LE offset][bytes].
    func upload(_ wav: Data, to slot: ClipSlot) async throws {
        if let demo { return try await demo.upload(wav, to: slot, on: self) }
        guard let p = peripheral, let audio = chars[PrankerUUID.audio] else { throw BLEError.notConnected }
        let wav = Data(wav)  // make sure indices start at 0
        uploadProgress = 0
        defer { uploadProgress = nil }

        try await command(["cmd": "upload", "clip": slot.wireID, "size": wav.count, "crc": CRC32.checksum(wav)])
        ackBuffer["uploadDone"] = nil

        let chunk = max(16, p.maximumWriteValueLength(for: .withoutResponse) - 4)
        var offset = 0
        while offset < wav.count {
            if let fail = ackBuffer.removeValue(forKey: "upload"), !fail.ok {
                throw BLEError.device(fail.error ?? "upload failed")
            }
            guard phase == .connected else { throw BLEError.notConnected }
            if !p.canSendWriteWithoutResponse {
                await waitUntilWritable()
                continue
            }
            let end = min(offset + chunk, wav.count)
            var packet = Data(capacity: end - offset + 4)
            var le = UInt32(offset).littleEndian
            withUnsafeBytes(of: &le) { packet.append(contentsOf: $0) }
            packet.append(wav.subdata(in: offset..<end))
            p.writeValue(packet, for: audio, type: .withoutResponse)
            offset = end
            uploadProgress = Double(offset) / Double(wav.count)
        }

        let done = try await waitForAck("uploadDone", timeout: 20)
        if !done.ok { throw BLEError.device(done.error ?? "upload failed") }
        refreshTargets()
    }

    // MARK: - Ack plumbing

    private func waitForAck(_ cmd: String, timeout: Double) async throws -> Ack {
        if let a = ackBuffer.removeValue(forKey: cmd) { return a }
        let id = UUID()
        return try await withCheckedThrowingContinuation { cont in
            ackWaiters[cmd, default: []].append((id, cont))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.expireWaiter(cmd, id)
            }
        }
    }

    private func expireWaiter(_ cmd: String, _ id: UUID) {
        guard var list = ackWaiters[cmd], let i = list.firstIndex(where: { $0.id == id }) else { return }
        let w = list.remove(at: i)
        ackWaiters[cmd] = list
        w.cont.resume(throwing: BLEError.timeout(cmd))
    }

    private func deliver(_ ack: Ack) {
        if var list = ackWaiters[ack.cmd], !list.isEmpty {
            let w = list.removeFirst()
            ackWaiters[ack.cmd] = list
            w.cont.resume(returning: ack)
        } else {
            ackBuffer[ack.cmd] = ack
        }
    }

    private func waitUntilWritable() async {
        let id = UUID()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writeWaiters.append((id, cont))
            // Safety net in case the "ready" callback never comes.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.releaseWriteWaiter(id)
            }
        }
    }

    private func releaseWriteWaiter(_ id: UUID?) {
        if let id {
            guard let i = writeWaiters.firstIndex(where: { $0.id == id }) else { return }
            writeWaiters.remove(at: i).cont.resume()
        } else {
            let all = writeWaiters
            writeWaiters = []
            all.forEach { $0.cont.resume() }
        }
    }

    // MARK: - Incoming data (also used by demo mode)

    /// Global status arrives after the per-target ones each tick, so it closes
    /// out one history sample.
    func applyStatus(_ s: DeviceStatus) {
        status = s
        statusSeq += 1
        if let cr = s.phoneRSSI {
            let alpha = config?.smoothing ?? 0.3
            phoneSmoothed = phoneSmoothed.map { $0 + alpha * (Double(cr) - $0) } ?? Double(cr)
        }
        let now = Date()
        var point = RSSIPoint(date: now, phone: phoneSmoothed)
        for (id, t) in targetStatus {
            if t.hearing, let sm = t.smoothed { point.smoothed[id] = sm }
            if (t.msSinceSeen ?? .max) < 1500, let r = t.lastRSSI { point.raw[id] = Double(r) }
        }
        history.append(point)
        history.removeAll { now.timeIntervalSince($0.date) > historySeconds }
    }

    func applyEvent(_ e: DeviceEvent) {
        events.insert(e, at: 0)
        if events.count > 50 { events.removeLast(events.count - 50) }
    }

    private func handleStatusMessage(_ data: Data) {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = d["t"] as? String else { return }
        switch type {
        case "s":
            applyStatus(DeviceStatus(json: d))
        case "p":
            if let t = TargetStatus(json: d) { targetStatus[t.id] = t }
        case "i":
            let i = DeviceInfo(json: d)
            info = i
            if i.targetsVersion != lastTargetsVersion {
                lastTargetsVersion = i.targetsVersion
                refreshTargets()
            }
        case "e":
            let id = (d["id"] as? NSNumber)?.intValue ?? 0
            applyEvent(DeviceEvent(date: Date(), targetID: id, targetName: d["n"] as? String ?? targetName(id),
                                   enter: d["ev"] as? String == "enter",
                                   played: (d["played"] as? NSNumber)?.boolValue ?? false,
                                   reason: d["why"] as? String))
        case "ack":
            deliver(Ack(cmd: d["cmd"] as? String ?? "?",
                        ok: (d["ok"] as? NSNumber)?.boolValue ?? false,
                        error: d["err"] as? String))
        default:
            break
        }
    }

    private func handleLog(_ data: Data) {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let now = (d["now"] as? NSNumber)?.doubleValue,
              let rows = d["ev"] as? [[NSNumber]] else { return }
        let readAt = Date()
        log = rows.compactMap { r -> LogEntry? in
            guard r.count >= 4 else { return nil }
            let ageSec = (now - r[0].doubleValue) / 1000
            return LogEntry(date: readAt.addingTimeInterval(-ageSec), targetID: r[1].intValue,
                            enter: r[2].boolValue, played: r[3].boolValue)
        }.reversed()
    }

    private func handleTargets(_ data: Data) {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        targets = rows.compactMap { TargetInfo(json: $0) }
        let ids = Set(targets.map(\.id))
        targetStatus = targetStatus.filter { ids.contains($0.key) }
    }

    // MARK: - Delegate handlers (main actor)

    private func handleStateUpdate() {
        guard !isDemo else { return }
        switch central.state {
        case .poweredOn:
            if let p = peripheral, p.state != .connected {
                phase = .connecting(deviceName)
                central.connect(p)
            } else if peripheral == nil, let idString = UserDefaults.standard.string(forKey: lastDeviceKey),
                      let id = UUID(uuidString: idString),
                      let known = central.retrievePeripherals(withIdentifiers: [id]).first {
                connect(known, name: known.name)  // pends until the device is in range
            } else if peripheral == nil {
                startScan()
            }
        case .poweredOff: phase = .bluetoothOff
        case .unauthorized: phase = .unauthorized
        case .unsupported: phase = .unsupported
        default: phase = .idle
        }
    }

    private func handleDiscover(_ p: CBPeripheral, _ adv: [String: Any], _ rssi: Int) {
        guard rssi < 0 else { return }  // 127 = unavailable
        let name = adv[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? "Pranker"
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            // Light smoothing so the list doesn't jitter.
            devices[i].rssi = (devices[i].rssi * 2 + rssi) / 3
            devices[i].name = name
            devices[i].lastSeen = Date()
        } else {
            devices.append(DiscoveredDevice(id: p.identifier, name: name, rssi: rssi, lastSeen: Date(), peripheral: p))
        }
    }

    private func handleConnected(_ p: CBPeripheral) {
        guard p == peripheral else { return }
        p.discoverServices([PrankerUUID.service])
    }

    private func handleDisconnected(_ p: CBPeripheral) {
        guard p == peripheral else { return }
        resetSession()
        if userDisconnected {
            phase = .idle
            return
        }
        // Keep a pending connection open: iOS reconnects as soon as it's back
        // (e.g. after the device reboots into/out of enrollment mode).
        phase = .connecting(deviceName)
        central.connect(p)
    }

    private func handleFailedConnect(_ p: CBPeripheral, message: String) {
        guard p == peripheral else { return }
        lastError = message
        peripheral = nil
        resetSession()
        phase = .idle
        startScan()
    }

    private func handleCharacteristics(_ p: CBPeripheral, _ service: CBService) {
        for c in service.characteristics ?? [] { chars[c.uuid] = c }
        guard let statusChar = chars[PrankerUUID.status], let configChar = chars[PrankerUUID.config] else {
            lastError = "This doesn't look like a Pranker device (missing characteristics)."
            return
        }
        guard chars[PrankerUUID.targets] != nil else {
            lastError = "The device runs older firmware. Please re-flash it."
            return
        }
        p.setNotifyValue(true, for: statusChar)
        p.readValue(for: configChar)
        refreshTargets()
        refreshLog()
        phase = .connected
    }

    private func handleValue(_ c: CBCharacteristic) {
        guard let data = c.value else { return }
        switch c.uuid {
        case PrankerUUID.status:
            handleStatusMessage(data)
        case PrankerUUID.config:
            if let cfg = try? JSONDecoder().decode(DeviceConfig.self, from: data) {
                config = cfg
                deviceName = cfg.name
            }
        case PrankerUUID.log:
            handleLog(data)
        case PrankerUUID.targets:
            handleTargets(data)
        default:
            break
        }
    }
}

// MARK: - CoreBluetooth delegates (called on the main queue)

extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { self.handleStateUpdate() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        MainActor.assumeIsolated { self.handleDiscover(peripheral, advertisementData, rssi) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { self.handleConnected(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        let message = error?.localizedDescription ?? "Couldn't connect."
        MainActor.assumeIsolated { self.handleFailedConnect(peripheral, message: message) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { self.handleDisconnected(peripheral) }
    }
}

extension BLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let svc = peripheral.services?.first(where: { $0.uuid == PrankerUUID.service }) else {
                self.lastError = "Pranker service not found."
                return
            }
            peripheral.discoverCharacteristics(nil, for: svc)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated { self.handleCharacteristics(peripheral, service) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated { self.handleValue(characteristic) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let error else { return }
        let message = error.localizedDescription
        MainActor.assumeIsolated { self.lastError = message }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { self.releaseWriteWaiter(nil) }
    }
}
