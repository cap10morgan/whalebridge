import CryptoKit
import Foundation

/// Manages the "whalebridge" Docker context: the meta.json Docker stores under
/// ~/.docker/contexts, and the currentContext key in ~/.docker/config.json.
/// Context storage format mirrors socktainer's DockerContextSetup (Apache-2.0).
enum DockerContext {
    static let name = "whalebridge"

    private static var dockerDir: String { NSHomeDirectory() + "/.docker" }
    private static var configFile: URL { URL(fileURLWithPath: dockerDir + "/config.json") }

    /// Docker names each context's storage directory sha256(context name).
    private static var contextDirName: String {
        SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Create or update the context. The tls directory must exist (empty) for
    /// the Docker CLI to accept the context.
    static func ensureContext(socketPath: String) throws {
        let metaDir = "\(dockerDir)/contexts/meta/\(contextDirName)"
        let tlsDir = "\(dockerDir)/contexts/tls/\(contextDirName)/docker"
        let payload: [String: Any] = [
            "Name": name,
            "Metadata": ["Description": "Whalebridge — Docker API over Apple containers"],
            "Endpoints": [
                "docker": [
                    "Host": "unix://\(socketPath)",
                    "SkipTLSVerify": false,
                ]
            ],
        ]
        let fm = FileManager.default
        try fm.createDirectory(atPath: metaDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: tlsDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: metaDir + "/meta.json"))
    }

    static func currentContext() -> String? {
        guard let data = try? Data(contentsOf: configFile),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["currentContext"] as? String
    }

    static var isDefault: Bool { currentContext() == name }

    /// Point currentContext at whalebridge; returns the previous value so it
    /// can be restored when the setting is turned off.
    static func makeDefault() throws -> String? {
        try updateConfig { config in
            let previous = config["currentContext"] as? String
            config["currentContext"] = name
            return previous
        }
    }

    /// Undo makeDefault, restoring `previous` (nil unsets, which Docker treats
    /// as the built-in "default" context). No-op if the user already switched
    /// to some other context themselves.
    static func resignDefault(restoring previous: String?) throws {
        _ = try updateConfig { config in
            guard config["currentContext"] as? String == name else { return nil }
            if let previous, previous != name {
                config["currentContext"] = previous
            } else {
                config.removeValue(forKey: "currentContext")
            }
            return nil
        }
    }

    /// Read-modify-write config.json, preserving unrelated keys (auths, credsStore…).
    private static func updateConfig(_ mutate: (inout [String: Any]) -> String?) throws -> String? {
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: configFile),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            config = json
        }
        let result = mutate(&config)
        try FileManager.default.createDirectory(atPath: dockerDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configFile)
        return result
    }
}
