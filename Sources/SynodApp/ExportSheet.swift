import AppKit
import SwiftUI
import SynodWeb
import UniformTypeIdentifiers

struct ExportSheet: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    @State private var size: ExportSize = .hd1080
    @State private var codec: VideoCodec = .h264
    @State private var fps = 60
    @State private var rate = 1.0
    @State private var progress: ExportProgress?
    @State private var running = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Video").font(.title2.bold())
            Form {
                Picker("Size", selection: $size) {
                    Text("1080p (1920×1080)").tag(ExportSize.hd1080)
                    Text("4K (3840×2160)").tag(ExportSize.uhd4k)
                }
                Picker("Codec", selection: $codec) {
                    Text("H.264").tag(VideoCodec.h264)
                    Text("HEVC").tag(VideoCodec.hevc)
                }
                Picker("Frame rate", selection: $fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Speed", selection: $rate) {
                    ForEach(SpeedChoice.all, id: \.self) { Text(SpeedChoice.label($0)).tag($0) }
                }
            }
            .disabled(running)
            if running || progress != nil {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(progress?.frame ?? 0), total: Double(max(progress?.total ?? 1, 1)))
                    if let p = progress {
                        Text(String(format: "Frame %d of %d, %.1f frames/s, about %.0f s left", p.frame, p.total, p.framesPerSecond, p.eta))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                if running {
                    Button("Cancel Export", role: .cancel) { task?.cancel() }
                } else {
                    Button("Close") { dismiss() }
                    Button("Export…") { start() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { rate = SpeedChoice.all.contains(model.speed) ? model.speed : 1 }
    }

    private func start() {
        guard let run = model.loaded else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = ((model.activeProgram?.name ?? "synod") + ".mp4")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var options = ExportOptions()
        options.size = size
        options.codec = codec
        options.fps = fps
        options.rate = rate
        let sceneText = run.sceneText
        running = true
        message = nil
        progress = nil
        task = Task {
            do {
                let result = try await Exporter(assets: WebAssets.locate()).export(sceneText: sceneText, to: url, options: options) { p in
                    progress = p
                }
                message = "Exported \(result.frames) frames to \(url.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch is CancellationError {
                message = "Export cancelled; the partial file was removed."
            } catch {
                message = "Export failed: \(error.localizedDescription)"
            }
            running = false
        }
    }
}
