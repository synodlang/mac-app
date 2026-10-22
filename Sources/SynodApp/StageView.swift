import SwiftUI
import SynodWeb
import WebKit

/// Hosts the controller's web view.
struct StageView: NSViewRepresentable {
    let controller: StageController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let web = controller.webView
        web.removeFromSuperview()
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The stage with its overlays: captions, the failure banner and the Predict panel.
struct StageArea: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        ZStack(alignment: .bottom) {
            if let stage = model.stage {
                StageView(controller: stage)
            } else {
                Color.black
            }
            VStack(spacing: 8) {
                if let banner = failureText {
                    BannerView(text: banner, systemImage: "exclamationmark.octagon.fill", tint: .red)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if model.coordinator.stale {
                    BannerView(text: "Stale: the last run failed. Showing the previous good run.", systemImage: "clock.badge.exclamationmark", tint: .orange)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if let c = model.caption {
                    Text(c)
                        .font(.title3)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .transition(.opacity)
                }
                if model.predictQuestion != nil {
                    PredictPanel(model: model)
                }
            }
            .padding(12)
            .animation(.default, value: model.caption)
        }
        .overlay(alignment: .topTrailing) {
            if model.coordinator.isRunning { ProgressView().controlSize(.small).padding(10) }
        }
        .frame(minHeight: 280)
        .background(Color.black)
    }

    private var failureText: String? {
        if let f = model.loaded?.status.fault { return "Run failed at \(f.time): \(f.message)" }
        if let f = model.loaded?.status.lookFault { return "Look failed at \(f.time): \(f.message)" }
        return model.banner
    }
}

struct PredictPanel: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Predict", systemImage: "questionmark.bubble").font(.headline)
            Text(model.predictQuestion ?? "").font(.title3)
            TextField("Your answer", text: $model.predictAnswer)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.continuePredict() }
            HStack {
                Spacer()
                Button("Continue") { model.continuePredict() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
