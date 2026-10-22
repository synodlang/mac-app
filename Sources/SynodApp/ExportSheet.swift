import AppKit
import SwiftUI
import SynodWeb
import UniformTypeIdentifiers

struct ExportSheet: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    enum Format: String, CaseIterable, Identifiable {
        case video = "Video", gif = "GIF"
        var id: String { rawValue }
    }

    enum GIFRange: String, CaseIterable, Identifiable {
        case whole = "Whole scene", fromPlayhead = "From the playhead"
        var id: String { rawValue }
    }

    @State private var format: Format = .video
    @State private var gifWidth = GIFLimits.defaultWidth
    @State private var gifFPS = GIFLimits.defaultFrameRate
    @State private var gifRange: GIFRange = .whole
    @State private var gifSeconds = "5"
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
            Text("Export").font(.title2.bold())
            Picker("Format", selection: $format) {
                ForEach(Format.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().disabled(running)
            Form {
                if format == .video {
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
                } else {
                    Picker("Width", selection: $gifWidth) {
                        ForEach(GIFLimits.widths, id: \.self) { Text("\($0) px").tag($0) }
                    }
                    Picker("Frame rate", selection: $gifFPS) {
                        ForEach(GIFLimits.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    Picker("Range", selection: $gifRange) {
                        ForEach(GIFRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if gifRange == .fromPlayhead {
                        TextField("Seconds", text: $gifSeconds)
                    }
                }
                Picker("Speed", selection: $rate) {
                    ForEach(SpeedChoice.all, id: \.self) { Text(SpeedChoice.label($0)).tag($0) }
                }
            }
            .disabled(running)
            if format == .gif { gifSummary }
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
                        .disabled(format == .gif && !gifValid)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { rate = SpeedChoice.all.contains(model.speed) ? model.speed : 1 }
    }

    // MARK: GIF

    /// The range in presentation time (ms) the sheet describes.
    private var gifBounds: (from: Double, to: Double?) {
        guard gifRange == .fromPlayhead else { return (0, nil) }
        let from = model.stage?.state.time ?? 0
        let secs = Double(gifSeconds.replacingOccurrences(of: ",", with: ".")) ?? 5
        return (from, from + max(0.1, secs) * 1000)
    }

    private var gifOptions: GIFExportOptions {
        var o = GIFExportOptions()
        o.width = gifWidth
        o.fps = gifFPS
        o.rate = rate
        o.from = gifBounds.from
        o.to = gifBounds.to
        return o
    }

    /// The frame count, size and estimated file size, or the reason the export cannot start.
    private var gifLayout: Result<(plan: ExportPlan, width: Int, height: Int), Error>? {
        guard let run = model.loaded else { return nil }
        return Result { try Exporter.gifLayout(sceneText: run.sceneText, duration: run.scene.duration, options: gifOptions) }
    }

    @ViewBuilder private var gifSummary: some View {
        switch gifLayout {
        case .success(let layout):
            let bytes = GIFLimits.estimatedBytes(width: layout.width, height: layout.height, frames: layout.plan.frameCount)
            Text("\(layout.plan.frameCount) frames, \(layout.width)×\(layout.height) px, about \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)). The GIF loops forever.")
                .font(.callout).foregroundStyle(.secondary)
        case .failure(let error):
            Text(error.friendlyText).font(.callout).foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }

    private var gifValid: Bool {
        if case .success = gifLayout { return true }
        return false
    }

    private func start() {
        guard let run = model.loaded else { return }
        if format == .gif { startGIF(run) } else { startVideo(run) }
    }

    private func startGIF(_ run: LoadedRun) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = ((model.activeProgram?.name ?? "synod") + ".gif")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let options = gifOptions
        let sceneText = run.sceneText
        running = true
        message = nil
        progress = nil
        task = Task {
            do {
                let result = try await Exporter(assets: WebAssets.locate()).exportGIF(sceneText: sceneText, to: url, options: options) { p in
                    progress = p
                }
                message = "Exported \(result.frames) frames (\(ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file))) to \(url.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch is CancellationError {
                message = "Export cancelled; the partial file was removed."
            } catch {
                message = "Export failed: \(error.friendlyText)"
            }
            running = false
        }
    }

    private func startVideo(_ run: LoadedRun) {
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

extension Error {
    /// GIF and stage errors describe themselves with `description`, not `localizedDescription`.
    var friendlyText: String {
        if let e = self as? GIFError { return e.description }
        if let e = self as? StageError { return e.description }
        return localizedDescription
    }
}
