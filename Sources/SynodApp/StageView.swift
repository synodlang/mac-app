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
        // Status banners sit in a bar above the stage, never over it, so they cannot cover its text.
        VStack(spacing: 0) {
            statusBar
            stage
        }
        .frame(minHeight: 280)
        .background(Color.black)
    }

    @ViewBuilder private var statusBar: some View {
        let failure = failureText
        let stale = model.coordinator.stale
        VStack(spacing: 4) {
            BreakItBanners(model: model)
            if let failure {
                BannerView(text: failure, systemImage: "exclamationmark.octagon.fill", tint: .red)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.vertical, 2)
            }
            if stale {
                BannerView(text: "Stale: the last run failed. Showing the previous good run.", systemImage: "clock.badge.exclamationmark", tint: .orange)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var stage: some View {
        ZStack(alignment: .bottom) {
            if let stage = model.stage {
                StageView(controller: stage)
            } else {
                Color.black
            }
            VStack(spacing: 8) {
                BoxSelectionChip(model: model)
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
    }

    private var failureText: String? {
        if let f = model.loaded?.status.fault { return "Run failed at \(f.time): \(f.message)" }
        if let f = model.loaded?.status.lookFault { return "Look failed at \(f.time): \(f.message)" }
        return model.banner
    }
}
