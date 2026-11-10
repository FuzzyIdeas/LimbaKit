import AppKit
import Combine
import Foundation
import os
import LimbaCore
import LimbaHook

/// Entry points for an app that adopts the Limba protocol. See README.md for the steps.
///
/// Every function can be called from any context, including `main.swift` and code that is not
/// isolated to the main actor. Called on the main thread, which is where apps call them, they run
/// right away; called anywhere else, they run on the main thread soon after.
public enum Limba {
    /// Hooks string lookups, loads the chosen translation and starts watching for changes.
    /// Call it before the app builds any UI: in the `App` initializer, in `main.swift`, or in
    /// `applicationWillFinishLaunching`.
    public static func start(bundle: Bundle = .main) {
        onMain { LimbaRuntime.shared.start(bundle: bundle) }
    }

    /// Switches to `language`, or to the built-in language when nil, and keeps the choice for the next launch.
    public static func select(_ language: String?) {
        onMain { LimbaRuntime.shared.select(language) }
    }

    /// Lets a translator open a view of the app from Limba, to review its strings in place.
    /// `title` is how the view is named to the person translating, such as "Settings > General".
    public static func addDeepLink(_ id: String, title: String, open: @escaping @MainActor () -> Void) {
        onMain { LimbaRuntime.shared.addDeepLink(id, title: title, open: open) }
    }

    @available(*, deprecated, renamed: "addDeepLink(_:title:open:)")
    public static func registerScreen(_ id: String, title: String, open: @escaping @MainActor () -> Void) {
        addDeepLink(id, title: title, open: open)
    }

    /// Re-applies the current language to AppKit windows and menus, for text the app set itself.
    public static func relocalize() {
        onMain { AppKitRelocalizer.relocalizeEverything() }
    }

    /// The active translation, or nil for the built-in language.
    public static var language: String? { LimbaRuntime.shared.language }

    static func onMain(_ body: @escaping @MainActor () -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { onMain(body) }
            return
        }
        if #available(macOS 14.0, *) {
            MainActor.assumeIsolated { body() }
        } else {
            // On the main thread the main actor is already running, so calling the closure is safe.
            unsafeBitCast(body, to: (() -> Void).self)()
        }
    }
}

public extension Notification.Name {
    /// Posted on the main thread after the language or the active translation changes.
    static let limbaDidChange = Notification.Name("LimbaDidChange")
}

/// State of the protocol inside an app. One instance per process, `LimbaRuntime.shared`.
// All state changes happen on the main actor; the class is shared with callbacks that hop there first.
public final class LimbaRuntime: ObservableObject, @unchecked Sendable {
    public static let shared = LimbaRuntime()

    /// The active translation, or nil for the built-in language.
    @Published public private(set) var language: String?
    /// Translations found in the app's translation folder.
    @Published public private(set) var languages: [String] = []
    /// Grows by one on every change, so that views depending on it render again.
    @Published public private(set) var revision = 0
    /// Grows on a `refresh` command; views under `.limba()` are rebuilt when it changes.
    @Published public private(set) var rebuildToken = 0
    @Published public private(set) var probe = false

    public private(set) var bundle: Bundle = .main
    /// `<Application Support>/Limba/<bundle identifier>`
    public private(set) var folder: URL?

