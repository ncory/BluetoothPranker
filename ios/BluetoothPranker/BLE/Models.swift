import Foundation

enum Clip: String, CaseIterable, Identifiable {
    case enter, leave

    var id: String { rawValue }
    var title: String { self == .enter ? "Enter sound" : "Leave sound" }
    var shortTitle: String { self == .enter ? "Enter" : "Leave" }
    var symbol: String { self == .enter ? "figure.walk.arrival" : "figure.walk.departure" }
}

/// Where a clip lives on the device: the shared default, or a per-target override.
struct ClipSlot: Hashable, Identifiable {
    var targetID: Int?  // nil = default sound used by every target
    var kind: Clip

    var id: String { wireID }
    /// "enter" / "leave" for defaults, "t<id>e" / "t<id>l" for targets.
    var wireID: String {
        guard let t = targetID else { return kind.rawValue }
        return "t\(t)\(kind == .enter ? "e" : "l")"
    }
}

/// A phone the device recognizes.
struct TargetInfo: Identifiable, Equatable {
    let id: Int
    var name: String
    var enabled: Bool
    var enterClipBytes: Int
    var leaveClipBytes: Int

    init(id: Int, name: String, enabled: Bool, enterClipBytes: Int = 0, leaveClipBytes: Int = 0) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.enterClipBytes = enterClipBytes
        self.leaveClipBytes = leaveClipBytes
    }

    init?(json d: [String: Any]) {
        guard let id = jsonInt(d["id"]) else { return nil }
        self.init(id: id, name: d["n"] as? String ?? "Target", enabled: jsonBool(d["on"]),
                  enterClipBytes: jsonInt(d["ce"]) ?? 0, leaveClipBytes: jsonInt(d["cl"]) ?? 0)
    }

    func clipBytes(_ kind: Clip) -> Int { kind == .enter ? enterClipBytes : leaveClipBytes }
}

/// Mirrors the firmware's settings JSON (short keys on the wire).
struct DeviceConfig: Codable, Equatable {
    var armed: Bool
    var enterRssi: Int
    var exitRssi: Int
    var absenceSec: Int
    var exitHoldSec: Int
    var smoothing: Double
    var cooldownSec: Int
    var armDelaySec: Int
    var volume: Int
    var playEnter: Bool
    var playLeave: Bool
    var chance: Int
    var led: Bool
    var name: String

    enum CodingKeys: String, CodingKey {
        case armed
        case enterRssi = "enter"
        case exitRssi = "exit"
        case absenceSec = "absence"
        case exitHoldSec = "exitHold"
        case smoothing = "smooth"
        case cooldownSec = "cooldown"
        case armDelaySec = "armDelay"
        case volume = "vol"
        case playEnter, playLeave, chance, led, name
    }
}

struct Ack {
    let cmd: String
    let ok: Bool
    let error: String?
}

