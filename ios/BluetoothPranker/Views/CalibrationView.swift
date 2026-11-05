import Charts
import SwiftUI

struct CalibrationView: View {
    @Environment(BLEManager.self) private var ble

    enum Source: Hashable {
        case phone          // this iPhone's connection to the device
        case target(Int)    // an enrolled phone, exactly as the device sees it
    }

    enum Spot { case inside, outside }

    @State private var source: Source
    @State private var capturing: Spot?
    @State private var captureStart = Date()
    @State private var samples: [Double] = []
    @State private var inside: Double?
    @State private var outside: Double?
    @State private var enterDraft: Double = -70
    @State private var exitDraft: Double = -82

    private let captureSeconds: TimeInterval = 10

    init(initialSource: Source = .phone) {
        _source = State(initialValue: initialSource)
    }

    private var currentValue: Double? {
        switch source {
        case .phone: return ble.phoneSmoothed
        case .target(let id):
            guard let s = ble.targetStatus[id], s.hearing else { return nil }
            return s.smoothed
        }
    }

    private var dirty: Bool {
        guard let c = ble.config else { return false }
        return Int(enterDraft) != c.enterRssi || Int(exitDraft) != c.exitRssi
    }

    var body: some View {
        List {
            Section {
                Picker("Measure", selection: $source) {
                    Text("This phone (app connection)").tag(Source.phone)
                    ForEach(ble.enabledTargets) { t in
                        Text("Target: \(t.name)").tag(Source.target(t.id))
                    }
                }
                Text(sourceHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Live signal") {
                RSSIChart(points: ble.history, source: source, enter: Int(enterDraft), exit: Int(exitDraft))
                    .frame(height: 220)
                LabeledContent("Now") {
                    Text(currentValue.map { "\(Int($0.rounded())) dBm" } ?? "no signal")
                        .monospacedDigit()
                }
            }

            Section {
                CaptureRow(title: "1. Inside", detail: "Stand where someone should count as *in*, e.g. a step inside the doorway.",
                           value: inside, isCapturing: capturing == .inside, progress: progress) { start(.inside) }
                    .disabled(capturing != nil)
                CaptureRow(title: "2. Outside", detail: "Stand where someone should count as *out*, e.g. in the hallway or next room.",
                           value: outside, isCapturing: capturing == .outside, progress: progress) { start(.outside) }
                    .disabled(capturing != nil)
                if let i = inside, let o = outside {
                    let s = Calibration.suggest(inside: i, outside: o)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Suggested: enter at **\(s.enter) dBm**, leave at **\(s.exit) dBm**")
                        if let w = s.warning {
                            Label(w, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Button("Use these values") {
                        enterDraft = Double(s.enter)
                        exitDraft = Double(s.exit)
                        save()
                    }
                }
            } header: {
                Text("Guided calibration")
            } footer: {
                Text("Each step averages about \(Int(captureSeconds)) seconds of signal. Stand still while it measures.")
            }

            Section {
                VStack(alignment: .leading) {
                    LabeledContent("Enter when stronger than", value: "\(Int(enterDraft)) dBm")
                    Slider(value: $enterDraft, in: -100 ... -30, step: 1)
                        .tint(.green)
                }
                VStack(alignment: .leading) {
                    LabeledContent("Leave when weaker than", value: "\(Int(exitDraft)) dBm")
                    Slider(value: $exitDraft, in: -105 ... -35, step: 1)
                        .tint(.red)
                }
                Button("Save thresholds", action: save)
                    .disabled(!dirty)
            } header: {
                Text("Thresholds")
            } footer: {
                Text("Higher (closer to 0) means closer to the device. Keep a gap between the two values so it doesn't flip back and forth at the doorway. 'Leave' also triggers when a phone hasn't been heard for the 'gone' time in Settings.")
            }
        }
        .navigationTitle("Calibrate")
        .onAppear {
            if let c = ble.config {
                enterDraft = Double(c.enterRssi)
                exitDraft = Double(c.exitRssi)
            }
        }
        .onChange(of: enterDraft) { _, v in if exitDraft > v - 2 { exitDraft = v - 2 } }
        .onChange(of: exitDraft) { _, v in if enterDraft < v + 2 { enterDraft = v + 2 } }
        .onChange(of: ble.statusSeq) { _, _ in collect() }
        .onChange(of: source) { _, _ in
            capturing = nil
            inside = nil
            outside = nil
        }
        .sensoryFeedback(.impact, trigger: ble.events.first?.id)
    }

    private var sourceHelp: String {
        switch source {
        case .phone:
            return "Uses this iPhone's connection to the app, so you don't need to enroll anything. Close enough to how the device hears a target, typically within a few dB."
        case .target(let id):
            return "Uses \(ble.targetName(id))'s phone exactly as the device detects it. Most accurate. If that's your phone, enroll it as a target first. Keep it in a pocket like the real target would, since a body blocks a few dB."
        }
    }

    private var progress: Double {
        min(1, Date().timeIntervalSince(captureStart) / captureSeconds)
    }

    private func start(_ spot: Spot) {
        samples = []
        captureStart = Date()
        capturing = spot
    }

    private func collect() {
        guard let spot = capturing else { return }
        if let v = currentValue { samples.append(v) }
        guard Date().timeIntervalSince(captureStart) >= captureSeconds else { return }
        capturing = nil
        guard let m = Calibration.median(samples), samples.count >= 5 else {
            ble.lastError = source == .phone
                ? "Didn't get enough signal readings. Stay connected and try again."
                : "Couldn't hear that phone. Is it enrolled, enabled and nearby?"
            return
        }
        if spot == .inside { inside = m } else { outside = m }
    }

    private func save() {
        let enter = Int(enterDraft), exit = Int(exitDraft)
        ble.perform {
            try await ble.update {
                $0.enterRssi = enter
                $0.exitRssi = exit
            }
        }
    }
}

private struct CaptureRow: View {
    let title: String
    let detail: LocalizedStringKey
    let value: Double?
    let isCapturing: Bool
    let progress: Double
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let value {
                    Text("\(Int(value.rounded())) dBm").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            if isCapturing {
                ProgressView(value: progress) { Text("Measuring…").font(.caption) }
            } else {
                Button(value == nil ? "Measure here" : "Measure again", action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

struct RSSIChart: View {
    let points: [RSSIPoint]
    let source: CalibrationView.Source
    let enter: Int
    let exit: Int

    private var targetID: Int? {
        if case .target(let id) = source { return id }
        return nil
    }

    var body: some View {
        Chart {
            ForEach(points) { p in
                if let id = targetID {
                    if let raw = p.raw[id] {
                        PointMark(x: .value("Time", p.date), y: .value("dBm", raw))
                            .symbolSize(10)
                            .foregroundStyle(Color.gray.opacity(0.5))
                    }
                    if let t = p.smoothed[id] {
                        LineMark(x: .value("Time", p.date), y: .value("dBm", t), series: .value("Series", "target"))
                            .foregroundStyle(Color.blue)
                    }
                } else if let ph = p.phone {
                    LineMark(x: .value("Time", p.date), y: .value("dBm", ph), series: .value("Series", "phone"))
                        .foregroundStyle(Color.purple)
                }
            }
            RuleMark(y: .value("Enter", enter))
                .foregroundStyle(Color.green)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("enter").font(.caption2).foregroundStyle(.green)
                }
            RuleMark(y: .value("Leave", exit))
                .foregroundStyle(Color.red)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .bottom, alignment: .leading) {
                    Text("leave").font(.caption2).foregroundStyle(.red)
                }
        }
        .chartYScale(domain: -105 ... -25)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.minute().second())
            }
        }
    }
}
