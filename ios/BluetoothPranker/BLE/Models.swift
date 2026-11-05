import Foundation

enum Clip: String, CaseIterable, Identifiable {
    case enter, leave

    var id: String { rawValue }
    var title: String { self == .enter ? "Enter sound" : "Leave sound" }
    var shortTitle: String { self == .enter ? "Enter" : "Leave" }
    var symbol: String { self == .enter ? "figure.walk.arrival" : "figure.walk.departure" }
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

/// Live status, sent by the device twice a second while connected.
struct DeviceStatus {
    var present: Bool
    var lastRSSI: Int?
    var msSinceSeen: Int?
    var smoothed: Double?
    var packetsPerSec: Double
    var phoneRSSI: Int?          // RSSI of *this* phone's connection
    var armingRemaining: Int     // seconds of silent "hide" time left
    var cooldownRemaining: Int
    var playing: Bool
    var uploadReceived: Int?
    var uploadTotal: Int?

    init(json d: [String: Any]) {
        present = jsonInt(d["st"]) == 1
        lastRSSI = jsonInt(d["r"])
        msSinceSeen = jsonInt(d["age"])
        smoothed = jsonDouble(d["s"])
        packetsPerSec = jsonDouble(d["pps"]) ?? 0
        phoneRSSI = jsonInt(d["cr"])
        armingRemaining = jsonInt(d["wait"]) ?? 0
        cooldownRemaining = jsonInt(d["cd"]) ?? 0
        playing = jsonBool(d["busy"])
        uploadReceived = jsonInt(d["up"])
        uploadTotal = jsonInt(d["upT"])
    }

    var everSeen: Bool { msSinceSeen != nil }
    /// The target is actively being heard right now (a packet within the last 5 s).
    var hearingTarget: Bool { (msSinceSeen ?? .max) < 5000 }
}

enum EnrollResult: Int {
    case none = 0, success, timeout, failed, cancelled

    var text: String? {
        switch self {
        case .none: return nil
        case .success: return "Last enrollment succeeded."
        case .timeout: return "Last enrollment timed out (3 minutes) before the phone paired."
        case .failed: return "Last enrollment failed: the phone paired but didn't share its identity key. Try again."
        case .cancelled: return "Last enrollment was cancelled with the button."
        }
    }
}

/// Slower-changing device info, sent every few seconds and on changes.
struct DeviceInfo {
    var protocolVersion: Int
    var firmware: String
    var hasTarget: Bool
    var enterClipBytes: Int
    var leaveClipBytes: Int
    var freeBytes: Int
    var enrollResult: EnrollResult
    var uptimeSec: Int

    init(json d: [String: Any]) {
        protocolVersion = jsonInt(d["v"]) ?? 0
        firmware = d["fw"] as? String ?? "?"
        hasTarget = jsonBool(d["irk"])
        enterClipBytes = jsonInt(d["ce"]) ?? 0
        leaveClipBytes = jsonInt(d["cl"]) ?? 0
        freeBytes = jsonInt(d["free"]) ?? 0
        enrollResult = EnrollResult(rawValue: jsonInt(d["er"]) ?? 0) ?? .none
        uptimeSec = jsonInt(d["upt"]) ?? 0
    }

    func clipBytes(_ clip: Clip) -> Int { clip == .enter ? enterClipBytes : leaveClipBytes }
}

struct DeviceEvent: Identifiable {
    let id = UUID()
    let date: Date
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
    let enter: Bool
    let played: Bool
}

struct RSSIPoint: Identifiable {
    let id = UUID()
    let date: Date
    let target: Double?     // smoothed target RSSI (what the device uses)
    let targetRaw: Double?  // last raw target packet
    let phone: Double?      // this phone's connection RSSI, smoothed
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
