import SwiftUI
import SynodCore
import SynodWeb
import WebKit

/// Hosts a web view the model owns (Compare's page).
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The two stages with their titles, and the shared timeline below.
struct CompareArea: View {
    @Bindable var model: WorkspaceModel
    @Bindable var compare: CompareModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                WebViewHost(webView: compare.controller.webView)
                HStack(spacing: 2) {
                    SideLabel(title: compare.left.title, tint: .blue, drives: true)
                    SideLabel(title: compare.right.title, tint: .orange, drives: false)
                }
                .allowsHitTesting(false)
                if let e = compare.error {
                    BannerView(text: e, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(minHeight: 280)
            .background(Color.black)
            CompareBar(model: model, compare: compare)
        }
    }

    private struct SideLabel: View {
        let title: String
        let tint: Color
        let drives: Bool
        var body: some View {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(title).font(.caption.monospaced()).lineLimit(1)
                if drives { Text("drives").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }
    }
}

/// Controls and the shared timeline in simulated time: left markers above, right markers below.
struct CompareBar: View {
    @Bindable var model: WorkspaceModel
    @Bindable var compare: CompareModel

    var body: some View {
        VStack(spacing: 6) {
            CompareTrack(compare: compare).frame(height: 44)
            HStack(spacing: 12) {
                Button { compare.stepFact(-1) } label: { Image(systemName: "backward.frame.fill") }.help("Previous fact of the left run")
                Button { compare.togglePlay() } label: {
                    Image(systemName: compare.playing ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .help("Play or pause both runs")
                Button { compare.stepFact(1) } label: { Image(systemName: "forward.frame.fill") }.help("Next fact of the left run")
                Menu {
                    ForEach(SpeedChoice.all, id: \.self) { r in Button(SpeedChoice.label(r)) { compare.setSpeed(r) } }
                } label: { Text(SpeedChoice.label(compare.speed)).monospacedDigit() }
                    .menuStyle(.button).fixedSize()
                Picker("Sync", selection: Binding(get: { compare.sync }, set: { compare.setSync($0) })) {
                    Text("Simulated time").tag(CompareSync.sim)
                    Text("Presentation time").tag(CompareSync.presentation)
                }
                .pickerStyle(.segmented).frame(width: 260).labelsHidden()
                .help("How the right run follows the left one")
                Button { compare.swap() } label: { Label("Swap", systemImage: "arrow.left.arrow.right") }
                    .help("Exchange the two runs")
                Spacer()
                let t = compare.times
                Text("sim \(SimTime(microseconds: Int64(t.simMicros)).description)")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Button("Exit Compare") { model.exitCompare() }
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
}

struct CompareTrack: View {
    @Bindable var compare: CompareModel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let domain = compare.domain
            let t = compare.times
            let lt = CompareLogic.ticks(markers: compare.left.run.scene.markers, map: compare.leftMap, domain: domain, width: w)
            let rt = CompareLogic.ticks(markers: compare.right.run.scene.markers, map: compare.rightMap, domain: domain, width: w)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1).offset(y: 0).frame(maxHeight: .infinity)
                ForEach(Array(lt.enumerated()), id: \.offset) { _, tick in
                    Rectangle().fill(color(tick.kind)).frame(width: 2, height: 14).position(x: tick.x, y: 9)
                        .help(tick.text.isEmpty ? tick.kind : tick.text)
                }
                ForEach(Array(rt.enumerated()), id: \.offset) { _, tick in
                    Rectangle().fill(color(tick.kind)).frame(width: 2, height: 14).position(x: tick.x, y: geo.size.height - 9)
                        .help(tick.text.isEmpty ? tick.kind : tick.text)
                }
                Rectangle().fill(Color.primary).frame(width: 2)
                    .offset(x: min(max(t.simMicros / domain, 0), 1) * w - 1)
                Text("left").font(.system(size: 8)).foregroundStyle(.secondary).position(x: 14, y: 5)
                Text("right").font(.system(size: 8)).foregroundStyle(.secondary).position(x: 16, y: geo.size.height - 5)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in compare.seek(toFraction: v.location.x / max(w, 1)) })
        }
    }

    private func color(_ kind: String) -> Color {
        switch kind {
        case "pause": return .blue
        case "caption": return .secondary
        case "broken", "failed": return .red
        default: return .gray
        }
    }
}

/// The inspector in Compare: nodes matched by name, and two columns for the selected node with the
/// differing fields highlighted.
struct CompareInspectorView: View {
    @Bindable var model: WorkspaceModel
    @Bindable var compare: CompareModel

    var body: some View {
        VStack(spacing: 0) {
            List(compare.pairs, selection: Binding(get: { compare.selectedNode }, set: { compare.selectedNode = $0 })) { pair in
                HStack {
                    Text(pair.name)
                    Spacer()
                    if !pair.isMatched {
                        Text(pair.inLeft ? "left only" : "right only").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(pair.name as String?)
            }
            .frame(height: min(CGFloat(compare.pairs.count) * 26 + 12, 170))
            Divider()
            if let node = compare.selectedNode {
                let rows = compare.rows
                HStack {
                    Text(node).font(.headline)
                    Spacer()
                    Text("left").frame(width: 110, alignment: .trailing)
                    Text("right").frame(width: 110, alignment: .trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                List(rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.name).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        value(row.left).frame(width: 110, alignment: .trailing)
                        value(row.right).frame(width: 110, alignment: .trailing)
                    }
                    .listRowBackground(row.differs ? Color.orange.opacity(0.25) : nil)
                }
            } else {
                Text("Select a node.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func value(_ s: String?) -> some View {
        Text(s ?? "none").font(.system(.callout, design: .monospaced)).lineLimit(3).multilineTextAlignment(.trailing)
            .foregroundStyle(s == nil ? .secondary : .primary)
    }
}
