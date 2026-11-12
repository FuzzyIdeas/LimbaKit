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
    public static var language: String? { LimbaRuntime.shared.currentLanguage }

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
    @Published public private(set) var language: String? {
        didSet { readable.withLock { $0.language = language } }
    }
    /// Translations found in the app's translation folder.
    @Published public private(set) var languages: [String] = []
    /// Grows by one on every change, so that views depending on it render again.
    @Published public private(set) var revision = 0 {
        didSet { readable.withLock { $0.revision = revision } }
    }
    /// Copies of `language` and `revision` that any thread can read. The properties themselves change
    /// on the main thread only, and `Limba.language`, `locale` and `String(limba:)` can be called anywhere.
    private let readable = OSAllocatedUnfairLock(initialState: (language: String?.none, revision: 0))
    /// Grows on a `refresh` command; views under `.limba()` are rebuilt when it changes.
    @Published public private(set) var rebuildToken = 0
    @Published public private(set) var probe = false

    public private(set) var bundle: Bundle = .main
    /// `<Application Support>/Limba/<bundle identifier>`
    public private(set) var folder: URL?

    /// The active translation, readable from any thread.
    public var currentLanguage: String? { readable.withLock { $0.language } }

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
        let (language, revision) = readable.withLock { ($0.language, $0.revision) }
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
    /// Bumped by every activation, so a copy that finishes after a newer one started is dropped.
    private var activation = 0
    /// The newest activation and selection, readable from `ioQueue`, so that work queued behind a newer
    /// request is skipped instead of run. A burst of language changes would otherwise copy the
    /// translation once per change and keep the queue busy for seconds.
    private let newest = OSAllocatedUnfairLock(initialState: (activation: 0, selection: 0))
    private var selection = 0
    private var pendingState: DispatchWorkItem?
    /// File I/O that runs on every file event or state change stays off the main thread: a directory
    /// listing or a rename can stall for seconds in the file system, and the app would hang with it.
    /// Serial, so scans and writes finish in the order they were started.
    private static let ioQueue = DispatchQueue(label: "LimbaKit.io", qos: .utility)
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
        self.folder = folder

        // Each launch copies into its own folder, so the copies of earlier launches can be removed in
        // the background instead of before the first window draws.
        let appStages = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Limba", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        let stageRoot = appStages.appendingPathComponent("\(getpid())", isDirectory: true)
        self.stageRoot = stageRoot

        if let saved = UserDefaults.standard.string(forKey: LimbaProtocol.languageDefaultsKey), !saved.isEmpty {
            loadAtLaunch(saved, folder: folder)
        } else {
            // Without a chosen translation nothing has to load before the first window, so the folder
            // is created and listed off the main thread: either call can block for 30 s on a busy disk.
            Self.ioQueue.async { [weak self] in
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let found = LimbaPaths.languages(in: folder)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if self.languages.isEmpty { self.languages = found }
                        self.watch(folder)
                    }
                }
            }
        }
        // Queued after the launch load, which the launch may be waiting for.
        Self.ioQueue.async {
            let old = (try? fm.contentsOfDirectory(at: appStages, includingPropertiesForKeys: nil)) ?? []
            for url in old where url.lastPathComponent != stageRoot.lastPathComponent {
                try? fm.removeItem(at: url)
            }
        }
        listen()
        scheduleState(after: 0.5)
    }

    /// The result of the launch load, taken once by whichever of its two callers comes first.
    private final class LaunchLoad: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (found: [String], result: Result<Staged, Error>?)?

        func set(_ found: [String], _ result: Result<Staged, Error>?) {
            lock.lock(); value = (found, result); lock.unlock()
        }

        func take() -> (found: [String], result: Result<Staged, Error>?)? {
            lock.lock(); defer { lock.unlock() }
            let v = value
            value = nil
            return v
        }
    }

    /// Loads the chosen translation at launch. The first window should already be translated, so the
    /// launch waits for the copy, but for one second at most: on a disk that stalls, the app starts in
    /// its built-in language and switches to the translation once the copy is ready.
    @MainActor
    private func loadAtLaunch(_ saved: String, folder: URL) {
        activation += 1
        let id = activation
        newest.withLock { $0.activation = id }
        guard let stageRoot else { return }
        stageCounter += 1
        let stage = stageRoot.appendingPathComponent("\(stageCounter)", isDirectory: true)
        let load = LaunchLoad()
        let resources = LimbaPaths.resources(of: bundle.bundleURL)
        let done = DispatchSemaphore(value: 0)
        // The main thread waits on this block, so it runs at the main thread's priority.
        Self.ioQueue.async(qos: .userInitiated, flags: .enforceQoS) { [weak self] in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let found = LimbaPaths.languages(in: folder)
            let result = found.contains(saved)
                ? Result { try Self.copy(LimbaPaths.lproj(saved, in: folder), toStage: stage, language: saved, resources: resources) }
                : nil
            load.set(found, result)
            done.signal()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishLaunchLoad(load, id: id, language: saved, stage: stage, late: true) }
            }
        }
        if done.wait(timeout: .now() + 1) == .success {
            finishLaunchLoad(load, id: id, language: saved, stage: stage, late: false)
        } else {
            NSLog("Limba: loading %@ took more than a second, so the app starts in its built-in language", saved)
        }
        watch(folder)
    }

    @MainActor
    private func finishLaunchLoad(_ load: LaunchLoad, id: Int, language saved: String, stage: URL, late: Bool) {
        // Called twice when the load finished in time; the second call finds nothing to take.
        guard let (found, result) = load.take() else { return }
        languages = found
        guard let result else { return }
        guard id == activation else {
            Self.ioQueue.async { try? FileManager.default.removeItem(at: stage) }
            return
        }
        switch result {
        case let .success(staged):
            install(staged, language: saved)
            if late { changed("\(saved) loaded after launch") }
        case let .failure(error):
            Self.ioQueue.async { try? FileManager.default.removeItem(at: stage) }
            NSLog("Limba: could not load %@: %@", saved, error.localizedDescription)
        }
    }

    /// Starts watching the translations folder, after it exists.
    @MainActor
    private func watch(_ folder: URL) {
        guard watcher == nil else { return }
        watcher = DirectoryWatcher(url: folder) { [weak self] paths in
            Task { @MainActor in self?.filesChanged(paths) }
        }
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
        guard let folder else { return }
        selection += 1
        let id = selection
        newest.withLock { $0.selection = id }
        Self.ioQueue.async { [weak self] in
            guard let self, self.newest.withLock({ $0.selection }) == id else { return }
            let found = LimbaPaths.languages(in: folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard id == self.selection else { return }
                    self.languages = found
                    guard value != self.language else {
                        self.scheduleState()
                        return
                    }
                    self.activate(value) { self.changed("select \(value ?? "built-in")") }
                }
            }
        }
    }

    /// Copies the translation to a new folder and points the hook at it. NSBundle caches string tables
    /// per path for the life of the process, so each revision gets a path it has never seen.
    ///
    /// The copy runs on `ioQueue`, and `then` runs on the main thread once the hook points at the new
    /// copy (or the copy failed). An activation that a newer one replaced while it copied does nothing,
    /// and its `then` never runs.
    @MainActor
    private func activate(_ requested: String?, then: (@MainActor () -> Void)? = nil) {
        activation += 1
        let current = activation
        newest.withLock { $0.activation = current }
        guard let requested, let folder, let stageRoot, languages.contains(requested) else {
            LBHook.setOverlayBundle(nil, language: nil)
            language = nil
            then?()
            return
        }
        let id = activation
        stageCounter += 1
        let stage = stageRoot.appendingPathComponent("\(stageCounter)", isDirectory: true)
        let source = LimbaPaths.lproj(requested, in: folder)
        let resources = LimbaPaths.resources(of: bundle.bundleURL)

        // A copy that never becomes the overlay is removed, or it stays in Caches until the next launch.
        let discard = { Self.ioQueue.async { try? FileManager.default.removeItem(at: stage) } }
        let finish: @MainActor (Result<Staged, Error>) -> Void = { [weak self] result in
            guard let self, id == self.activation else {
                discard()
                return
            }
            switch result {
            case let .success(staged):
                self.install(staged, language: requested)
            case let .failure(error):
                discard()
                NSLog("Limba: could not load %@: %@", requested, error.localizedDescription)
            }
            then?()
        }
        Self.ioQueue.async { [newest] in
            // A newer activation replaced this one while it waited: its copy would be thrown away.
            guard newest.withLock({ $0.activation }) == id else { return }
            let result = Result { try Self.copy(source, toStage: stage, language: requested, resources: resources) }
            DispatchQueue.main.async { MainActor.assumeIsolated { finish(result) } }
        }
    }

    /// A finished copy: its folder, the bundle that reads it, and the fingerprint of the source files.
    private struct Staged: @unchecked Sendable {
        let url: URL
        let bundle: Bundle?
        let fingerprint: [String]
    }

    /// Copies `<language>.lproj` into `stage`. The bundle is opened and its tables are loaded here
    /// too, since both read from disk: the first lookup in a table reads and parses the whole file, and
    /// it would otherwise happen on the main thread, when the app draws its first label.
    private static func copy(_ source: URL, toStage stage: URL, language: String, resources: URL) throws -> Staged {
        let fm = FileManager.default
        let destination = LimbaPaths.lproj(language, in: stage)
        // Read and write the bytes instead of copyItem: an APFS clone shows up as an FSEvent on the
        // source files, which would trigger another reload. Each table is checked on the way: a value
        // of the wrong type crashes the app inside CFBundle's lookup, so only clean entries are copied,
        // and a file that can't be read is left out.
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var tables = Set<String>()
        for file in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where !file.lastPathComponent.hasPrefix(".") {
            let name = file.lastPathComponent
            let table = (name as NSString).deletingPathExtension
            let sources = shippedCatalog(resources).texts[table] ?? [:]
            guard let data = try? Data(contentsOf: file, options: .uncached), let clean = SafeTables.cleaned(data, name: name, sources: sources) else {
                NSLog("Limba: skipped %@, which is not a valid strings table", name)
                continue
            }
            try clean.write(to: destination.appendingPathComponent(name, isDirectory: false))
            tables.insert(table)
        }
        let bundle = Bundle(path: stage.path)
        if let bundle { LBHook.warm(bundle, language: language, tables: tables.sorted()) }
        return Staged(url: stage, bundle: bundle, fingerprint: fingerprint(source))
    }

    @MainActor
    private func install(_ staged: Staged, language requested: String) {
        guard let overlay = staged.bundle else { return }
        LBHook.setOverlayBundle(overlay, language: requested)
        language = requested
        loadedFingerprint = staged.fingerprint

        // Keep the previous copy for a moment: a lookup on another thread may still be reading it.
        stages.append(staged.url)
        while stages.count > 2 {
            let old = stages.removeFirst()
            Self.ioQueue.async { try? FileManager.default.removeItem(at: old) }
        }
    }

    static let log = Logger(subsystem: "Limba", category: "runtime")

    /// Reasons for the changes waiting to be applied, and whether a `refresh` is among them.
    private var pendingReasons: [String] = []
    private var pendingRebuild = false

    /// Applies changes at most once every 50 ms. Every change makes SwiftUI render each view under
    /// `.limba()` again and walks every AppKit window and menu, so a burst of commands or file events,
    /// applied one by one, would keep the main thread busy for seconds.
    @MainActor
    private func changed(_ reason: String, rebuild: Bool = false) {
        pendingRebuild = pendingRebuild || rebuild
        pendingReasons.append(reason)
        guard pendingReasons.count == 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.applyChanges() }
        }
    }

    @MainActor
    private func applyChanges() {
        let reasons = pendingReasons
        pendingReasons = []
        guard !reasons.isEmpty else { return }
        let summary = reasons.count > 3 ? "\(reasons.prefix(3).joined(separator: "; ")) and \(reasons.count - 3) more" : reasons.joined(separator: "; ")
        Self.log.info("revision \(self.revision + 1, privacy: .public): \(summary, privacy: .public)")
        if pendingRebuild {
            pendingRebuild = false
            rebuildToken += 1
        }
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

        // List the folder off the main thread, then act on the result back on it.
        let current = language
        Self.ioQueue.async { [weak self] in
            let found = LimbaPaths.languages(in: folder)
            let scannedPrint = current.map { Self.fingerprint(LimbaPaths.lproj($0, in: folder)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.apply(found: found, fingerprint: scannedPrint, of: current, relevant: relevant)
                }
            }
        }
    }

    @MainActor
    private func apply(found: [String], fingerprint: [String]?, of scanned: String?, relevant: [String]) {
        if found != languages { languages = found }

        if let language {
            if !languages.contains(language) {
                activate(nil) { self.changed("\(language) removed") }
            } else if relevant.contains(where: { $0.contains("/\(language).lproj") }),
                      language != scanned || fingerprint != loadedFingerprint {
                let names = relevant.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                activate(language) { self.changed("files changed: \(names)") }
            }
        } else if let saved = UserDefaults.standard.string(forKey: LimbaProtocol.languageDefaultsKey),
                  languages.contains(saved) {
            activate(saved) { self.changed("\(saved) appeared") }
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
        changed("refresh", rebuild: true)
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
        var capabilities: [LimbaProtocol.Capability] = [.live, .probe]
        if !deepLinks.isEmpty { capabilities.append(.deepLinks) }
        // LimbaKit's own text is listed even before it shows: the language picker stays hidden until
        // the first translation exists, so its label would otherwise never reach that translation.
        let own = Self.ownKeys.map { SourceString.id(table: "Localizable", key: $0) }
        let (pid, language, revision, probe, deepLinks) = (getpid(), language, revision, probe, deepLinks.map(\.link))
        let resources = LimbaPaths.resources(of: bundle.bundleURL)
        // isDirectory: false keeps Foundation from calling lstat on the main thread to find out,
        // which blocked for 30 s while the disk was busy.
        let url = folder.appendingPathComponent(LimbaProtocol.stateFile, isDirectory: false)
        let bundleIdentifier = bundleIdentifier
        // Parsing the shipped catalogs (once) and writing the file both stay off the main thread.
        Self.ioQueue.async {
            // The hook's tables can hold tens of thousands of keys, so they are copied here and not on
            // the main thread. Both getters take the hook's lock.
            var markers: [String: [String]] = [:]
            for (number, tableKey) in LBHook.markerTable() {
                markers["\(number)"] = Self.split(tableKey)
            }
            let seen = LBHook.seenTableKeys().union(own)
            let state = AppState(
                pid: pid, language: language, revision: revision, probe: probe,
                capabilities: capabilities, deepLinks: deepLinks,
                markers: markers, seen: Self.discoveredKeys(seen, resources: resources)
            )
            if let data = try? JSONEncoder.limba.encode(state) { try? StringsFiles.writeAtomically(data, to: url) }
            DistributedNotificationCenter.default().postNotificationName(
                LimbaProtocol.stateNotification, object: bundleIdentifier, userInfo: nil, deliverImmediately: true
            )
        }
    }

    /// Keys the app looked up that no shipped catalog contains, such as strings from Swift packages
    /// that resolve against the main bundle. Runs on `ioQueue` only.
    private static func discoveredKeys(_ seen: Set<String>, resources: URL) -> [[String]] {
        let shipped = shippedCatalog(resources)
        // Frameworks look up their own keys in the main bundle too (AccessibilityImageDescriptions,
        // InfoPlist); only tables that the app ships hold the app's strings.
        let tables: Set<String> = shipped.tables.isEmpty ? ["Localizable"] : shipped.tables
        return seen.filter { !shipped.keys.contains($0) }.map(split)
            .filter { $0.count == 2 && tables.contains($0[0]) && !$0[1].isEmpty }
            .sorted { $0[1] < $1[1] }
    }

    /// What the app's string catalogs hold, read once. Touched on `ioQueue` only.
    private struct Shipped {
        var keys = Set<String>()
        var tables = Set<String>()
        /// The source text of each key, by table, to check the placeholders of a translation against.
        var texts: [String: [String: String]] = [:]
    }

    private static var shipped: Shipped?

    private static func shippedCatalog(_ folder: URL) -> Shipped {
        if let shipped { return shipped }
        var result = Shipped()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "xcstrings" {
            guard let catalog = try? StringCatalog.load(file) else { continue }
            let table = file.deletingPathExtension().lastPathComponent
            if table != "InfoPlist" { result.tables.insert(table) }
            for key in catalog.strings.keys { result.keys.insert(SourceString.id(table: table, key: key)) }
            var texts: [String: String] = [:]
            for string in catalog.sourceStrings(table: table) where string.text != string.key {
                texts[string.key] = string.text
            }
            result.texts[table] = texts
        }
        shipped = result
        return result
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
