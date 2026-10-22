import SwiftUI
import SynodCore
import SynodWeb

struct TimelineBar: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 6) {
            TimelineTrack(model: model)
                .frame(height: 34)
            HStack(spacing: 12) {
                Button { model.stepFact(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .help("Previous fact (←)")
                Button { model.togglePlay() } label: {
                    Image(systemName: (model.stage?.state.playing ?? false) ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .help("Play or pause (Space)")
                Button { model.stepFact(1) } label: { Image(systemName: "forward.frame.fill") }
                    .help("Next fact (→)")
                Menu {
                    ForEach(SpeedChoice.all, id: \.self) { r in
                        Button(SpeedChoice.label(r)) { model.setSpeed(r) }
                    }
                } label: { Text(SpeedChoice.label(model.speed)).monospacedDigit() }
                    .menuStyle(.button).fixedSize()
                    .help("Playback speed")
                Spacer()
                TimeReadout(model: model)
            }
            .buttonStyle(.borderless)
            .disabled(model.loaded == nil)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
}

struct TimeReadout: View {
    let model: WorkspaceModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !(model.stage?.state.playing ?? false))) { ctx in
            let at = smoothed(ctx.date)
            let sim = model.loaded.flatMap { run in
                run.trace.factAt(at).flatMap { run.trace.simTime(ofSeq: $0.seq) }
            }
            HStack(spacing: 10) {
                Text(String(format: "%.1fs / %.1fs", at / 1000, model.timeline.duration / 1000))
                if let sim { Text("sim \(sim.description)").foregroundStyle(.secondary) }
            }
            .font(.system(.callout, design: .monospaced))
        }
    }

    func smoothed(_ now: Date) -> Double {
        guard let s = model.stage?.state else { return 0 }
        return TimelineModel.smoothedTime(lastAt: s.time, lastWall: s.lastTimeWall, now: now, rate: model.speed,
                                          playing: s.playing, duration: model.timeline.duration)
    }
}

struct TimelineTrack: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !(model.stage?.state.playing ?? false))) { ctx in
                let at = TimeReadout(model: model).smoothed(ctx.date)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                    Canvas { gc, size in
                        let bins = max(1, Int(size.width / 3))
                        let d = model.timeline.density(bins: bins)
                        let bw = size.width / Double(bins)
                        for (i, v) in d.enumerated() where v > 0 {
                            let h = max(1, (size.height - 14) * v)
                            gc.fill(Path(CGRect(x: Double(i) * bw, y: size.height - h, width: max(1, bw - 0.5), height: h)),
                                    with: .color(.accentColor.opacity(0.45)))
                        }
                    }
                    ForEach(Array(model.timeline.ticks(width: w).enumerated()), id: \.offset) { _, t in
                        Rectangle().fill(color(t.kind)).frame(width: 2, height: 12)
                            .overlay(alignment: .top) { if t.kind == "pause" { Text("?").font(.system(size: 9, weight: .bold)).offset(y: -9).foregroundStyle(color(t.kind)) } }
                            .position(x: t.x, y: 7)
                            .help(t.text.isEmpty ? t.kind : t.text)
                            .onTapGesture { model.seek(to: t.at) }
                    }
                    ForEach(Array(model.pulseTimes.enumerated()), id: \.offset) { _, t in
                        PulsingMarker().position(x: model.timeline.fraction(at: t) * w, y: 7)
                            .help("Your change broke a rule here")
                            .onTapGesture { model.seek(to: t) }
                    }
                    Rectangle().fill(Color.primary).frame(width: 2)
                        .offset(x: model.timeline.fraction(at: at) * w - 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in model.scrub(toFraction: v.location.x / max(w, 1)) }
                .onEnded { v in model.scrub(toFraction: v.location.x / max(w, 1), force: true) })
        }
    }

    func color(_ kind: String) -> Color {
        switch kind {
        case "pause": return .blue
        case "caption": return .secondary
        case "broken", "failed": return .red
        default: return .gray
        }
    }
}

/// A red marker that pulses, for the fact where a Break it broke a rule.
struct PulsingMarker: View {
    @State private var on = false

    var body: some View {
        ZStack {
            Circle().fill(Color.red.opacity(0.35)).frame(width: 18, height: 18).scaleEffect(on ? 1.0 : 0.4).opacity(on ? 0.0 : 0.9)
            Circle().fill(Color.red).frame(width: 8, height: 8)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) { on = true } }
    }
}
