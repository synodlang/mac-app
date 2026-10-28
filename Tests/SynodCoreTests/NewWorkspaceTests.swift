import Foundation
import Testing

@testable import SynodCore

/// A stand-in for `synod new`: writes `synod.mod`, `<last word>/demo.synod` (or a library file) and records its arguments.
private func makeFakeNew(in dir: URL, exitCode: Int32 = 0, stderr: String = "") throws -> SynodRunner {
    let script = dir.appendingPathComponent("fake-new.sh")
    let body = """
    #!/bin/sh
    echo "$*" >> "\(dir.path)/args.txt"
    if [ \(exitCode) -ne 0 ]; then echo "\(stderr)" >&2; exit \(exitCode); fi
    target="$2"; module="$4"; pkg="${module##*/}"
    mkdir -p "$target/$pkg"
    printf 'module %s\\nsynod 0.2\\n' "$module" > "$target/synod.mod"
    if [ "$5" = "--lib" ]; then
      printf '# package %s\\n' "$pkg" > "$target/$pkg/$pkg.synod"
    else
      printf '# package main\\n' > "$target/$pkg/demo.synod"
      printf '# package %s\\n' "$pkg" > "$target/$pkg/$pkg.synod"
    fi
    """
    try body.write(to: script, atomically: true, encoding: .utf8)
    return SynodRunner(executable: URL(fileURLWithPath: "/bin/sh"), prefixArgs: [script.path])
}

@Test func defaultModuleIsALowerCaseWord() {
    #expect(NewWorkspace.defaultModule(forFolder: "my-system") == "example.com/mysystem")
    #expect(NewWorkspace.defaultModule(forFolder: "Raft Demo 2") == "example.com/raftdemo")
    #expect(NewWorkspace.defaultModule(forFolder: "123") == "example.com/app")
    #expect(NewWorkspace.defaultModule(forFolder: "") == "example.com/app")
}

@Test func newArgumentsAreAnArrayWithTheModule() {
    let dir = URL(fileURLWithPath: "/tmp/with space/my-system")
    #expect(NewWorkspace.arguments(for: .init(directory: dir)) == ["new", "/tmp/with space/my-system", "--module", "example.com/mysystem"])
    #expect(NewWorkspace.arguments(for: .init(directory: dir, module: "  a.b/c  ")) == ["new", "/tmp/with space/my-system", "--module", "a.b/c"])
    #expect(NewWorkspace.arguments(for: .init(directory: dir, module: "", isLibrary: true)).suffix(2) == ["example.com/mysystem", "--lib"])
}

@Test func failureMessageDropsThePrefix() {
    func result(_ err: String, _ out: String = "") -> ProcessResult {
        ProcessResult(exitCode: 2, stdout: Data(out.utf8), stderr: Data(err.utf8))
    }
    #expect(NewWorkspace.message(from: result("synod new: demo is not empty\n")) == "demo is not empty")
    #expect(NewWorkspace.message(from: result("", "odd")) == "odd")
    #expect(NewWorkspace.message(from: result("")) == "synod new failed with exit status 2")
}

@Test func creatingARefusesAFolderWithFilesWithoutRunningSynod() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = try makeFakeNew(in: dir)
    let busy = dir.appendingPathComponent("busy")
    try FileManager.default.createDirectory(at: busy, withIntermediateDirectories: true)
    try "x".write(to: busy.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
    await #expect(throws: NewWorkspace.Failure.notEmpty(busy.path)) {
        _ = try await NewWorkspace.create(.init(directory: busy), runner: runner)
    }
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("args.txt").path))
}

@Test func synodFailureCarriesItsMessage() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = try makeFakeNew(in: dir, exitCode: 2, stderr: "synod new: 2app is not a package name; use a lower-case word")
    await #expect(throws: NewWorkspace.Failure.synod("2app is not a package name; use a lower-case word")) {
        _ = try await NewWorkspace.create(.init(directory: dir.appendingPathComponent("w"), module: "example.com/2app"), runner: runner)
    }
}

@Test func creatingAProgramWorkspaceOpensTheDemo() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = try makeFakeNew(in: dir)
    // Missing parent folders are made; an existing empty folder is fine.
    let target = dir.appendingPathComponent("deep/er/My Sys")
    let made = try await NewWorkspace.create(.init(directory: target), runner: runner)
    #expect(made.root.path == FileWatcher.realPath(target.path))
    #expect(made.program == "mysys")
    #expect(made.package == nil)
    #expect(made.file == "mysys/demo.synod")
    let args = try String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8)
    #expect(args.contains("new \(target.path) --module example.com/mysys"))

    let empty = dir.appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let again = try await NewWorkspace.create(.init(directory: empty, module: "a.b/c"), runner: runner)
    #expect(again.file == "c/demo.synod")
}

@Test func creatingALibraryOpensItsPackage() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = try makeFakeNew(in: dir)
    let made = try await NewWorkspace.create(.init(directory: dir.appendingPathComponent("kit"), isLibrary: true), runner: runner)
    #expect(made.program == nil)
    #expect(made.package == "kit")
    #expect(made.file == "kit/kit.synod")
}

@Test func createdPrefersTheDemoProgramThenAPackage() {
    let root = URL(fileURLWithPath: "/w")
    let scan = Workspace.Scan(programs: [.init(relPath: "a", mainFile: "main.synod"), .init(relPath: "b", mainFile: "demo.synod")], packages: [])
    #expect(NewWorkspace.created(root: root, scan: scan).file == "b/demo.synod")
    #expect(NewWorkspace.created(root: root, scan: .init(programs: [], packages: [])).file == nil)
}
