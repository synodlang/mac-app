import Foundation

/// The failure codes of the editor tools. A failed call returns `isError: true` with a text starting with the raw value.
public enum EditorErrorCode: String, Sendable, CaseIterable {
    case notFound = "not-found"
    case outsideModule = "outside-module"
    case readOnly = "read-only"
    case versionMismatch = "version-mismatch"
    case badRange = "bad-range"
    case exists = "exists"
    case tooLarge = "too-large"
    case busy = "busy"
    case badArguments = "bad-arguments"
}

/// An error an `EditorService` throws; the tool result text is `"<code>: <message>"`.
public struct EditorToolError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: EditorErrorCode
    public let message: String

    public init(_ code: EditorErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message.isEmpty ? code.rawValue : "\(code.rawValue): \(message)" }
}

public struct EditorFileInfo: Sendable, Equatable {
    public var path: String
    public var open: Bool
    public var dirty: Bool
    public var readOnly: Bool
    public var version: Int
    public init(path: String, open: Bool, dirty: Bool, readOnly: Bool, version: Int) {
        self.path = path
        self.open = open
        self.dirty = dirty
        self.readOnly = readOnly
        self.version = version
    }
}

public struct EditorBufferSlice: Sendable, Equatable {
    public var path: String
    public var version: Int
    public var dirty: Bool
    public var readOnly: Bool
    public var lineCount: Int
    public var startLine: Int
    public var endLine: Int
    public var text: String
    public init(path: String, version: Int, dirty: Bool, readOnly: Bool, lineCount: Int, startLine: Int, endLine: Int, text: String) {
        self.path = path
        self.version = version
        self.dirty = dirty
        self.readOnly = readOnly
        self.lineCount = lineCount
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
    }
}

public struct EditorDiagnostic: Sendable, Equatable {
    public var path: String
    public var line: Int
    public var col: Int
    public var endLine: Int
    public var endCol: Int
    public var severity: String
    public var code: String
    public var message: String
    public var hint: String?
    public init(path: String, line: Int, col: Int, endLine: Int, endCol: Int, severity: String, code: String, message: String, hint: String?) {
        self.path = path
        self.line = line
        self.col = col
        self.endLine = endLine
        self.endCol = endCol
        self.severity = severity
        self.code = code
        self.message = message
        self.hint = hint
    }
}

public struct EditorDiagnosticsResult: Sendable, Equatable {
    public var stale: Bool
    public var diagnostics: [EditorDiagnostic]
    public init(stale: Bool, diagnostics: [EditorDiagnostic]) {
        self.stale = stale
        self.diagnostics = diagnostics
    }
}

public struct EditorPosition: Sendable, Equatable {
    public var line: Int
    public var col: Int
    public init(line: Int, col: Int) {
        self.line = line
        self.col = col
    }
}

public struct EditorSelectionRange: Sendable, Equatable {
    public var line: Int
    public var col: Int
    public var endLine: Int
    public var endCol: Int
    public var text: String
    public init(line: Int, col: Int, endLine: Int, endCol: Int, text: String) {
        self.line = line
        self.col = col
        self.endLine = endLine
        self.endCol = endCol
        self.text = text
    }
}

public struct EditorSelectionInfo: Sendable, Equatable {
    public var path: String?
    public var version: Int?
    public var caret: EditorPosition?
    public var selections: [EditorSelectionRange]
    public init(path: String?, version: Int?, caret: EditorPosition?, selections: [EditorSelectionRange]) {
        self.path = path
        self.version = version
        self.caret = caret
        self.selections = selections
    }
}

/// One edit: 1-based line and code-point column, the end is exclusive.
public struct EditorTextEdit: Sendable, Equatable {
    public var line: Int
    public var col: Int
    public var endLine: Int
    public var endCol: Int
    public var text: String
    public init(line: Int, col: Int, endLine: Int, endCol: Int, text: String) {
        self.line = line
        self.col = col
        self.endLine = endLine
        self.endCol = endCol
        self.text = text
    }
}

public struct EditorEditResult: Sendable, Equatable {
    public var path: String
    public var version: Int
    public var dirty: Bool
    public init(path: String, version: Int, dirty: Bool = true) {
        self.path = path
        self.version = version
        self.dirty = dirty
    }
}

public struct EditorCreateResult: Sendable, Equatable {
    public var path: String
    public var version: Int
    public var formatted: Bool
    public init(path: String, version: Int, formatted: Bool) {
        self.path = path
        self.version = version
        self.formatted = formatted
    }
}

public struct EditorSavedFile: Sendable, Equatable {
    public var path: String
    public var version: Int
    public var formatted: Bool
    public init(path: String, version: Int, formatted: Bool) {
        self.path = path
        self.version = version
        self.formatted = formatted
    }
}

public struct EditorSaveFailure: Sendable, Equatable {
    public var path: String
    public var message: String
    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public struct EditorSaveResult: Sendable, Equatable {
    public var saved: [EditorSavedFile]
    public var failed: [EditorSaveFailure]
    public init(saved: [EditorSavedFile], failed: [EditorSaveFailure]) {
        self.saved = saved
        self.failed = failed
    }
}

/// What the editor offers to Claude. The app implements it over `EditorModel`; the tool registry validates the
/// arguments against the published schemas, so an implementation sees well-formed values (types, minimums, array
/// sizes) and only checks meaning (paths, versions, ranges). Throw `EditorToolError` for every expected failure.
///
/// Calls may arrive from any task, one connection at a time or concurrently; hop to the main actor inside. A call
/// that waits (`diagnostics(fresh: true)`) should honour task cancellation (`Task.checkCancellation()`), which the
/// server triggers on `notifications/cancelled` and when the connection closes.
public protocol EditorService: Sendable {
    /// Module files with their editor state, in byte order of path.
    func listFiles() async throws -> [EditorFileInfo]
    /// The inclusive, clamped line range (all lines when both bounds are nil).
    func readBuffer(path: String, startLine: Int?, endLine: Int?) async throws -> EditorBufferSlice
    /// With `fresh`, run the overlay check and wait up to 5 s; on timeout return the last result with `stale: true`.
    func diagnostics(path: String?, fresh: Bool) async throws -> EditorDiagnosticsResult
    func selection() async throws -> EditorSelectionInfo
    /// One undo group named "Claude Edit"; `version` must equal the buffer's version.
    func applyEdits(path: String, version: Int, edits: [EditorTextEdit]) async throws -> EditorEditResult
    func replaceBuffer(path: String, version: Int, text: String) async throws -> EditorEditResult
    func createFile(path: String, text: String) async throws -> EditorCreateResult
    func saveFiles(paths: [String]) async throws -> EditorSaveResult
    /// Shows the file; returns the module-relative path.
    func openFile(path: String, line: Int?, col: Int?) async throws -> String
}
