import AppKit
import LimbaCore
import LimbaHook

/// Brings AppKit text up to date after the language changes.
///
/// AppKit keeps the string it was given, so nothing re-resolves on its own. The hook remembers which
/// key produced every string it returned; each piece of text on screen is mapped back to its key and
/// looked up again. Text built from a format string (`"%lld files"`) is matched against the remembered
/// formats and rebuilt with the same arguments. SwiftUI views are skipped, since `.limba()`
/// updates those.
@MainActor
enum AppKitRelocalizer {
    /// Built from the format strings seen so far, and built again only when more were seen. Compiling
    /// one regex per format on every opened menu made menus slow to open in apps with many formats.
    private static var cachedFormats: (count: Int, index: FormatIndex)?

    private static func formatIndex() -> FormatIndex {
        // The count is read without copying the formats, so opening a menu stays cheap.
        let count = Int(LBHook.formatValuesCount)
        if let cachedFormats, cachedFormats.count == count { return cachedFormats.index }
        let index = FormatIndex(LBHook.formatValues())
        cachedFormats = (count, index)
        return index
    }

    static func relocalizeEverything() {
        let formats = formatIndex()
        for window in NSApp.windows {
            relocalize(window: window, formats: formats)
        }
        if let menu = NSApp.mainMenu { relocalize(menu: menu, formats: formats) }
    }

    static func relocalize(menu: NSMenu) {
        relocalize(menu: menu, formats: formatIndex())
    }

    // MARK: Walking

    private static func relocalize(window: NSWindow, formats: FormatIndex) {
        if let t = translate(window.title, formats) { window.title = t }
        if #available(macOS 11.0, *), let t = translate(window.subtitle, formats) { window.subtitle = t }
        for item in window.toolbar?.items ?? [] {
            if let t = translate(item.label, formats) { item.label = t }
            if let t = translate(item.paletteLabel, formats) { item.paletteLabel = t }
            if let tip = item.toolTip, let t = translate(tip, formats) { item.toolTip = t }
        }
        if let view = window.contentView { relocalize(view: view, formats: formats) }
        if let frame = window.contentView?.superview {
            for sub in frame.subviews where sub !== window.contentView { relocalize(view: sub, formats: formats) }
        }
    }

    private static func relocalize(view: NSView, formats: FormatIndex) {
        let className = NSStringFromClass(type(of: view))
        if className.contains("HostingView") || className.contains("7SwiftUI") { return }

        if let tip = view.toolTip, let t = translate(tip, formats) { view.toolTip = t }

        switch view {
        case let popup as NSPopUpButton:
            if let menu = popup.menu { relocalize(menu: menu, formats: formats) }
            popup.synchronizeTitleAndSelectedItem()
        case let button as NSButton:
            if let t = translate(button.title, formats) { button.title = t }
            if let t = translate(button.alternateTitle, formats) { button.alternateTitle = t }
        case let segmented as NSSegmentedControl:
            for i in 0 ..< segmented.segmentCount {
                if let label = segmented.label(forSegment: i), let t = translate(label, formats) { segmented.setLabel(t, forSegment: i) }
                if let tip = segmented.toolTip(forSegment: i), let t = translate(tip, formats) { segmented.setToolTip(t, forSegment: i) }
            }
        case let field as NSTextField:
            if !field.isEditable, let t = translate(field.stringValue, formats) { field.stringValue = t }
            if let placeholder = field.placeholderString, let t = translate(placeholder, formats) { field.placeholderString = t }
        case let tabs as NSTabView:
            for item in tabs.tabViewItems {
                if let t = translate(item.label, formats) { item.label = t }
            }
        case let box as NSBox:
            if let t = translate(box.title, formats) { box.title = t }
        case let table as NSTableView:
            for column in table.tableColumns {
                if let t = translate(column.title, formats) { column.title = t }
                if let tip = column.headerToolTip, let t = translate(tip, formats) { column.headerToolTip = t }
            }
        default:
            break
        }

        for sub in view.subviews { relocalize(view: sub, formats: formats) }
    }

    private static func relocalize(menu: NSMenu, formats: FormatIndex) {
        if let t = translate(menu.title, formats) { menu.title = t }
        for item in menu.items {
            if let attributed = item.attributedTitle, attributed.length > 0 {
                if let t = translate(attributed.string, formats) {
                    let attrs = attributed.attributes(at: 0, effectiveRange: nil)
                    item.attributedTitle = NSAttributedString(string: t, attributes: attrs)
                }
            } else if let t = translate(item.title, formats) {
                item.title = t
            }
            if let tip = item.toolTip, let t = translate(tip, formats) { item.toolTip = t }
            if let sub = item.submenu { relocalize(menu: sub, formats: formats) }
        }
    }