    public var bundleIdentifier: String { bundle.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    /// The built-in language, in its own name.
    public var builtInLanguageName: String {
        Languages.nativeName(bundle.developmentLocalization ?? "en")
    }

    /// The locale that `.limba()` puts in the SwiftUI environment: the user's region with the
    /// translation's language, so plural rules and dates follow the language on screen. The `lb`
    /// keyword changes with each revision and changes nothing else; a new value makes SwiftUI resolve
    /// its text again while every view keeps its state.
    public var locale: Locale {
        guard language != nil || revision > 0 else { return .autoupdatingCurrent }
        var components = Locale.Components(locale: .current)
        if let language {
            components.languageComponents = Locale.Language.Components(identifier: language)
        }
        let base = Locale(components: components).identifier
        return Locale(identifier: base + (base.contains("@") ? ";" : "@") + "lb=\(revision)")
    }

    private var started = false
    private var watcher: DirectoryWatcher?
    private var stageRoot: URL?
    private var stageCounter = 0
    private var stages: [URL] = []
    private var deepLinks: [(link: AppState.DeepLink, open: @MainActor () -> Void)] = []
    private var observers: [NSObjectProtocol] = []
    private var catalogKeys: Set<String>?
    private var pendingState: DispatchWorkItem?
    /// File I/O for the state file stays off the main thread: a rename can stall for seconds in the
    /// file system (a path lookup by file ID), and the app would hang with it.
    private static let stateQueue = DispatchQueue(label: "LimbaKit.state", qos: .utility)
    /// Names, sizes and dates of the loaded translation files, to ignore events that changed nothing.
    private var loadedFingerprint: [String] = []

    // MARK: Start

    @MainActor
    func start(bundle: Bundle) {
        guard !started else { return }
        started = true
        self.bundle = bundle
        _ = LBHook.install(on: bundle)

        let fm = FileManager.default
        let folder = LimbaPaths.translationsFolder(bundleIdentifier: bundleIdentifier)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder

        let stageRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Limba", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        try? fm.removeItem(at: stageRoot)
        self.stageRoot = stageRoot

        languages = LimbaPaths.languages(in: folder)
        if let saved = UserDefaults.standard.string(forKey: LimbaProtocol.languageDefaultsKey), !saved.isEmpty {
            activate(saved)
        }

        watcher = DirectoryWatcher(url: folder) { [weak self] paths in
            Task { @MainActor in self?.filesChanged(paths) }
        }
        listen()
        scheduleState(after: 0.5)
    }

    // MARK: Language

    @MainActor
    func select(_ requested: String?) {
        let value = (requested?.isEmpty ?? true) ? nil : requested
        if let value {
            UserDefaults.standard.set(value, forKey: LimbaProtocol.languageDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LimbaProtocol.languageDefaultsKey)
        }
        if let folder { languages = LimbaPaths.languages(in: folder) }
        guard value != language else {
            scheduleState()
            return
        }
        activate(value)
        changed("select \(value ?? "built-in")")
    }

    /// Copies the translation to a new folder and points the hook at it. NSBundle caches string tables
    /// per path for the life of the process, so each revision gets a path it has never seen.
    @MainActor
    private func activate(_ requested: String?) {
        guard let requested, let folder, let stageRoot, languages.contains(requested) else {
            LBHook.setOverlayBundle(nil, language: nil)
            language = nil
            return
        }
        let fm = FileManager.default
        stageCounter += 1
        let stage = stageRoot.appendingPathComponent("\(stageCounter)", isDirectory: true)
        let source = LimbaPaths.lproj(requested, in: folder)
        let destination = LimbaPaths.lproj(requested, in: stage)
        do {
            // Read and write the bytes instead of copyItem: an APFS clone shows up as an FSEvent on the
            // source files, which would trigger another reload.
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where !file.lastPathComponent.hasPrefix(".") {
                try Data(contentsOf: file).write(to: destination.appendingPathComponent(file.lastPathComponent))
            }
        } catch {
            NSLog("Limba: could not load %@: %@", requested, error.localizedDescription)
            return
        }
        guard let overlay = Bundle(path: stage.path) else { return }
        LBHook.setOverlayBundle(overlay, language: requested)
        language = requested
        loadedFingerprint = Self.fingerprint(source)

        // Keep the previous copy for a moment: a lookup on another thread may still be reading it.
        stages.append(stage)
        while stages.count > 2 {
            try? fm.removeItem(at: stages.removeFirst())
        }
    }

    static let log = Logger(subsystem: "Limba", category: "runtime")

    @MainActor
    private func changed(_ reason: String) {
        Self.log.info("revision \(self.revision + 1, privacy: .public): \(reason, privacy: .public)")
        revision += 1
        AppKitRelocalizer.relocalizeEverything()
        NotificationCenter.default.post(name: .limbaDidChange, object: nil)
        scheduleState()
    }

    @MainActor
    private func filesChanged(_ paths: [String]) {
        let relevant = paths.filter { path in
            let name = (path as NSString).lastPathComponent
            return !name.hasPrefix(".") && name != LimbaProtocol.stateFile
        }
        guard !relevant.isEmpty, let folder else { return }

        let found = LimbaPaths.languages(in: folder)
        if found != languages { languages = found }

        if let language {
            if !languages.contains(language) {
                activate(nil)
                changed("\(language) removed")
            } else if relevant.contains(where: { $0.contains("/\(language).lproj") }),
                      Self.fingerprint(LimbaPaths.lproj(language, in: folder)) != loadedFingerprint {
                activate(language)
                changed("files changed: \(relevant.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
            }
        } else if let saved = UserDefaults.standard.string(forKey: LimbaProtocol.languageDefaultsKey),
                  languages.contains(saved) {
            activate(saved)
            changed("\(saved) appeared")
        }
        scheduleState()
    }

    // MARK: Probe, deep links, refresh

    @MainActor
    func setProbe(_ on: Bool) {
        if on != probe {
            probe = on
            LBHook.markersEnabled = on
            changed(on ? "probe on" : "probe off")
        }
        // Markers get their numbers while views render again, so write the state once that settles.
        scheduleState(after: 0.8)
    }

    @MainActor
    func refresh() {
        rebuildToken += 1
        changed("refresh")
    }

    @MainActor
    func addDeepLink(_ id: String, title: String, open: @escaping @MainActor () -> Void) {
        deepLinks.removeAll { $0.link.id == id }
        deepLinks.append((AppState.DeepLink(id: id, title: title), open))
        scheduleState()
    }

    @MainActor
    private func show(_ id: String) {
        deepLinks.first { $0.link.id == id }?.open()
        scheduleState(after: 0.8)
    }

    // MARK: Commands

    @MainActor
    private func listen() {
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: LimbaProtocol.commandNotification, object: bundleIdentifier, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            Task { @MainActor in self?.handle(info) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.changed("system locale changed") }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
            guard let menu = note.object as? NSMenu else { return }
            Task { @MainActor in
                guard let self, self.language != nil || self.revision > 0 else { return }
                AppKitRelocalizer.relocalize(menu: menu)
            }
        })
    }

