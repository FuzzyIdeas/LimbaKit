import Foundation

/// Names and paths fixed by PROTOCOL.md. Both sides of the protocol read them from here.
public enum LimbaProtocol {
    public static let version = 2

    /// User defaults key, in the app's domain, that holds the chosen language identifier.
    public static let languageDefaultsKey = "LimbaLanguage"

    /// Distributed notification a translator posts to a running app. Object: the app's bundle identifier.
    public static let commandNotification = Notification.Name("limba.command")
    /// Distributed notification an app posts after writing `state.json`. Object: its bundle identifier.
    public static let stateNotification = Notification.Name("limba.state")

    /// Folder inside `Contents/Resources` that holds the unprocessed String Catalogs and the manifest.
    public static let resourceFolder = "Limba"
    public static let manifestFile = "app.json"
    public static let contextFile = "context.md"

    /// Folder inside Application Support that holds one folder per app.
    public static let supportFolder = "Limba"
    public static let stateFile = "state.json"
    public static let languageFile = "language.json"

    public enum Command: String, Codable, Sendable {
        case hello, select, probe, show, refresh
    }

    public enum Capability: String, Codable, Sendable {
        /// Text updates on screen without a relaunch.
        case live
        /// Markers can be turned on.
        case probe
        /// The app can open its deep links by identifier.
        case deepLinks

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            // Protocol 1 called deep links "screens".
            guard let value = Capability(rawValue: raw == "screens" ? "deepLinks" : raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown capability \(raw)"))
            }
            self = value
        }
    }
}

/// Contents of `state.json`, written by a running app.
public struct AppState: Codable, Sendable, Equatable {
    /// A view of the app that a translator can open, such as a Settings pane.
    public struct DeepLink: Codable, Sendable, Equatable, Hashable {
        public var id: String
        public var title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public var `protocol`: Int
    public var pid: Int32
    public var language: String?
    public var revision: Int
    public var probe: Bool
    public var capabilities: [LimbaProtocol.Capability]
    public var deepLinks: [DeepLink]
    /// Marker number (as a string) to [table, key].
    public var markers: [String: [String]]
    /// [table, key] pairs looked up at runtime that no shipped catalog contains.
    public var seen: [[String]]
    public var updated: Date

    public init(
        pid: Int32, language: String?, revision: Int, probe: Bool,
        capabilities: [LimbaProtocol.Capability], deepLinks: [DeepLink],
        markers: [String: [String]], seen: [[String]], updated: Date = Date()
    ) {
        self.protocol = LimbaProtocol.version
        self.pid = pid
        self.language = language
        self.revision = revision
        self.probe = probe
        self.capabilities = capabilities
        self.deepLinks = deepLinks
        self.markers = markers
        self.seen = seen
        self.updated = updated
    }

    enum CodingKeys: String, CodingKey {
        case `protocol`, pid, language, revision, probe, capabilities, deepLinks, markers, seen, updated
        /// Protocol 1 wrote deep links under this key.
        case screens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.protocol = try c.decode(Int.self, forKey: .protocol)
        pid = try c.decode(Int32.self, forKey: .pid)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        revision = try c.decode(Int.self, forKey: .revision)
        probe = try c.decode(Bool.self, forKey: .probe)
        capabilities = try c.decode([LimbaProtocol.Capability].self, forKey: .capabilities)
        deepLinks = try c.decodeIfPresent([DeepLink].self, forKey: .deepLinks)
            ?? c.decodeIfPresent([DeepLink].self, forKey: .screens) ?? []
        markers = try c.decode([String: [String]].self, forKey: .markers)
        seen = try c.decode([[String]].self, forKey: .seen)
        updated = try c.decode(Date.self, forKey: .updated)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.protocol, forKey: .protocol)
        try c.encode(pid, forKey: .pid)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encode(revision, forKey: .revision)
        try c.encode(probe, forKey: .probe)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encode(deepLinks, forKey: .deepLinks)
        try c.encode(markers, forKey: .markers)
        try c.encode(seen, forKey: .seen)
        try c.encode(updated, forKey: .updated)
    }
}

/// Contents of `language.json`, written by a translator next to the tables.
public struct LanguageInfo: Codable, Sendable, Equatable {
    public var `protocol`: Int
    public var language: String
    public var name: String?
    public var translator: String?
    public var updated: Date?

    public init(language: String, name: String? = nil, translator: String? = nil, updated: Date? = Date()) {
        self.protocol = LimbaProtocol.version
        self.language = language
        self.name = name
        self.translator = translator
        self.updated = updated
    }
}

/// Contents of `Contents/Resources/Limba/app.json`.
public struct AppManifest: Codable, Sendable, Equatable {
    public struct Term: Codable, Sendable, Equatable, Hashable {
        public var term: String
        public var note: String?
        /// False for terms that stay in the source language.
        public var translate: Bool?

        public init(term: String, note: String? = nil, translate: Bool? = nil) {
            self.term = term
            self.note = note
            self.translate = translate
        }
    }

    public var `protocol`: Int?
    public var description: String?
    public var context: String?
    public var glossary: [Term]?

    public init(description: String? = nil, context: String? = nil, glossary: [Term]? = nil) {
        self.protocol = LimbaProtocol.version
        self.description = description
        self.context = context
        self.glossary = glossary
    }
}

public extension JSONEncoder {
    /// ISO 8601 dates with milliseconds, so a reader can order two writes made within one second.
    static var limba: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = encoder.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        return e
    }
}

public extension JSONDecoder {
    /// Reads ISO 8601 dates with or without fractional seconds.
    static var limba: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO 8601 date: \(s)")
        }
        return d
    }
}
