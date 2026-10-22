import SwiftUI
import SynodCore
import SynodWeb

/// The Break it actions for what is selected: a node (Crash or Restart), a dragged box (Partition),
/// an active partition (Heal) and a clicked message (Drop this message). They sit in the inspector.
struct BreakItActionsView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        let b = model.breakIt
        let availability = b.availability
        let enabled = availability == .available
        VStack(alignment: .leading, spacing: 6) {
            Label("Break it", systemImage: "bolt.trianglebadge.exclamationmark").font(.headline)
            if case .unavailable(let why) = availability {
                Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let node = model.selectedNode {
                switch b.nodeOffer(node) {
                case .crash:
                    action("Crash \(node)", "bolt.slash", enabled) { b.begin(.crash(node: node)) }
                case .restart:
                    action("Restart \(node)", "arrow.counterclockwise", enabled) { b.begin(.restart(node: node)) }
                case .none:
                    EmptyView()
                }
            }
            if !model.boxNodes.isEmpty {
                let sel = model.boxNodes
                action("Partition \(sel.joined(separator: ", ")) from the rest", "rectangle.split.2x1", enabled) {
                    b.begin(.partition(selected: sel))
                }
            } else {
                Text("Drag a box around nodes on the stage to partition them.").font(.caption).foregroundStyle(.secondary)
            }
            if b.partitionActive {
                action("Heal the partition", "link", enabled) { b.begin(.heal) }
            }
            if let id = model.selectedMessage {
                switch b.messageOffer(id) {
                case .available:
                    action("Drop message #\(id)", "xmark.circle", enabled) { b.begin(.dropMessage(id: id)) }
                case .disabled(let reason):
                    action("Drop message #\(id)", "xmark.circle", false) {}
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                case .unknown:
                    EmptyView()
                }
            } else {
                Text("Click a message dot to drop it.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func action(_ title: String, _ image: String, _ enabled: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Label(title, systemImage: image).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(.bordered)
            .disabled(!enabled)
    }
}

/// The generated `after T` block, its time and the file it goes into; Apply edits, saves and re-runs.
struct BreakItSheet: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        let b = model.breakIt
        if let sheet = b.sheet {
            VStack(alignment: .leading, spacing: 12) {
                Text(title(for: sheet.action)).font(.title2.bold())
                Form {
                    LabeledContent("File") { Text(sheet.file).font(.body.monospaced()) }
                    TextField("Time", text: Binding(get: { sheet.timeText }, set: { b.setTimeText($0) }))
                        .disabled(!sheet.timeIsEditable)
                        .font(.body.monospaced())
                        .onSubmit { Task { await b.apply() } }
                    if let e = sheet.error { Text(e).font(.callout).foregroundStyle(.red) }
                    if !sheet.timeIsEditable {
                        Text("A drop acts when the message is sent, so its time is fixed.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !sheet.plan.statement.isEmpty {
                Text("This is added at the end of define main:").font(.callout).foregroundStyle(.secondary)
                Text(sheet.plan.blockLines.joined(separator: "\n"))
                    .font(.system(.body, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
                }
                Text("The file is saved (formatted) and the program runs again. Undo restores it.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { b.cancelSheet() }.keyboardShortcut(.cancelAction)
                    Button("Apply") { Task { await b.apply() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(sheet.error != nil)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
    }

    private func title(for a: BreakItAction) -> String {
        switch a {
        case .crash(let n): return "Crash \(n)"
        case .restart(let n): return "Restart \(n)"
        case .partition(let s): return "Partition \(s.joined(separator: ", "))"
        case .heal: return "Heal the partition"
        case .dropMessage(let id): return "Drop message #\(id)"
        }
    }
}

/// What happened after Apply: the fact was found, nothing changed, the run failed, a rule broke.
struct BreakItBanners: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        let b = model.breakIt
        VStack(spacing: 4) {
            if b.isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Break it: editing, saving and running…").font(.callout)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
            }
            switch b.outcome {
            case .applied(let seq):
                bar("bolt.fill", .orange, b.appliedSummary ?? "Break it applied") {
                    Button("Show") { model.jump(toSeq: seq) }
                    undoButtons
                    dismissButton
                }
            case .noEffect:
                bar("exclamationmark.triangle.fill", .orange, "Break it had no effect") {
                    undoButtons
                    dismissButton
                }
            case .failed(let m):
                bar("xmark.octagon.fill", .red, "Break it failed: \(m)") {
                    if b.canUndo { Button("Undo Break it") { Task { await b.undo() } } }
                    dismissButton
                }
            case nil:
                EmptyView()
            }
            if let text = b.brokenText, let first = b.broken.first {
                bar("exclamationmark.octagon.fill", .red, text) {
                    Button("Jump there") { model.jump(toSeq: first.seq) }
                    dismissButton
                }
            }
        }
    }

    @ViewBuilder private var undoButtons: some View {
        let b = model.breakIt
        if b.canUndo { Button("Undo Break it") { Task { await b.undo() } } }
        if b.before != nil { Button("Compare with before") { model.startCompare(.beforeBreakIt) } }
    }

    private var dismissButton: some View {
        Button { model.breakIt.dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
    }

    private func bar<Actions: View>(_ image: String, _ tint: Color, _ text: String,
                                    @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 8) {
            Image(systemName: image).foregroundStyle(tint)
            Text(text).font(.callout).lineLimit(3)
            Spacer(minLength: 0)
            actions().controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, 2)
    }
}

/// A floating chip over the stage after a box was dragged: the quick way to Partition.
struct BoxSelectionChip: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        if !model.boxNodes.isEmpty, model.compare == nil {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed")
                Text(model.boxNodes.joined(separator: ", ")).font(.callout.monospaced()).lineLimit(1)
                if model.breakIt.availability == .available {
                    Button("Partition…") { model.breakIt.begin(.partition(selected: model.boxNodes)) }
                        .controlSize(.small)
                }
                Button { model.boxNodes = [] } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
        }
    }
}
