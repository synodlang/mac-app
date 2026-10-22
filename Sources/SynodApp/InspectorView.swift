import SwiftUI
import SynodCore

struct InspectorContainer: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $model.tab) {
                ForEach(WorkspaceModel.InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch model.tab {
            case .inspector:
                if let compare = model.compare {
                    CompareInspectorView(model: model, compare: compare)
                } else {
                    InspectorView(model: model)
                }
            case .problems: ProblemsView(model: model)
            }
        }
    }
}

struct InspectorView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        if let run = model.loaded {
            let seq = model.currentFact?.seq ?? 0
            VStack(spacing: 0) {
                nodePicker(run: run, seq: seq)
                Divider()
                stateTable(run: run, seq: seq).frame(maxHeight: 240)
                Divider()
                BreakItActionsView(model: model)
                Divider()
                HStack {
                    Text("Trace").font(.headline)
                    Spacer()
                    Toggle("Selected node only", isOn: $model.onlySelectedNode).toggleStyle(.checkbox)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                traceList(run: run, seq: seq)
            }
        } else {
            ContentUnavailableView("Nothing running", systemImage: "waveform.path", description: Text("Run a program to inspect its nodes."))
        }
    }

    private func nodePicker(run: LoadedRun, seq: Int) -> some View {
        List(run.trace.nodes, id: \.self, selection: $model.selectedNode) { node in
            let state = run.trace.state(of: node, atSeq: seq)
            HStack {
                Circle().fill(color(state?.status)).frame(width: 8, height: 8)
                Text(node)
                Spacer()
                if let role = state?.fields.first(where: { $0.name.hasSuffix(".Role") || $0.name.hasSuffix(".State") }) {
                    Text(role.value.display).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                }
            }
            .tag(node)
        }
        .frame(height: min(CGFloat(run.trace.nodes.count) * 26 + 12, 170))
    }

    private func stateTable(run: LoadedRun, seq: Int) -> some View {
        Group {
            if let node = model.selectedNode, let state = run.trace.state(of: node, atSeq: seq) {
                let changed = state.changedFields(atSeq: seq)
                List {
                    Section("\(node) is \(state.status.rawValue)") {
                        ForEach(state.fields, id: \.name) { f in
                            HStack(alignment: .firstTextBaseline) {
                                Text(f.name).foregroundStyle(.secondary)
                                Spacer()
                                Text(f.value.display).font(.system(.body, design: .monospaced)).multilineTextAlignment(.trailing)
                            }
                            .listRowBackground(changed.contains(f.name) ? Color.accentColor.opacity(0.22) : nil)
                        }
                    }
                }
            } else {
                Text(model.selectedNode == nil ? "Select a node." : "Not started yet.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func traceList(run: LoadedRun, seq: Int) -> some View {
        let events = run.trace.window(around: seq, radius: 40, node: model.onlySelectedNode ? model.selectedNode : nil)
        return ScrollViewReader { proxy in
            List(events, id: \.seq) { e in
                Button { model.jump(toSeq: e.seq) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(e.time.description).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
                        Text(run.trace.oneLine(e)).font(.caption.monospaced()).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .listRowBackground(e.seq == seq ? Color.accentColor.opacity(0.28) : nil)
                .id(e.seq)
            }
            .onChange(of: seq) { _, s in proxy.scrollTo(s, anchor: .center) }
        }
    }

    private func color(_ s: NodeStatus?) -> Color {
        switch s {
        case .up: return .green
        case .crashed: return .red
        case .removed: return .gray
        case nil: return .secondary.opacity(0.4)
        }
    }
}
