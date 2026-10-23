import Testing
import Foundation
import SynodWeb
@testable import SynodApp

@MainActor @Suite struct LaunchArgumentsTests {
    let dirs: Set<String> = ["/work/mod"]
    func exists(_ p: String) -> Bool? { dirs.contains(p) ? true : nil }

    @Test func picksFirstExistingPath() {
        #expect(LaunchArguments.workspaceURL(in: ["/nope", "/work/mod"], exists: exists)?.path == "/work/mod")
    }
    @Test func skipsOptionsAndDefaultsPairs() {
        #expect(LaunchArguments.workspaceURL(in: ["-NSDocumentRevisionsDebugMode", "/work/mod", "-v"], exists: exists) == nil)
        #expect(LaunchArguments.workspaceURL(in: ["-v", "/work/mod"], exists: exists)?.path == "/work/mod")
    }
    @Test func theWorkspaceFileOptionAndItsValueAreSkipped() {
        let dirs2: Set<String> = ["/work/mod", "/tmp/rec"]
        let ex: (String) -> Bool? = { dirs2.contains($0) ? true : nil }
        #expect(LaunchArguments.workspaceURL(in: ["--workspace-file", "/tmp/rec", "/work/mod"], exists: ex)?.path == "/work/mod")
    }
    @Test func noArguments() {
        #expect(LaunchArguments.workspaceURL(in: [], exists: exists) == nil)
    }
}
