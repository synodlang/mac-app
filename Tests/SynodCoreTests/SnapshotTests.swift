import Foundation
import Testing

@testable import SynodCore

private func put(_ root: URL, _ rel: String, _ content: Data) throws {
    let url = root.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url)
}

private func put(_ root: URL, _ rel: String, _ text: String) throws { try put(root, rel, Data(text.utf8)) }

private func module() throws -> URL {
    let root = try makeTempDir()
    try put(root, "synod.mod", "module example.com/m\nsynod 0.2\n")
    try put(root, "synod.sum", "")
    try put(root, "twopc/twopc.synod", "# package twopc\n")
    try put(root, "twopc/demo.synod", Data([0x23, 0x20, 0xFF, 0x00, 0x0D, 0x0A, 0x80]))
    return root
}

@Test func snapshotCoversOnlySynodFiles() throws {
    let root = try module()
    defer { try? FileManager.default.removeItem(at: root) }
    for skipped in ["vendor/x@v1/x.synod", "out/o.synod", ".hidden/h.synod", "_tmp/t.synod", "twopc/.dot.synod", "twopc/notes.txt", "README.md"] {
        try put(root, skipped, "x")
    }
    let snap = WorkspaceSnapshot.take(root: root)
    #expect(snap.paths == ["synod.mod", "synod.sum", "twopc/demo.synod", "twopc/twopc.synod"])
    #expect(snap.canRevert)
    #expect(snap.diff().isEmpty)
}

@Test func diffAndByteExactRevert() throws {
    let root = try module()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try Data(contentsOf: root.appendingPathComponent("twopc/demo.synod"))
    let snap = WorkspaceSnapshot.take(root: root)
    try put(root, "twopc/demo.synod", "# package main\n")
    try FileManager.default.removeItem(at: root.appendingPathComponent("twopc/twopc.synod"))
    try put(root, "fresh/new/new.synod", "# package new\n")
    try put(root, "twopc/extra.synod", "# package twopc\n")
    try put(root, "vendor/ignored.synod", "x")
    let d = snap.diff()
    #expect(d.added == ["fresh/new/new.synod", "twopc/extra.synod"])
    #expect(d.modified == ["twopc/demo.synod"])
    #expect(d.deleted == ["twopc/twopc.synod"])
    #expect(d.count == 4)
    #expect(d.changedOrAdded == ["fresh/new/new.synod", "twopc/demo.synod", "twopc/extra.synod"])
    try snap.revert()
    #expect(try Data(contentsOf: root.appendingPathComponent("twopc/demo.synod")) == original)
    #expect(try String(contentsOf: root.appendingPathComponent("twopc/twopc.synod"), encoding: .utf8) == "# package twopc\n")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("twopc/extra.synod").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("fresh").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("vendor/ignored.synod").path))
    #expect(snap.diff().isEmpty)
}

@Test func revertRecreatesDeletedFolder() throws {
    let root = try module()
    defer { try? FileManager.default.removeItem(at: root) }
    let snap = WorkspaceSnapshot.take(root: root)
    try FileManager.default.removeItem(at: root.appendingPathComponent("twopc"))
    #expect(snap.diff().deleted.count == 2)
    try snap.revert()
    #expect(snap.diff().isEmpty)
}

@Test func limitsTurnRevertOff() throws {
    let root = try module()
    defer { try? FileManager.default.removeItem(at: root) }
    try put(root, "big.synod", Data(repeating: 0x41, count: WorkspaceSnapshot.maxFileBytes + 1))
    let big = WorkspaceSnapshot.take(root: root)
    #expect(!big.canRevert)
    #expect(throws: WorkspaceSnapshot.RevertError.self) { try big.revert() }
    // the diff still counts changes
    try put(root, "added.synod", "# package a\n")
    #expect(big.diff().added == ["added.synod"])

    try FileManager.default.removeItem(at: root.appendingPathComponent("big.synod"))
    let exactly = WorkspaceSnapshot.take(root: root, maxFileBytes: 10, maxTotalBytes: 1000)
    #expect(!exactly.canRevert)  // demo.synod and twopc.synod are over 10 bytes? one of them is
    let total = WorkspaceSnapshot.take(root: root, maxFileBytes: 1000, maxTotalBytes: 30)
    #expect(!total.canRevert)
    #expect(WorkspaceSnapshot.take(root: root, maxFileBytes: 1000, maxTotalBytes: 1000).canRevert)
    #expect(WorkspaceSnapshot.maxFileBytes == 1_000_000 && WorkspaceSnapshot.maxTotalBytes == 20_000_000)
}
