import Foundation
import Observation
import SynodCore

/// The prompt bar of one window (decision 96): one `claude` request at a time, run in the module
/// root, changing the workspace only through the editor MCP server (decisions 98 to 100). It owns the
/// request's lifetime: listener hold, per-request token, 0600 config file, snapshot, read-only
/// buffers, progress, the banner and Revert.
@MainActor @Observable
final class ClaudeModel {
    /// What a request needs from the app; the workspace model fills it from Settings.
    struct Config {
        var claude: URL
        var model: String?
        var skills: URL
        var synod: URL
        var bridge: URL
        var host: [String: String] = ProcessInfo.processInfo.environment
        var timeout: Duration = .seconds(1800)
        var stopTiming = ClaudeProcess.StopTiming()
    }

    enum SendResult: Equatable {
        case started
        /// Dirty buffers must be saved first; the files are listed for the "Save All and Send" sheet.
        case needsSave([String])
        case refused(String)
    }

    internal(set) var isRunning = false
    /// Progress lines of the current or last request ("Read twopc/twopc.synod", "Ran synod check .").
    private(set) var progress: [String] = []
    private(set) var finalText: String?
    private(set) var errorText: String?
    private(set) var sessionID: String?
    /// Files the last request changed (on disk or in an unsaved buffer): the banner's count.
    private(set) var changed: [String] = []
    private(set) var canRevert = false
    /// Edits Claude left unsaved: the banner offers Save All.
    private(set) var unsavedLeft = false
    private(set) var lastExitStatus: Int32?
    /// The request waiting for "Save All and Send", and its files.
    var pendingRequest: String?
    private(set) var pendingFiles: [String] = []
    var draft = ""
    /// Counts ⌘K presses; the bar focuses its field on each.
    private(set) var focusSerial = 0

    @ObservationIgnored weak var host: WorkspaceModel?
    @ObservationIgnored var config: () -> Config? = { nil }
    /// False while Settings has the prompt bar off: nothing is ever launched then.
    @ObservationIgnored var isEnabled: () -> Bool = { true }
    @ObservationIgnored var hub: EditorMCPHub = .shared
    @ObservationIgnored private var process: ClaudeProcess?
    @ObservationIgnored private var snapshot: WorkspaceSnapshot?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var assistantText: String?
    @ObservationIgnored private var resultSeen = false

    var hasBanner: Bool { !changed.isEmpty || unsavedLeft }

    func focus() { focusSerial += 1 }

    // MARK: Sending

