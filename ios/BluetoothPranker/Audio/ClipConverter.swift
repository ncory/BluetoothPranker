import AVFoundation

/// Converts any audio file iOS can read into the format the firmware plays:
/// 16 kHz, mono, 16-bit PCM WAV. Also trims silence and normalizes loudness,
/// which matters a lot on the Atom Echo's tiny speaker.
enum ClipConverter {
    static let sampleRate: Double = 16_000
    static let maxSeconds: Double = 12

    struct Result {
        let wav: Data
        let duration: Double
    }

    enum ConvertError: LocalizedError {
        case unreadable, conversionFailed, silent
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read that audio file."
            case .conversionFailed: return "Couldn't convert the audio."
            case .silent: return "That clip is silent."
            }
        }
    }

    static func convert(url: URL) throws -> Result {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard file.length > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw ConvertError.unreadable
        }
        converter.downmix = true

        // Read a bit more than the limit so silence trimming has room to work.
        let maxFrames = AVAudioFrameCount(min(Double(file.length), (maxSeconds + 3) * inFormat.sampleRate))
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: maxFrames) else {
            throw ConvertError.unreadable
        }
        try file.read(into: inBuf, frameCount: maxFrames)

        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * sampleRate / inFormat.sampleRate) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw ConvertError.conversionFailed
        }
        var fed = false
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return inBuf
        }
        guard status != .error, let channel = outBuf.floatChannelData?[0] else {
            throw convError ?? ConvertError.conversionFailed
        }

        var samples = Array(UnsafeBufferPointer(start: channel, count: Int(outBuf.frameLength)))
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0.001 else { throw ConvertError.silent }

        // Trim leading/trailing silence (below 3% of peak), keeping 30 ms of padding.
        let threshold = peak * 0.03
        let pad = Int(sampleRate * 0.03)
        let first = max(0, (samples.firstIndex { abs($0) > threshold } ?? 0) - pad)
        let last = min(samples.count - 1, (samples.lastIndex { abs($0) > threshold } ?? samples.count - 1) + pad)
        samples = Array(samples[first...last])
        if samples.count > Int(maxSeconds * sampleRate) { samples = Array(samples.prefix(Int(maxSeconds * sampleRate))) }

        // Normalize to ~98% and fade the edges to avoid clicks.
        let gain = 0.98 / peak
        let fade = min(Int(sampleRate * 0.008), samples.count / 2)
        var pcm = Data(capacity: samples.count * 2)
        for (i, s) in samples.enumerated() {
            var v = s * gain
            if i < fade { v *= Float(i) / Float(fade) }
            if i >= samples.count - fade { v *= Float(samples.count - 1 - i) / Float(fade) }
            var q = Int16(max(-1, min(1, v)) * 32767).littleEndian
            withUnsafeBytes(of: &q) { pcm.append(contentsOf: $0) }
        }
        return Result(wav: wavHeader(dataBytes: pcm.count) + pcm, duration: Double(samples.count) / sampleRate)
    }

    static func wavHeader(dataBytes: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)            // PCM
        u16(1)            // mono
        u32(rate)
        u32(rate * 2)     // byte rate
        u16(2)            // block align
        u16(16)           // bits per sample
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        return d
    }
}
