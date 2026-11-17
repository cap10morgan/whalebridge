import Foundation
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

/// `defaultKernelPath` finds where apple/container keeps its default kernel
/// from `container system status` output, since there's no command that
/// reports the kernel itself.
@Suite struct DefaultKernelPathTests {
    @Test func readsAppRootFromStatusOutput() {
        let output = """
            FIELD               VALUE
            status              running
            paths.appRoot       /Users/me/Library/Application Support/com.apple.container/
            paths.installRoot   /usr/local/
            """
        #expect(
            DaemonManager.defaultKernelPath(statusOutput: output, architecture: "arm64")
                == "/Users/me/Library/Application Support/com.apple.container/kernels/default.kernel-arm64")
    }

    @Test func missingAppRootReturnsNil() {
        #expect(DaemonManager.defaultKernelPath(statusOutput: "status  running", architecture: "arm64") == nil)
    }

    @Test func emptyAppRootReturnsNil() {
        #expect(DaemonManager.defaultKernelPath(statusOutput: "paths.appRoot       ", architecture: "arm64") == nil)
    }
}

/// `appRoot` reads where apple/container keeps its data from `container
/// system status`, for the Time Machine setting as well as the kernel check.
@Suite struct AppRootTests {
    @Test func readsAppRootFromStatusOutput() {
        let output = """
            status              running
            paths.appRoot       /Users/me/Library/Application Support/com.apple.container/
            """
        #expect(
            DaemonManager.appRoot(statusOutput: output)?.appending(path: "snapshots").path
                == "/Users/me/Library/Application Support/com.apple.container/snapshots")
    }

    @Test func stoppedApiserverReportsNoAppRoot() {
        #expect(DaemonManager.appRoot(statusOutput: "apiserver is not running and not registered with launchd") == nil)
    }
}

/// After a runtime upgrade, Whalebridge moves the default kernel to the new
/// recommended one only when it's still a kernel an earlier runtime
/// recommended, which it tells from the default-kernel symlink's target.
@Suite struct OutdatedKernelTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "OutdatedKernelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test func readsTheKernelTheDefaultSymlinkPointsTo() throws {
        let kernel = directory.appending(path: "vmlinux-6.18.35-197-debug")
        try Data().write(to: kernel)
        let link = directory.appending(path: "default.kernel-arm64")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: kernel)
        #expect(DaemonManager.kernelName(linkedFrom: link.path) == "vmlinux-6.18.35-197-debug")
    }

    @Test func noSymlinkMeansNoKernelName() throws {
        #expect(DaemonManager.kernelName(linkedFrom: directory.appending(path: "default.kernel-arm64").path) == nil)
        let plainFile = directory.appending(path: "default.kernel-arm64")
        try Data().write(to: plainFile)
        #expect(DaemonManager.kernelName(linkedFrom: plainFile.path) == nil)
    }

    @Test func earlierRecommendedKernelsExcludeTheCurrentOne() {
        // 1.6's recommendation is outdated under 1.7; 1.7's own isn't.
        #expect(DaemonManager.earlierRecommendedKernels.contains("vmlinux-6.18.35-197-debug"))
        #expect(!DaemonManager.earlierRecommendedKernels.contains("vmlinux-6.18.56-208-debug"))
    }
}
