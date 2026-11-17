import Foundation

/// Whether Time Machine backs up the parts of Apple's container storage that
/// can be recreated: container filesystems and unpacked image snapshots.
///
/// apple/container 1.7 excludes these directories itself, but only when it
/// creates them (apple/container#2412), so an install that predates 1.7 keeps
/// backing them up. This sets the same sticky exclusion attribute Apple does,
/// and the runtime leaves an existing directory's setting alone. So the
/// directories themselves are the source of truth, and no preference is stored.
enum BackupExclusion {
    enum State: Equatable {
        /// Every directory that exists is excluded.
        case excluded
        /// At least one directory that exists is still backed up.
        case included
        /// The runtime hasn't created any of the directories yet.
        case unavailable
    }

    /// The directories apple/container excludes, under its app root. Image
    /// content and volumes stay in backups: a built image's blobs exist only
    /// in `content`, and volumes hold the data containers keep.
    static let directoryNames = ["containers", "snapshots"]

    static func directories(appRoot: URL) -> [URL] {
        directoryNames.map { appRoot.appending(path: $0, directoryHint: .isDirectory) }
    }

    static func state(of directories: [URL]) -> State {
        let existing = directories.filter(isDirectory)
        guard !existing.isEmpty else { return .unavailable }
        return existing.allSatisfy(isExcluded) ? .excluded : .included
    }

    /// Sets the exclusion on each of `directories` that exists. A missing one
    /// is skipped rather than created, since the runtime owns them; a 1.7
    /// runtime excludes it when it creates it.
    static func setExcluded(_ excluded: Bool, directories: [URL]) throws {
        for directory in directories where isDirectory(directory) {
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = excluded
            try url.setResourceValues(values)
        }
    }

    static func isExcluded(_ directory: URL) -> Bool {
        var url = directory
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
