import Foundation

/// A simulated Pranker so the app can be explored without hardware: in the
/// iOS Simulator (which has no Bluetooth), for screenshots, or just to look
/// around. Start it from the scanner screen, or launch with the `-demo` argument.
@MainActor
final class DemoDevice {
    private var timer: Timer?
    private var t: Double = 0
    private var present: [Int: Bool] = [:]
    private var smoothed: [Int: Double] = [:]
    private var armUntil = Date().addingTimeInterval(45)
    private var playingUntil = Date.distantPast
    private let started = Date()

    func start(on ble: BLEManager) {
        ble.isDemo = true
        ble.demo = self
        ble.deviceName = "Pranker"
        ble.config = .demoDefault
        ble.targets = [
            TargetInfo(id: 1, name: "Me (test)", enabled: true, enterClipBytes: 64_044),
            TargetInfo(id: 2, name: "Alex", enabled: true, enterClipBytes: 96_044, leaveClipBytes: 80_044),
            TargetInfo(id: 3, name: "Sam", enabled: false),
        ]
        var info = DeviceInfo(firmware: "1.1.0 (demo)", targetCount: 3, freeBytes: 1_180_000, uptimeSec: 3720)
        info.enterClipBytes = 48_044
        info.enrollResult = .success
        ble.info = info

        // Seed two minutes of history and a few events so screens aren't empty.
        let now = Date()
        for k in stride(from: 240, to: 0, by: -1) {
            let time = -Double(k) * 0.5
            var p = RSSIPoint(date: now.addingTimeInterval(time), phone: -58 + Self.noise(time, 7) * 3)
            for id in [1, 2] {
                p.smoothed[id] = signal(id, time)
                p.raw[id] = signal(id, time) + Self.noise(time, Double(id)) * 6
            }
            ble.history.append(p)
        }
        let seeded: [(Double, Int, Bool, Bool, String?)] = [
            (-25, 1, true, true, nil), (-95, 1, false, true, nil), (-140, 2, true, false, "cooldown"),
            (-610, 2, true, true, nil), (-1500, 2, false, true, nil),
        ]
        for (ago, id, enter, played, why) in seeded {
            let date = now.addingTimeInterval(ago)
            ble.events.append(DeviceEvent(date: date, targetID: id, targetName: ble.targetName(id), enter: enter,
                                          played: played, reason: why))
            ble.log.append(LogEntry(date: date, targetID: id, enter: enter, played: played))
        }
        t = 0
        ble.phase = .connected
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak ble] _ in
            MainActor.assumeIsolated {
                guard let self, let ble else { return }
                self.tick(ble)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// "Me" walks in and out of the room every minute; Alex sits nearby.
    private func signal(_ id: Int, _ time: Double) -> Double {
        id == 1 ? -73 + 15 * sin(2 * .pi * time / 60) : -63 + 2 * sin(time / 7)
    }

    private static func noise(_ time: Double, _ seed: Double) -> Double {
        sin(time * 12.9898 + seed * 78.233).truncatingRemainder(dividingBy: 1)
    }

    private func tick(_ ble: BLEManager) {
        t += 0.5
        guard let cfg = ble.config else { return }
        let armed = cfg.armed && armUntil <= Date()
        var any = false
        for target in ble.targets {
            guard target.enabled else {
                ble.targetStatus[target.id] = nil
                continue
            }
            let raw = signal(target.id, t) + Double.random(in: -6...6)
            let sm = (smoothed[target.id] ?? raw) + cfg.smoothing * (raw - (smoothed[target.id] ?? raw))
            smoothed[target.id] = sm
            let was = present[target.id] ?? false
            var now = was
            if !was && sm >= Double(cfg.enterRssi) { now = true }
            if was && sm <= Double(cfg.exitRssi) { now = false }
            present[target.id] = now
            any = any || now
            if now != was {
                let enabledKind = now ? cfg.playEnter : cfg.playLeave
                let played = armed && enabledKind
                let why: String? = !cfg.armed ? "disarmed" : (!armed ? "arming" : (!enabledKind ? "off" : nil))
                if played { playingUntil = Date().addingTimeInterval(1.5) }
                ble.applyEvent(DeviceEvent(date: Date(), targetID: target.id, targetName: target.name,
                                           enter: now, played: played, reason: why))
                ble.log.insert(LogEntry(date: Date(), targetID: target.id, enter: now, played: played), at: 0)
            }
            ble.targetStatus[target.id] = TargetStatus(id: target.id, present: now, lastRSSI: Int(raw),
                                                       msSinceSeen: Int.random(in: 40...600), smoothed: sm,
                                                       packetsPerSec: 2.4)
        }
        ble.applyStatus(DeviceStatus(anyPresent: any, phoneRSSI: -58 + Int.random(in: -4...4),
                                     armingRemaining: max(0, Int(armUntil.timeIntervalSinceNow.rounded(.up))),
                                     playing: Date() < playingUntil))
        ble.info?.uptimeSec = 3720 + Int(Date().timeIntervalSince(started))
    }

    func handle(_ body: [String: Any], on ble: BLEManager) async throws -> Ack {
        let cmd = body["cmd"] as? String ?? "?"
        let id = (body["id"] as? Int) ?? 0
        try? await Task.sleep(for: .milliseconds(150))
        switch cmd {
        case "play":
            playingUntil = Date().addingTimeInterval(2)
        case "stop":
            playingUntil = .distantPast
        case "hide", "reboot":
            armUntil = Date().addingTimeInterval(Double(ble.config?.armDelaySec ?? 60))
        case "enroll":
            let name = body["name"] as? String ?? "Target"
            ble.phase = .connecting(ble.deviceName)
            try? await Task.sleep(for: .seconds(3))
            let newID = (ble.targets.map(\.id).max() ?? 0) + 1
            ble.targets.append(TargetInfo(id: newID, name: name, enabled: true))
            ble.info?.targetCount = ble.targets.count
            ble.info?.enrollResult = .success
            ble.phase = .connected
        case "removeTarget":
            ble.targets.removeAll { $0.id == id }
            ble.targetStatus[id] = nil
            ble.info?.targetCount = ble.targets.count
        case "renameTarget":
            if let i = ble.targets.firstIndex(where: { $0.id == id }) {
                ble.targets[i].name = body["name"] as? String ?? ble.targets[i].name
            }
        case "enableTarget":
            if let i = ble.targets.firstIndex(where: { $0.id == id }) {
                ble.targets[i].enabled = body["on"] as? Bool ?? true
            }
        case "delete":
            setClipBytes(0, clipID: body["clip"] as? String ?? "", ble: ble)
        case "clearLog":
            ble.log = []
        default:
            break
        }
        return Ack(cmd: cmd, ok: true, error: nil)
    }

    func upload(_ wav: Data, to slot: ClipSlot, on ble: BLEManager) async throws {
        ble.uploadProgress = 0
        defer { ble.uploadProgress = nil }
        for i in 1...25 {
            try? await Task.sleep(for: .milliseconds(80))
            ble.uploadProgress = Double(i) / 25
        }
        setClipBytes(wav.count, clipID: slot.wireID, ble: ble)
    }

    private func setClipBytes(_ bytes: Int, clipID: String, ble: BLEManager) {
        switch clipID {
        case "enter": ble.info?.enterClipBytes = bytes
        case "leave": ble.info?.leaveClipBytes = bytes
        default:
            guard clipID.hasPrefix("t"), let id = Int(clipID.dropFirst().dropLast()),
                  let i = ble.targets.firstIndex(where: { $0.id == id }) else { return }
            if clipID.hasSuffix("e") { ble.targets[i].enterClipBytes = bytes } else { ble.targets[i].leaveClipBytes = bytes }
        }
    }
}

extension DeviceConfig {
    static let demoDefault = DeviceConfig(
        armed: true, enterRssi: -68, exitRssi: -80, absenceSec: 30, exitHoldSec: 8, smoothing: 0.3,
        cooldownSec: 20, armDelaySec: 60, volume: 80, playEnter: true, playLeave: true, chance: 100,
        led: false, name: "Pranker")
}

extension BLEManager {
    func startDemo() {
        stopScan()
        resetSession()
        DemoDevice().start(on: self)
    }

    func stopDemo() {
        demo?.stop()
        demo = nil
        isDemo = false
        resetSession()
        phase = .idle
        startScan()
    }
}
