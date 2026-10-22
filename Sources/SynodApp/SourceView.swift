import AppKit
import SwiftUI

/// Maps 1-based line and column (in code points) to a UTF-16 offset in `text`.
enum SourceLocator {
    static func offset(in text: String, line: Int, col: Int) -> Int {
        let ns = text as NSString
        var lineStart = 0
        var current = 1
        while current < line {
            let r = ns.range(of: "\n", range: NSRange(location: lineStart, length: ns.length - lineStart))
            if r.location == NSNotFound { return ns.length }
            lineStart = r.location + 1
            current += 1
        }
        var offset = lineStart
        var remaining = max(col - 1, 0)
        while remaining > 0 && offset < ns.length {
            let c = ns.character(at: offset)
            if c == 0x0A { break }
            let isHigh = (0xD800...0xDBFF).contains(c) && offset + 1 < ns.length
            offset += isHigh ? 2 : 1
            remaining -= 1
        }
        return offset
    }

    /// The range of a span; a missing end covers the rest of the line, an empty span one character.
    static func range(in text: String, line: Int, col: Int, endLine: Int?, endCol: Int?) -> NSRange {
        let ns = text as NSString
        let start = offset(in: text, line: line, col: col)
        var end: Int
        if let endLine, let endCol {
            end = offset(in: text, line: endLine, col: endCol)
        } else {
            let eol = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            end = eol.location == NSNotFound ? ns.length : eol.location
        }
        if end <= start { end = min(start + 1, ns.length) }
        return NSRange(location: start, length: max(0, end - start))
    }
}

/// Read-only source text on TextKit 2 with temporary highlight attributes.
struct SourceTextView: NSViewRepresentable {
    let text: String
    let primary: SourceTarget.Span?
    let secondary: [SourceTarget.Span]

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView(usingTextLayoutManager: true)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView,
              let layout = tv.textLayoutManager, let content = tv.textContentStorage else { return }
        if tv.string != text { tv.string = text }
        tv.textColor = .labelColor
        layout.removeRenderingAttribute(.backgroundColor, for: content.documentRange)
        layout.removeRenderingAttribute(.underlineStyle, for: content.documentRange)

        func textRange(_ r: NSRange) -> NSTextRange? {
            guard let s = content.location(content.documentRange.location, offsetBy: r.location),
                  let e = content.location(s, offsetBy: r.length) else { return nil }
            return NSTextRange(location: s, end: e)
        }
        for span in secondary {
            let r = SourceLocator.range(in: text, line: span.line, col: span.col, endLine: span.endLine, endCol: span.endCol)
            if let tr = textRange(r) {
                layout.addRenderingAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, for: tr)
            }
        }
        if let p = primary {
            let r = SourceLocator.range(in: text, line: p.line, col: p.col, endLine: p.endLine, endCol: p.endCol)
            if let tr = textRange(r) {
                layout.addRenderingAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.45), for: tr)
                DispatchQueue.main.async {
                    layout.ensureLayout(for: tr)
                    tv.scrollRangeToVisible(r)
                }
            }
        } else {
            tv.scroll(.zero)
        }
    }
}

struct SourceView: View {
    @Bindable var model: WorkspaceModel
    @State private var text = ""
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            if let target = model.source {
                HStack {
                    Picker("File", selection: Binding(get: { target.file }, set: { f in
                        model.source = SourceTarget(file: f, origin: target.origin)
                    })) {
                        ForEach(model.siblingFiles, id: \.self) { Text($0).tag($0) }
                        if !model.siblingFiles.contains(target.file) { Text(target.file).tag(target.file) }
                    }
                    .labelsHidden()
                    Spacer()
                    Button("Open in Editor") { model.openInEditor() }
                }
                .padding(8)
                Divider()
                if let loadError {
                    ContentUnavailableView("Cannot read file", systemImage: "doc.questionmark", description: Text(loadError))
                } else {
                    SourceTextView(text: text, primary: target.primary, secondary: target.secondary)
                }
            } else {
                ContentUnavailableView("No file", systemImage: "doc.text", description: Text("Select a program, a package or a problem."))
            }
        }
        .task(id: model.source?.file ?? "") { load() }
        .onChange(of: model.source) { _, _ in load() }
        .onChange(of: model.coordinator.loaded?.sceneText.count) { _, _ in load() }
    }

    private func load() {
        guard let t = model.source, let url = model.fileURL(for: t) else { text = ""; return }
        do {
            let s = try String(contentsOf: url, encoding: .utf8)
            if s != text { text = s }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
