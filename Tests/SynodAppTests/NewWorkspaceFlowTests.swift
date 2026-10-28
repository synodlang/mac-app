import Testing
import Foundation
import SynodCore
@testable import SynodApp

@MainActor @Suite struct NewWorkspaceFlowTests {
    @Test func theHandOffIsTakenOnce() {
        let env = AppEnvironment.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synod-handoff-\(UUID().uuidString)")
        let made = NewWorkspace.Created(root: root, package: nil, program: "demo", file: "demo/demo.synod")
        env.expectNewWorkspace(made)
        #expect(env.takeNewWorkspace(at: root)?.program == "demo")
        #expect(env.takeNewWorkspace(at: root) == nil)
    }

    @Test func aWorkspaceNobodyMadeHasNoHandOff() {
        #expect(AppEnvironment.shared.takeNewWorkspace(at: URL(fileURLWithPath: "/nowhere/\(UUID().uuidString)")) == nil)
    }
}
