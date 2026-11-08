import Foundation

/// Where translation files live, per PROTOCOL.md section 2.
public enum LimbaPaths {
    /// The folder of one app's translations, as seen from inside that app.
    public static func translationsFolder(bundleIdentifier: String, fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent(LimbaProtocol.supportFolder, isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// The folder of one app's translations, as seen from another process (a translator).
    /// A sandboxed app resolves Application Support inside its container.
    public static func translationsFolder(bundleIdentifier: String, sandboxed: Bool, home: URL = realHome) -> URL {
        var support = home.appendingPathComponent("Library", isDirectory: true)
        if sandboxed {
            support = support
                .appendingPathComponent("Containers", isDirectory: true)
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent("Data/Library", isDirectory: true)
        }
        return support
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(LimbaProtocol.supportFolder, isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// The user's home folder, even when the caller runs in a sandbox.
    public static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `<folder>/<language>.lproj`
    public static func lproj(_ language: String, in folder: URL) -> URL {
        folder.appendingPathComponent("\(language).lproj", isDirectory: true)
    }

    /// Language identifiers that have an `.lproj` folder with at least one table.
    public static func languages(in folder: URL, fileManager: FileManager = .default) -> [String] {
        guard let items = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.pathExtension == "lproj" }
            .filter { dir in
                let files = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
                return files.contains { $0.hasSuffix(".strings") || $0.hasSuffix(".stringsdict") }
            }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// `Contents/Resources/Limba` of an app bundle.
    public static func resources(of bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent(LimbaProtocol.resourceFolder, isDirectory: true)
    }
}
