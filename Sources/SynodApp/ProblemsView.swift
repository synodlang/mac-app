import SwiftUI
import SynodCore

/// One row of the Problems list, flattened from a check report or a run's status lines.
struct ProblemRow: Identifiable, Equatable {
    enum Severity: String { case error, warning, note }
    var id: String
    var severity: Severity
    var code: String
    var message: String
    var file: String?
    var line: Int?
    var col: Int?
    var endLine: Int?
    var endCol: Int?
    var hint: String?
    var label: String?
    var notes: [String] = []
    var labels: [CheckReport.Label] = []
    var helps: [String] = []
    /// The compiler diagnostic the row comes from; its helps with edits are quick fixes.
    var diagnostic: CheckReport.Diagnostic?

    var location: String? {
        guard let file, let line, let col else { return nil }
        return "\(file):\(line):\(col)"
    }

    static func rows(report: CheckReport?, status: RunStatus?, raw: String?, error: String?) -> [ProblemRow] {
        var rows: [ProblemRow] = []
        if let error { rows.append(ProblemRow(id: "error", severity: .error, code: "", message: error)) }
        if let report {
            for (i, d) in report.diagnostics.enumerated() {
                rows.append(ProblemRow(
                    id: "d\(i):\(d.id)", severity: d.isError ? .error : (d.severity == "warning" ? .warning : .note),
                    code: d.code, message: d.message, file: d.file, line: d.line, col: d.col,
                    endLine: d.end.line, endCol: d.end.col, hint: d.hint, label: d.label,
                    notes: d.notes, labels: d.labels, helps: d.help.map(\.text), diagnostic: d))
            }
        }
        if let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows.append(ProblemRow(id: "raw", severity: .error, code: "", message: raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if let status {
            if let f = status.fault {
                rows.append(fault(f, id: "fault", prefix: "Run failed at \(f.time): "))
            }
            if let f = status.lookFault {
                rows.append(fault(f, id: "look", prefix: "Look failed at \(f.time): "))
            }
            for (i, b) in status.broken.enumerated() {
                rows.append(ProblemRow(id: "broken\(i)", severity: .warning, code: "broken",
                                       message: "Rule broken at \(b.time) (\(b.count) time\(b.count == 1 ? "" : "s")): \(b.rule)"))
            }
        }
        return rows
    }

    private static func fault(_ f: RunFault, id: String, prefix: String) -> ProblemRow {
        ProblemRow(id: id, severity: .error, code: f.code, message: prefix + f.message,
                   file: f.pos?.file, line: f.pos?.line, col: f.pos?.col)
    }
}

struct ProblemsView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        let rows = ProblemRow.rows(report: model.problemReport, status: model.loaded?.status,
                                   raw: model.coordinator.rawProblems, error: model.coordinator.errorMessage)
        if rows.isEmpty {
            ContentUnavailableView("No problems", systemImage: "checkmark.circle", description: Text("The last run was clean."))
        } else {
            List(rows) { row in
                RowView(row: row, fixes: fixes(for: row), apply: apply, open: { open(row) })
            }
        }
    }

    private func fixes(for row: ProblemRow) -> [EditorFix] {
        guard let d = row.diagnostic else { return [] }
        let origin = model.selection?.origin ?? .own
        return d.help.filter { !$0.edits.isEmpty }.map { EditorFix(file: d.file, origin: origin, text: $0.text, help: $0) }
    }

    /// The user picked a fix: it edits the buffer (not the file) and the editor shows the place.
    private func apply(_ fix: EditorFix) {
        do {
            try model.editor.apply(fix)
            model.editor.lastError = nil
            if let e = fix.help.edits.first {
                model.show(source: SourceTarget(file: fix.file, origin: fix.origin,
                                                primary: .init(line: e.line, col: e.col, endLine: nil, endCol: nil)))
            }
        } catch {
            model.editor.lastError = error.localizedDescription
            model.editorVisible = true
        }
    }

    private func open(_ row: ProblemRow) {
        guard let file = row.file, let line = row.line, let col = row.col else { return }
        let origin = model.selection?.origin ?? .own
        let sameFile = row.labels.filter { $0.file == file }.map {
            SourceTarget.Span(line: $0.line, col: $0.col, endLine: $0.end.line, endCol: $0.end.col)
        }
        model.show(source: SourceTarget(
            file: file, origin: origin,
            primary: .init(line: line, col: col, endLine: row.endLine, endCol: row.endCol), secondary: sameFile))
    }

    struct RowView: View {
        let row: ProblemRow
        var fixes: [EditorFix] = []
        var apply: (EditorFix) -> Void = { _ in }
        var open: () -> Void = {}

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon).foregroundStyle(color)
                    Text(row.message).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if !row.code.isEmpty { Text(row.code).font(.caption.monospaced()) }
                    if let l = row.location { Text(l).font(.caption.monospaced()) }
                }
                .foregroundStyle(.secondary)
                if let label = row.label { Text(label).font(.callout).foregroundStyle(.secondary) }
                if let hint = row.hint { Label(hint, systemImage: "lightbulb").font(.callout) }
                ForEach(row.labels.indices, id: \.self) { i in
                    let l = row.labels[i]
                    Text("\(l.file):\(l.line):\(l.col)  \(l.text)").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(row.notes, id: \.self) { Text("Note: \($0)").font(.callout).foregroundStyle(.secondary) }
                ForEach(row.helps.filter { h in !fixes.contains { $0.text == h } }, id: \.self) {
                    Label($0, systemImage: "wand.and.stars").font(.callout)
                }
                ForEach(fixes) { fix in
                    HStack {
                        Label(fix.text, systemImage: "wand.and.stars").font(.callout)
                        Spacer()
                        Button("Apply Fix") { apply(fix) }.controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { open() }
        }
        var icon: String {
            switch row.severity {
            case .error: return "xmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .note: return "info.circle.fill"
            }
        }
        var color: Color {
            switch row.severity {
            case .error: return .red
            case .warning: return .orange
            case .note: return .blue
            }
        }
    }
}