    /// Starts a request. With dirty buffers and no `saveAll` it returns `.needsSave` and keeps the text
    /// for the sheet; `confirmPending()` then saves every buffer and sends it.
    @discardableResult
    func send(_ text: String, saveAll: Bool = false) async -> SendResult {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return .refused("Type a request first.") }
        guard !isRunning else { return .refused("A request is already running.") }
        guard isEnabled() else { return .refused("The prompt bar is off. Turn it on in Settings > Claude.") }
        guard let host else { return .refused("No workspace.") }
        guard !host.isReadOnly else { return .refused("The prompt bar is off on the bundled examples. Copy them to a folder first.") }
        guard let cfg = config() else {
            let why = host.env.promptBarProblem ?? "The prompt bar is not set up."
            errorText = why
            return .refused(why)
        }
        let dirty = host.editor.dirtyDocuments
        if !dirty.isEmpty {
            if !saveAll {
                pendingRequest = request
                pendingFiles = dirty.map(\.file)
                return .needsSave(pendingFiles)
            }
            for d in dirty {
                do { try await host.editor.save(file: d.file, origin: d.origin) } catch {
                    let why = "Could not save \(d.file): \(error.localizedDescription)"
                    errorText = why
                    return .refused(why)
                }
            }
        }
        pendingRequest = nil
        pendingFiles = []
        return await start(request, cfg)
    }

    /// The "Save All and Send" sheet's button.
    func confirmPending() async {
        guard let request = pendingRequest else { return }
        let r = await send(request, saveAll: true)
        if case .refused(let why) = r { errorText = why }
    }

    func cancelPending() {
        pendingRequest = nil
        pendingFiles = []
    }

    private func start(_ request: String, _ cfg: Config) async -> SendResult {
        guard let host else { return .refused("No workspace.") }
        let root = host.workspace.root
        guard let skill = ClaudeInvocation.loadSkill(from: cfg.skills) else {
            errorText = "The agent skill (SKILL.md) was not found in \(cfg.skills.path)."
            return .refused(errorText!)
        }
        isRunning = true
        progress = []
        finalText = nil
        errorText = nil
        changed = []
        unsavedLeft = false
        resultSeen = false
        assistantText = nil
        lastExitStatus = nil
        draft = ""
        host.editor.userLocked = true

        let snap = await Task.detached { WorkspaceSnapshot.take(root: root) }.value
        snapshot = snap
        canRevert = snap.canRevert

        let session: EditorMCPHub.Session
        do {
            session = try await hub.beginRequest(for: host, synod: cfg.synod, bridge: cfg.bridge)
        } catch {
            errorText = "Could not start the editor connection: \(error.localizedDescription)"
            host.editor.userLocked = false
            isRunning = false
            return .refused(errorText!)
        }
        let invocation = ClaudeInvocation(
            claude: cfg.claude, request: request, workingDirectory: root, mcpConfig: session.config.url, skillsFolder: cfg.skills,
            skillMarkdown: skill, synod: cfg.synod, model: cfg.model, sessionID: sessionID, hostEnvironment: cfg.host)
        let proc = ClaudeProcess(invocation, timeout: cfg.timeout, stopTiming: cfg.stopTiming)
        process = proc
        task = Task { [weak self] in await self?.run(proc, session: session, root: root) }
        return .started
    }

    private func run(_ proc: ClaudeProcess, session: EditorMCPHub.Session, root: URL) async {
        let parser = ClaudeStreamParser(moduleRoot: root)
        let (stream, continuation) = AsyncStream.makeStream(of: [ClaudeEvent].self)
        let consumer = Task { [weak self] in
            for await events in stream { self?.handle(events) }
        }
        var exit: ClaudeProcess.Exit?
        var launchError: String?
        do {
            exit = try await proc.run { line in continuation.yield(parser.parse(line: line)) }
        } catch {
            launchError = error.localizedDescription
        }
        continuation.finish()
        await consumer.value
        await hub.endRequest(session)
        await finish(exit: exit, launchError: launchError)
    }

    private func handle(_ events: [ClaudeEvent]) {
        for e in events {
            switch e {
            case .initialized(let id, _):
                sessionID = id
            case .text(let t):
                assistantText = t
            case .toolUse:
                if let line = e.progressLine { progress.append(line) }
            case .toolResult, .other:
                break
            case .result(let isError, let text, let id, _):
                resultSeen = true
                if sessionID == nil { sessionID = id }
                if isError {
                    errorText = ClaudeStreamParser.isLoginProblem(text) ? ClaudeStreamParser.loginMessage : text
                } else {
                    finalText = text
                }
            }
        }
    }

    private func finish(exit: ClaudeProcess.Exit?, launchError: String?) async {
        process = nil
        isRunning = false
        host?.editor.userLocked = false
        lastExitStatus = exit?.status
        if let launchError {
            errorText = "Could not start claude: \(launchError)"
        } else if let exit {
            if exit.stopped {
                progress.append("Stopped")
            } else if exit.timedOut {
                errorText = "Claude took longer than 30 minutes and was stopped."
            } else if !resultSeen && exit.status != 0 {
                let last = exit.stderr.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                if ClaudeStreamParser.isLoginProblem(last) {
                    errorText = ClaudeStreamParser.loginMessage
                } else {
                    errorText = last.isEmpty ? "claude exited with status \(exit.status)." : last
                }
            }
        }
        if finalText == nil, errorText == nil { finalText = assistantText }
        await refreshChanges()
    }

    // MARK: Changes

    /// Works out what the request changed and shows it: changed files reload into clean buffers, the
    /// program list refreshes, the newest changed main file's program is selected and run (unless
    /// buffers are still unsaved).
    func refreshChanges() async {
        guard let host, let snapshot else { return }
        let snap = snapshot
        let diff = await Task.detached { snap.diff() }.value
        host.editor.diskChanged()
        host.rescan()
        let unsaved = host.editor.dirtyDocuments.map(\.file)
        unsavedLeft = !unsaved.isEmpty
        changed = Array(Set(diff.added + diff.modified + diff.deleted + unsaved)).sorted()
        canRevert = snap.canRevert
        guard !changed.isEmpty else { return }
        showNewestProgram(candidates: Set(diff.added + diff.modified + unsaved), runIt: unsaved.isEmpty)
    }

    private func showNewestProgram(candidates: Set<String>, runIt: Bool) {
        guard let host else { return }
        let fm = FileManager.default
        var best: (Workspace.Program, Date)?
        for p in host.workspace.scan().programs {
            let main = p.relPath == "." ? p.mainFile : p.relPath + "/" + p.mainFile
            guard candidates.contains(main) else { continue }
            let date = host.editor.documents[EditorModel.key(main, .own)]?.isDirty == true
                ? Date()
                : ((try? fm.attributesOfItem(atPath: host.workspace.url(forRelative: main).path))?[.modificationDate] as? Date) ?? .distantPast
            if best == nil || date > best!.1 { best = (p, date) }
        }
        if let (program, _) = best {
            host.select(.init(origin: .own, kind: .program, relPath: program.relPath), run: runIt)
        } else if let file = candidates.filter({ $0.hasSuffix(".synod") }).sorted().first {
            host.show(source: SourceTarget(file: file, origin: .own))
        }
    }

    func showChange(_ file: String) {
        guard let host else { return }
        host.show(source: SourceTarget(file: file, origin: .own))
    }

    /// The banner's "Save All": writes every unsaved buffer (formatted) like the user's Save.
    func saveAll() async {
        guard let host else { return }
        for d in host.editor.dirtyDocuments {
            do { try await host.editor.save(file: d.file, origin: d.origin) } catch {
                errorText = "Could not save \(d.file): \(error.localizedDescription)"
                return
            }
        }
        unsavedLeft = false
    }

    /// Restores the snapshot bytes, deletes added files and drops unsaved Claude edits. Only the user's
    /// click calls this.
    func revert() {
        guard let host, let snapshot else { return }
        do {
            try snapshot.revert()
        } catch {
            errorText = error.localizedDescription
            return
        }
        host.editor.discardEditsAndReload()
        host.rescan()
        changed = []
        unsavedLeft = false
        canRevert = false
        progress.append("Reverted")
        if host.activeProgram == nil { host.selection = nil }
        host.run(.manual)
    }

    // MARK: Controls

    func stop() {
        guard let process else { return }
        Task { await process.stop() }
    }

    /// Clears the conversation: the next request starts a new session.
    func newConversation() {
        guard !isRunning else { return }
        sessionID = nil
        progress = []
        finalText = nil
        errorText = nil
        changed = []
        unsavedLeft = false
        snapshot = nil
        canRevert = false
    }

    /// The preset "Explain this run".
    @discardableResult
    func explainRun() async -> SendResult {
        guard let host, let p = host.activeProgram, host.loaded != nil else { return .refused("Run a program first.") }
        let main = p.relPath == "." ? p.mainFile : p.relPath + "/" + p.mainFile
        return await send(ClaudeInvocation.explainRunPrompt(program: p.relPath, mainFile: main))
    }

    /// The window closes: stop the process and let the task clean up.
    func shutdown() {
        guard isRunning else { return }
        stop()
    }

    /// Waits for the running request to finish and clean up (headless runs).
    func waitUntilIdle(timeout: Double = 60) async -> Bool {
        let end = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while isRunning, ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(20)) }
        return !isRunning
    }
}
