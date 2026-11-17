import Foundation
import Testing

@testable import Whalebridge

/// `BackupExclusion` reads and sets Time Machine's sticky exclusion on Apple's
/// recreatable container storage, so these run against real directories.
@Suite struct BackupExclusionTests {
    let appRoot: URL

    init() throws {
        appRoot = FileManager.default.temporaryDirectory
            .appending(path: "BackupExclusionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true)
    }

    private func makeDirectories(_ names: [String]) throws {
        for name in names {
            try FileManager.default.createDirectory(
                at: appRoot.appending(path: name), withIntermediateDirectories: true)
        }
    }

    @Test func coversContainersAndSnapshotsOnly() {
        #expect(
            BackupExclusion.directories(appRoot: appRoot).map(\.lastPathComponent) == ["containers", "snapshots"])
    }

    @Test func unavailableBeforeTheRuntimeCreatesItsStorage() {
        #expect(BackupExclusion.state(of: BackupExclusion.directories(appRoot: appRoot)) == .unavailable)
    }

    @Test func newDirectoriesAreIncluded() throws {
        try makeDirectories(["containers", "snapshots"])
        #expect(BackupExclusion.state(of: BackupExclusion.directories(appRoot: appRoot)) == .included)
    }

    @Test func excludingAndIncludingRoundTrips() throws {
        try makeDirectories(["containers", "snapshots"])
        let directories = BackupExclusion.directories(appRoot: appRoot)

        try BackupExclusion.setExcluded(true, directories: directories)
        #expect(BackupExclusion.state(of: directories) == .excluded)
        #expect(directories.allSatisfy(BackupExclusion.isExcluded))

        try BackupExclusion.setExcluded(false, directories: directories)
        #expect(BackupExclusion.state(of: directories) == .included)
        #expect(!directories.contains(where: BackupExclusion.isExcluded))
    }

    @Test func partlyExcludedReadsAsIncluded() throws {
        // e.g. a 1.7 runtime created `snapshots` (excluded) under an older `containers`.
        try makeDirectories(["containers", "snapshots"])
        try BackupExclusion.setExcluded(true, directories: [appRoot.appending(path: "snapshots")])
        #expect(BackupExclusion.state(of: BackupExclusion.directories(appRoot: appRoot)) == .included)
    }

    @Test func missingDirectoriesAreSkippedNotCreated() throws {
        try makeDirectories(["snapshots"])
        let directories = BackupExclusion.directories(appRoot: appRoot)

        try BackupExclusion.setExcluded(true, directories: directories)
        #expect(!FileManager.default.fileExists(atPath: appRoot.appending(path: "containers").path))
        #expect(BackupExclusion.state(of: directories) == .excluded)
    }

    @Test func leavesOtherStorageAlone() throws {
        try makeDirectories(["containers", "snapshots", "content", "volumes"])
        try BackupExclusion.setExcluded(true, directories: BackupExclusion.directories(appRoot: appRoot))
        #expect(!BackupExclusion.isExcluded(appRoot.appending(path: "content")))
        #expect(!BackupExclusion.isExcluded(appRoot.appending(path: "volumes")))
    }
}
