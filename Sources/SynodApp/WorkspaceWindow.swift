import SwiftUI
import SynodCore
import SynodWeb

struct WorkspaceWindow: View {
    let url: URL
    @Environment(AppEnvironment.self) private var env
    @State private var model: WorkspaceModel?
    @State private var error: String?

    var body: some View {
        Group {
            if let model {
                WorkspaceView(model: model)
            } else if let error {
                ContentUnavailableView("Cannot open this folder", systemImage: "folder.badge.questionmark", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .task(id: url) {
            env.probeIfNeeded()
            do {
                model = WorkspaceModel(workspace: try Workspace.open(url), env: env)
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onDisappear { model?.stop() }
    }
}

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let problem = env.versionProblem {
                    BannerView(text: problem, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
                if model.isReadOnly {
                    BannerView(text: "Bundled examples are read-only. Use File > Copy Examples to Folder… to edit them.", systemImage: "lock.fill", tint: .secondary)
                }
                if let err = model.stageError {
                    BannerView(text: err, systemImage: "xmark.octagon.fill", tint: .red)
                }
                if model.editorVisible {
                    VSplitView {
                        VStack(spacing: 0) {
                            StageArea(model: model)
                            TimelineBar(model: model)
                        }
                        .frame(minHeight: 340)
                        EditorPane(model: model)
                            .frame(minHeight: 150, idealHeight: 260)
                    }
                } else {
                    StageArea(model: model)
                    TimelineBar(model: model)
                }
            }
        }
        .inspector(isPresented: $model.inspectorVisible) {
            InspectorContainer(model: model)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
        }
        .navigationTitle(model.workspace.root.lastPathComponent)
        .navigationSubtitle(model.selection.map { $0.relPath } ?? "")
        .toolbar { WorkspaceToolbar(model: model) }
        .focusedSceneValue(\.workspaceModel, model)
        .sheet(isPresented: $model.showExport) { ExportSheet(model: model) }
        .onChange(of: model.copiedTo) { _, url in
            if let url { openWindow(value: url) }
        }
    }
}

struct BannerView: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout).lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(tint.opacity(0.12))
    }
}

struct WorkspaceToolbar: ToolbarContent {
    @Bindable var model: WorkspaceModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.run(.manual) } label: { Label("Run", systemImage: "arrow.clockwise") }
                .help("Run again (⌘R)")
                .disabled(model.activeProgram == nil)
            Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                Text("Ordered").tag(RunOptions.Mode.ordered)
                Text("Proportional").tag(RunOptions.Mode.proportional)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .help("How message delays are chosen when the program runs")
            HStack(spacing: 4) {
                Text("Seed").foregroundStyle(.secondary)
                TextField("program", text: $model.seedText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { model.run(.seed) }
                    .foregroundStyle(model.seedIsValid ? Color.primary : Color.red)
            }
            Toggle(isOn: Binding(get: { model.predictEnabled }, set: { model.setPredict($0) })) {
                Label("Predict", systemImage: "questionmark.bubble")
            }
            .toggleStyle(.button)
            .help("Stop at questions and ask for your answer")
            Button { model.showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(model.loaded == nil)
                .help("Export a video")
            Button { model.editorVisible.toggle() } label: { Label("Editor", systemImage: "square.and.pencil") }
                .help("Show or hide the editor (⌥⌘E)")
            Button { model.inspectorVisible.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
        }
    }
}
