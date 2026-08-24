import Foundation

// MARK: - Command registry manifest schema

public struct CommandManifestEntry: Codable, Equatable, Sendable {
    public let name: String
    public let kind: String // "native" | "wasm" | "node" | "linux"
    public let entry: String // symbol name or script path
    public let framework: String? // e.g. "TermXPython", "TermXNode"

    public init(name: String, kind: String, entry: String, framework: String? = nil) {
        self.name = name
        self.kind = kind
        self.entry = entry
        self.framework = framework
    }
}

public struct CommandManifest: Codable, Equatable, Sendable {
    public let commands: [CommandManifestEntry]

    public init(commands: [CommandManifestEntry]) {
        self.commands = commands
    }
}

// MARK: - Manifest Loader

public enum ManifestLoader {

    /// Load a command manifest from a JSON URL or Data.
    public static func load(from url: URL) throws -> [CommandManifestEntry] {
        let data = try Data(contentsOf: url)
        return try load(from: data)
    }

    public static func load(from data: Data) throws -> [CommandManifestEntry] {
        // Support either an array `[{...}]` or an object `{"commands": [{...}]}`
        if let list = try? JSONDecoder().decode([CommandManifestEntry].self, from: data) {
            return list
        }
        let manifest = try JSONDecoder().decode(CommandManifest.self, from: data)
        return manifest.commands
    }

    /// Discovers and loads all `Resources/registry.json` manifests found in bundle resources.
    public static func discoverManifests() -> [CommandManifestEntry] {
        var entries: [CommandManifestEntry] = []
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            if let url = bundle.url(forResource: "registry", withExtension: "json"),
               let loaded = try? load(from: url) {
                entries.append(contentsOf: loaded)
            }
        }
        return entries
    }
}
