import SwiftUI
import SynodCore

/// The Predict panel (decisions 77 and 82). With choices it shows the question and one button per
/// choice (keys 1 to 6); without them the M8 text field. Nothing is graded: every pick is saved and
/// playback continues to show what really happens.
struct PredictPanel: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Predict", systemImage: "questionmark.bubble").font(.headline)
            Text(model.predictQuestion ?? "").font(.title3).fixedSize(horizontal: false, vertical: true)
            if model.predictChoices.isEmpty {
                TextField("Your answer", text: $model.predictAnswer)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.continuePredict() }
                HStack {
                    Spacer()
                    Button("Continue") { model.continuePredict() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(model.predictChoices.enumerated()), id: \.offset) { i, choice in
                        Button { model.choosePredict(i) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(i + 1)")
                                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                                    .frame(width: 20, height: 20)
                                    .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                                Text(choice).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                if model.predictPreviousChoice == i {
                                    Text("last time").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])
                        .help("Choose \(i + 1)")
                    }
                }
                Text("Press 1 to \(model.predictChoices.count) or click. Nothing is graded; the run shows what happens.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
