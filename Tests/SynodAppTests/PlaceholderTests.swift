import Testing
@testable import SynodApp

@MainActor @Test func appLinks() {
    #expect(Entry.headlessFlags.contains("--smoke"))
}