    @MainActor
    private func handle(_ info: [AnyHashable: Any]) {
        guard let name = info["command"] as? String, let command = LimbaProtocol.Command(rawValue: name) else { return }
        switch command {
        case .hello:
            scheduleState()
        case .select:
            select(info["language"] as? String)
        case .probe:
            setProbe((info["on"] as? Bool) ?? true)
        case .show:
            // Protocol 1 translators send the identifier as "screen".
            if let id = (info["deepLink"] ?? info["screen"]) as? String { show(id) }
        case .refresh:
            refresh()
        }
    }

    // MARK: State

    @MainActor
    private func scheduleState(after delay: TimeInterval = 0.05) {
        pendingState?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.writeState() }
        }
        pendingState = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @MainActor
    func writeState() {
        guard let folder else { return }
        var markers: [String: [String]] = [:]
        for (number, tableKey) in LBHook.markerTable() {
            markers["\(number)"] = Self.split(tableKey)
        }
        var capabilities: [LimbaProtocol.Capability] = [.live, .probe]
        if !deepLinks.isEmpty { capabilities.append(.deepLinks) }
        let state = AppState(
            pid: getpid(), language: language, revision: revision, probe: probe,
            capabilities: capabilities, deepLinks: deepLinks.map(\.link),
            markers: markers, seen: discoveredKeys()
        )
        let data = try? JSONEncoder.limba.encode(state)
        let url = folder.appendingPathComponent(LimbaProtocol.stateFile)
        let bundleIdentifier = bundleIdentifier
        Self.stateQueue.async {
            if let data { try? StringsFiles.writeAtomically(data, to: url) }
            DistributedNotificationCenter.default().postNotificationName(
                LimbaProtocol.stateNotification, object: bundleIdentifier, userInfo: nil, deliverImmediately: true
            )
        }
    }

    /// Keys the app looked up that no shipped catalog contains, such as strings from Swift packages
    /// that resolve against the main bundle.
    private func discoveredKeys() -> [[String]] {
        let known = shippedCatalogKeys()
        // Frameworks look up their own keys in the main bundle too (AccessibilityImageDescriptions,
        // InfoPlist); only tables that the app ships hold the app's strings.
        let tables: Set<String> = shippedTables.isEmpty ? ["Localizable"] : shippedTables
        // LimbaKit's own text is listed even before it shows: the language picker stays hidden until
        // the first translation exists, so its label would otherwise never reach that translation.
        let own = Self.ownKeys.map { SourceString.id(table: "Localizable", key: $0) }
        let pairs: [[String]] = LBHook.seenTableKeys().union(own).filter { !known.contains($0) }.map(Self.split)
        return pairs
            .filter { $0.count == 2 && tables.contains($0[0]) && !$0[1].isEmpty }
            .sorted { $0[1] < $1[1] }
    }

    private var shippedTables = Set<String>()

    private func shippedCatalogKeys() -> Set<String> {
        if let catalogKeys { return catalogKeys }
        var keys = Set<String>()
        let folder = LimbaPaths.resources(of: bundle.bundleURL)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "xcstrings" {
            guard let catalog = try? StringCatalog.load(file) else { continue }
            let table = file.deletingPathExtension().lastPathComponent
            if table != "InfoPlist" { shippedTables.insert(table) }
            for key in catalog.strings.keys { keys.insert(SourceString.id(table: table, key: key)) }
        }
        catalogKeys = keys
        return keys
    }

    static func fingerprint(_ folder: URL) -> [String] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { url in
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return "\(url.lastPathComponent) \(v.fileSize ?? 0) \(v.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
            }
            .sorted()
    }

    /// Text that LimbaKit shows itself, looked up in the app's main bundle like the app's own text.
    static let ownKeys = ["Language"]

    static func split(_ tableKey: String) -> [String] {
        guard let i = tableKey.firstIndex(of: "\u{1F}") else { return ["Localizable", tableKey] }
        return [String(tableKey[..<i]), String(tableKey[tableKey.index(after: i)...])]
    }
}
