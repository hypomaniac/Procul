import Foundation
import Testing
@testable import Procul

@Suite("Version numbers")
struct VersionTests {
    @Test func laterNumbersAreNewer() {
        #expect(Version.isNewer("1.1", than: "1.0"))
        #expect(Version.isNewer("v2.0", than: "1.9.9"))
        #expect(Version.isNewer("1.10", than: "1.9"))
        #expect(Version.isNewer("1.0.1", than: "1.0"))
    }

    @Test func sameOrOlderIsNotNewer() {
        #expect(!Version.isNewer("1.0", than: "1.0"))
        #expect(!Version.isNewer("v1.0.0", than: "1.0"))
        #expect(!Version.isNewer("0.9", than: "1.0"))
        #expect(!Version.isNewer("1.9", than: "1.10"))
    }
}

@MainActor
@Suite("Update checker")
struct UpdateCheckerTests {
    private func answer(_ tag: String, page: String? = nil, extra: String = "") -> Data {
        let page = page ?? "\(UpdateChecker.releasesPage)/tag/\(tag)"
        return Data(#"{"tag_name":"\#(tag)","html_url":"\#(page)"\#(extra)}"#.utf8)
    }

    private func checker(current: String, prefs: Preferences? = nil, _ data: Data?) -> UpdateChecker {
        UpdateChecker(prefs: prefs ?? Preferences(defaults: MemorySettings()), current: current) {
            guard let data else { throw URLError(.notConnectedToInternet) }
            return data
        }
    }

    @Test func aNewerReleaseIsReported() async {
        let updates = checker(current: "1.0", answer("v1.2"))
        await updates.check()
        #expect(updates.available?.version == "1.2")
        #expect(updates.available?.page.absoluteString == "\(UpdateChecker.releasesPage)/tag/v1.2")
    }

    @Test func theSameVersionIsNot() async {
        let updates = checker(current: "1.2", answer("v1.2"))
        await updates.check()
        #expect(updates.available == nil)
    }

    @Test func noNetworkSaysNothing() async {
        let updates = checker(current: "1.0", nil)
        await updates.check()
        #expect(updates.available == nil)
    }

    @Test func aLinkToSomewhereElseIsRefused() async {
        let updates = checker(current: "1.0", answer("v9.0", page: "https://example.com/hypomaniac/Procul/releases/tag/v9.0"))
        await updates.check()
        #expect(updates.available == nil)
    }

    @Test func draftsAndPrereleasesAreIgnored() {
        #expect(UpdateChecker.parse(answer("v9.0", extra: #","prerelease":true"#)) == nil)
        #expect(UpdateChecker.parse(answer("v9.0", extra: #","draft":true"#)) == nil)
        #expect(UpdateChecker.parse(Data("not json".utf8)) == nil)
    }

    @Test func theSwitchTurnsItOffAndClearsTheNotice() async {
        let prefs = Preferences(defaults: MemorySettings())
        #expect(prefs.checksForUpdates)
        let updates = checker(current: "1.0", prefs: prefs, answer("v1.2"))
        await updates.check()
        #expect(updates.available != nil)

        updates.setEnabled(false)
        #expect(updates.available == nil)
        await updates.check()
        #expect(updates.available == nil)
    }
}