    // MARK: Translating one piece of text

    /// The text in the current language, or nil when it is unknown or already current.
    private static func translate(_ text: String, _ formats: FormatIndex) -> String? {
        guard !text.isEmpty else { return nil }
        var result: String?
        if let tableKey = LBHook.tableKey(forValue: text) {
            result = lookup(tableKey)
        } else if let (tableKey, arguments) = formats.match(text) {
            result = FormatIndex.fill(lookup(tableKey), with: arguments)
        }
        guard let result, result != text else { return nil }
        return result
    }

    private static func lookup(_ tableKey: String) -> String {
        let parts = LimbaRuntime.split(tableKey)
        return LimbaRuntime.shared.bundle.localizedString(forKey: parts[1], value: nil, table: parts[0])
    }
}

/// Matches formatted text such as "3 files" against remembered formats such as "%lld files".
struct FormatIndex {
    private struct Entry {
        let regex: NSRegularExpression
        let positions: [Int]
        let tableKey: String
        /// The literal text before the first placeholder and after the last one, checked before the
        /// regex: most text on screen fails one of them, and a regex for every format on every menu
        /// item made menus slow to open in apps with many formats.
        let prefix: String
        let suffix: String
    }

    private let entries: [Entry]
    /// Texts already matched against this index, and the result. One index serves one set of formats.
    private let matches = Matches()

    private final class Matches {
        var results: [String: (String, [Int: String])?] = [:]
    }

    init(_ formats: [String: String]) {
        entries = formats.compactMap { format, tableKey in
            let specifiers = FormatSpecifiers.parse(format)
            guard !specifiers.isEmpty, !specifiers.contains(where: { $0.type.hasPrefix("#@") }) else { return nil }
            var pattern = "^"
            var cursor = format.startIndex
            var positions: [Int] = []
            for (i, spec) in specifiers.enumerated() {
                pattern += NSRegularExpression.escapedPattern(for: String(format[cursor ..< spec.range.lowerBound]).replacingOccurrences(of: "%%", with: "%"))
                pattern += "(.+?)"
                positions.append(spec.position ?? (i + 1))
                cursor = spec.range.upperBound
            }
            let tail = String(format[cursor...]).replacingOccurrences(of: "%%", with: "%")
            pattern += NSRegularExpression.escapedPattern(for: tail) + "$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
            let head = String(format[..<specifiers[0].range.lowerBound]).replacingOccurrences(of: "%%", with: "%")
            return Entry(regex: regex, positions: positions, tableKey: tableKey, prefix: head, suffix: tail)
        }
    }

    /// The key of the format that produced `text`, and its arguments by position.
    func match(_ text: String) -> (String, [Int: String])? {
        if let known = matches.results[text] { return known }
        let result = findMatch(text)
        if matches.results.count >= 5000 { matches.results.removeAll() }
        matches.results[text] = result
        return result
    }

    private func findMatch(_ text: String) -> (String, [Int: String])? {
        let range = NSRange(text.startIndex..., in: text)
        let ns = text as NSString
        // NSString compares UTF-16 units like the regex does, where String would compare whole characters.
        // It also answers false for an empty prefix or suffix, so those are skipped.
        for entry in entries where (entry.prefix.isEmpty || ns.hasPrefix(entry.prefix)) && (entry.suffix.isEmpty || ns.hasSuffix(entry.suffix)) {
            guard let m = entry.regex.firstMatch(in: text, range: range) else { continue }
            var arguments: [Int: String] = [:]
            for (i, position) in entry.positions.enumerated() {
                if let r = Range(m.range(at: i + 1), in: text) { arguments[position] = String(text[r]) }
            }
            return (entry.tableKey, arguments)
        }
        return nil
    }

    /// Puts the captured arguments into a translated format, by position.
    static func fill(_ format: String, with arguments: [Int: String]) -> String? {
        let specifiers = FormatSpecifiers.parse(format)
        guard !specifiers.contains(where: { $0.type.hasPrefix("#@") }) else { return nil }
        var out = ""
        var cursor = format.startIndex
        for (i, spec) in specifiers.enumerated() {
            out += format[cursor ..< spec.range.lowerBound].replacingOccurrences(of: "%%", with: "%")
            guard let value = arguments[spec.position ?? (i + 1)] else { return nil }
            out += value
            cursor = spec.range.upperBound
        }
        out += format[cursor...].replacingOccurrences(of: "%%", with: "%")
        return out
    }
}