fileprivate func jsonDouble(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
fileprivate func jsonInt(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
fileprivate func jsonBool(_ v: Any?) -> Bool { (v as? NSNumber)?.boolValue ?? false }

/// Device-wide live status, sent twice a second while connected.
struct DeviceStatus {
    var anyPresent: Bool
    var phoneRSSI: Int?          // RSSI of *this* phone's connection
    var armingRemaining: Int     // seconds of silent "hide" time left
    var playing: Bool
    var uploadReceived: Int?
    var uploadTotal: Int?

    init(json d: [String: Any]) {
        anyPresent = jsonInt(d["any"]) == 1
        phoneRSSI = jsonInt(d["cr"])
        armingRemaining = jsonInt(d["wait"]) ?? 0
        playing = jsonBool(d["busy"])
        uploadReceived = jsonInt(d["up"])
        uploadTotal = jsonInt(d["upT"])
    }

    init(anyPresent: Bool, phoneRSSI: Int?, armingRemaining: Int, playing: Bool) {
        self.anyPresent = anyPresent
        self.phoneRSSI = phoneRSSI
        self.armingRemaining = armingRemaining
        self.playing = playing
    }
}

/// Live presence of one target, sent twice a second for each enabled target.
struct TargetStatus {
    var id: Int
    var present: Bool
    var lastRSSI: Int?
    var msSinceSeen: Int?
    var smoothed: Double?
    var packetsPerSec: Double
    var cooldownRemaining: Int

    init?(json d: [String: Any]) {
        guard let id = jsonInt(d["id"]) else { return nil }
        self.id = id
        present = jsonInt(d["st"]) == 1
        lastRSSI = jsonInt(d["r"])
        msSinceSeen = jsonInt(d["age"])
        smoothed = jsonDouble(d["s"])
        packetsPerSec = jsonDouble(d["pps"]) ?? 0
        cooldownRemaining = jsonInt(d["cd"]) ?? 0
    }

    init(id: Int, present: Bool, lastRSSI: Int?, msSinceSeen: Int?, smoothed: Double?, packetsPerSec: Double) {
        self.id = id
        self.present = present
        self.lastRSSI = lastRSSI
        self.msSinceSeen = msSinceSeen
        self.smoothed = smoothed
        self.packetsPerSec = packetsPerSec
        self.cooldownRemaining = 0
    }

    var everSeen: Bool { msSinceSeen != nil }
    /// The target is actively being heard right now (a packet within the last 5 s).
    var hearing: Bool { (msSinceSeen ?? .max) < 5000 }
}

enum EnrollResult: Int {
    case none = 0, success, timeout, failed, cancelled, full

    var text: String? {
        switch self {
        case .none: return nil
        case .success: return "Last enrollment succeeded."
        case .timeout: return "Last enrollment timed out (3 minutes) before the phone paired."
        case .failed: return "Last enrollment failed: the phone paired but didn't share its identity key. Try again."
        case .cancelled: return "Last enrollment was cancelled with the button."
        case .full: return "Last enrollment failed: the target list is full."
        }
    }
}

/// Slower-changing device info, sent every few seconds and on changes.
struct DeviceInfo {
    var protocolVersion: Int
    var firmware: String
    var targetCount: Int
    var maxTargets: Int
    var targetsVersion: Int
    var enterClipBytes: Int   // default clips
    var leaveClipBytes: Int
    var freeBytes: Int
    var enrollResult: EnrollResult
    var uptimeSec: Int

    init(json d: [String: Any]) {
        protocolVersion = jsonInt(d["v"]) ?? 0
        firmware = d["fw"] as? String ?? "?"
        targetCount = jsonInt(d["nt"]) ?? 0
        maxTargets = jsonInt(d["max"]) ?? 8
        targetsVersion = jsonInt(d["tv"]) ?? 0
        enterClipBytes = jsonInt(d["ce"]) ?? 0
        leaveClipBytes = jsonInt(d["cl"]) ?? 0
        freeBytes = jsonInt(d["free"]) ?? 0
        enrollResult = EnrollResult(rawValue: jsonInt(d["er"]) ?? 0) ?? .none
        uptimeSec = jsonInt(d["upt"]) ?? 0
    }

    init(firmware: String, targetCount: Int, freeBytes: Int, uptimeSec: Int) {
        protocolVersion = 2
        self.firmware = firmware
        self.targetCount = targetCount
        maxTargets = 8
        targetsVersion = 0
        enterClipBytes = 0
        leaveClipBytes = 0
        self.freeBytes = freeBytes
        enrollResult = .none
        self.uptimeSec = uptimeSec
    }

    func clipBytes(_ kind: Clip) -> Int { kind == .enter ? enterClipBytes : leaveClipBytes }
}

struct DeviceEvent: Identifiable {
    let id = UUID()
    let date: Date
    let targetID: Int
    let targetName: String
    let enter: Bool
    let played: Bool
    let reason: String?

    var reasonText: String? {
        switch reason {
        case "disarmed": return "device is disarmed"
        case "arming": return "still in the silent hide period"
        case "off": return "this sound is turned off"
        case "cooldown": return "cooldown"
        case "chance": return "random chance skipped it"
        case "busy": return "already playing"
        default: return nil
        }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let targetID: Int
    let enter: Bool
    let played: Bool
}

struct RSSIPoint: Identifiable {
    let id = UUID()
    let date: Date
    var smoothed: [Int: Double] = [:]  // per target: what the device decides on
    var raw: [Int: Double] = [:]       // per target: latest packet
    var phone: Double?                 // this phone's connection RSSI, smoothed
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

enum Calibration {
    struct Suggestion {
        let enter: Int
        let exit: Int
        let warning: String?
    }

    /// Pick thresholds between the "inside" and "outside" readings, with a gap
    /// between them so the device doesn't flip-flop at the doorway.
    static func suggest(inside: Double, outside: Double) -> Suggestion {
        let gap = inside - outside
        if gap < 6 {
            let enter = Int((inside - 2).rounded())
            return Suggestion(
                enter: enter, exit: enter - 4,
                warning: gap < 2
                    ? "Inside and outside look the same. Pick spots further apart, or rely on the 'gone for' timeout for leaving."
                    : "Inside and outside are close (\(Int(gap)) dB apart), so expect some false triggers near the boundary.")
        }
        let enter = Int((inside - gap * 0.3).rounded())
        var exit = Int((outside + gap * 0.3).rounded())
        if exit > enter - 3 { exit = enter - 3 }
        return Suggestion(enter: enter, exit: exit, warning: nil)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
