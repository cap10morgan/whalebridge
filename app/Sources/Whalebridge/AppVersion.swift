import Foundation

/// The version Whalebridge reports about itself — in the About dialog and as
/// the Docker API's platform version.
///
/// Release bundles bake the tag into Info.plist (bundle.sh); a bundle built
/// from a bare git commit bakes that commit's short sha the same way. Unbundled
/// runs (`make dev`) have no Info.plist value and fall back to the short sha
/// the Makefile passes in the environment, then to "dev" as a last resort
/// (bare `swift run` outside make).
enum AppVersion {
    static let current: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? ProcessInfo.processInfo.environment["WHALEBRIDGE_VERSION"]
        ?? "dev"
}
