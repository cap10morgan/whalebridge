import Testing

@testable import Whalebridge

/// `bestPatchTag` picks the newest available apple/container patch release
/// within a required major.minor, so installs land on the latest patch
/// instead of the exact version baked in at build time.
@Suite struct BestPatchTagTests {
    @Test func picksHighestPatchWithinMajorMinor() {
        let tags = ["1.2.0", "1.2.1", "1.2.3", "1.2.2"]
        #expect(DaemonManager.bestPatchTag(from: tags, majorMinor: "1.2") == "1.2.3")
    }

    @Test func ignoresOtherMajorMinorVersions() {
        let tags = ["1.1.5", "1.2.0", "1.3.0", "2.0.0"]
        #expect(DaemonManager.bestPatchTag(from: tags, majorMinor: "1.2") == "1.2.0")
    }

    @Test func excludesPreReleaseSuffixes() {
        // "1.2.4-rc1" fails the Int(...) parse on the patch component and is
        // correctly excluded — only exact major.minor.patch tags count.
        let tags = ["1.2.0", "1.2.4-rc1", "1.2.3"]
        #expect(DaemonManager.bestPatchTag(from: tags, majorMinor: "1.2") == "1.2.3")
    }

    @Test func noMatchingTagsReturnsNil() {
        let tags = ["1.1.0", "1.3.0"]
        #expect(DaemonManager.bestPatchTag(from: tags, majorMinor: "1.2") == nil)
    }

    @Test func emptyTagListReturnsNil() {
        #expect(DaemonManager.bestPatchTag(from: [], majorMinor: "1.2") == nil)
    }

    @Test func singleDigitAndDoubleDigitPatchesCompareNumerically() {
        // String comparison would wrongly rank "1.2.9" above "1.2.10" —
        // confirms the comparison is numeric.
        let tags = ["1.2.9", "1.2.10"]
        #expect(DaemonManager.bestPatchTag(from: tags, majorMinor: "1.2") == "1.2.10")
    }
}
