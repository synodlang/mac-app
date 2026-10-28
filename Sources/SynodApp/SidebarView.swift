import SwiftUI
import SynodCore

struct SidebarView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { if let s = $0 { model.select(s) } })) {
            if !model.isReadOnly || !model.scan.programs.isEmpty {
                Section("Programs") {
                    ForEach(model.scan.programs) { p in
                        Label(p.relPath == "." ? p.name : p.relPath, systemImage: "play.rectangle")
                            .tag(WorkspaceModel.Item(origin: .own, kind: .program, relPath: p.relPath))
                    }
                }
            }
            if !model.scan.packages.isEmpty {
                Section("Packages") {
                    ForEach(model.scan.packages) { p in
                        Label(p.relPath, systemImage: "shippingbox")
                            .tag(WorkspaceModel.Item(origin: .own, kind: .package, relPath: p.relPath))
                    }
                }
            }
            if let ex = model.examplesScan {
                Section("Examples") {
                    ForEach(ex.programs) { p in
                        Label(p.relPath, systemImage: "lock")
                            .tag(WorkspaceModel.Item(origin: .examples, kind: .program, relPath: p.relPath))
                    }
                    ForEach(ex.packages) { p in
                        Label(p.relPath, systemImage: "shippingbox")
                            .tag(WorkspaceModel.Item(origin: .examples, kind: .package, relPath: p.relPath))
                    }
                }
            }
            if let lk = model.looksScan {
                Section("Looks") {
                    ForEach(lk.programs) { p in
                        Label(p.relPath, systemImage: "lock")
                            .tag(WorkspaceModel.Item(origin: .looks, kind: .program, relPath: p.relPath))
                    }
                    ForEach(lk.packages) { p in
                        Label(p.relPath, systemImage: "paintpalette")
                            .tag(WorkspaceModel.Item(origin: .looks, kind: .package, relPath: p.relPath))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Copy Examples to Folder…") { model.copyExamples() }
                .buttonStyle(.link)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
