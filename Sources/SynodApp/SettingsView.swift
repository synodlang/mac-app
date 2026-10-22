import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        Form {
            Section("Compiler") {
                TextField("synod path", text: $env.synodPathOverride, prompt: Text("Bundled compiler"))
                    .textFieldStyle(.roundedBorder)
                LabeledContent("In use") { Text(env.tools?.synod.path ?? "not found").textSelection(.enabled).lineLimit(2) }
                if let v = env.version {
                    LabeledContent("Version") { Text("language \(v.language), compiler \(v.compiler)") }
                }
                if let p = env.versionProblem {
                    Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .onAppear { env.probeIfNeeded() }
    }
}
