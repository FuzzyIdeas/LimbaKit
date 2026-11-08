import AppKit
import SwiftUI
import LimbaKit

@main
struct DemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        // Step 1: before any UI exists.
        Limba.start()
    }

    var body: some Scene {
        Window("Limba Demo", id: "main") {
            // Step 2: on every root view, so text updates live.
            MainView().limba()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Display") {
                Button("Sync Mode") {}
                Button("Increase Brightness") {}.keyboardShortcut(.upArrow)
                Button("Decrease Brightness") {}.keyboardShortcut(.downArrow)
            }
        }

        Settings {
            SettingsView().limba()
        }
    }
}

enum Mode: String, CaseIterable, Identifiable {
    case sync, location, sensor, manual
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .sync: "Sync"
        case .location: "Location"
        case .sensor: "Sensor"
        case .manual: "Manual"
        }
    }
}

struct MainView: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage("brightness") private var brightness = 70.0
    @AppStorage("subzero") private var subzero = false
    @AppStorage("mode") private var mode = Mode.sync.rawValue
    @AppStorage("control") private var control = 0
    @AppStorage("threshold") private var threshold = 30.0
    @AppStorage("displays") private var displays = 2

    var body: some View {
        Form {
            Section("Display") {
                LabeledContent("Brightness") {
                    HStack {
                        Slider(value: $brightness, in: 0 ... 100)
                        Text(verbatim: "\(Int(brightness))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Sub-zero dimming", isOn: $subzero)
                Picker("Adaptive mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                LabeledContent("Connected displays") {
                    Text("\(displays) displays")
                }
            }
            Section("Low light automation") {
                Picker("Control", selection: $control) {
                    Text("Dark mode").tag(0)
                    Text("Night Shift").tag(1)
                }
                LabeledContent("Ambient light threshold") {
                    HStack {
                        Slider(value: $threshold, in: 0 ... 200)
                        Text("\(Int(threshold)) lux").monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
            }
            Section {
                Button("Reset Settings") {
                    brightness = 70
                    threshold = 30
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { AppDelegate.openSettingsAction = openSettings }
    }
}

enum SettingsTab: String {
    case general, display
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = SettingsTab.general.rawValue
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage("autoUpdate") private var autoUpdate = true

    var body: some View {
        TabView(selection: $tab) {
            Form {
                Section {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                    Toggle("Show in menu bar", isOn: $showInMenuBar)
                }
                // Step 3: the language picker, in a group of its own at the bottom of Settings > General.
                Section {
                    LabeledContent("Language") {
                        LimbaTranslateButton("Translate with Limba")
                        LimbaLanguagePicker("Language").labelsHidden()
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(SettingsTab.general.rawValue)

            Form {
                Toggle("Automatic updates", isOn: $autoUpdate)
            }
            .formStyle(.grouped)
            .tabItem { Label("Display", systemImage: "display") }
            .tag(SettingsTab.display.rawValue)
        }
        .frame(width: 420, height: 220)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    /// SwiftUI opens the Settings scene only through this action since macOS 14.
    static var openSettingsAction: OpenSettingsAction?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit text set in code: the runtime maps it back to its key when the language changes.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: String(localized: "Open Limba Demo"), action: #selector(openMain), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: String(localized: "Sub-zero dimming"), action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item

        // Step 4, optional: screens a translator can open to read their strings in place.
        Limba.registerScreen("main", title: "Main window") { [weak self] in self?.openMain() }
        Limba.registerScreen("settings.general", title: "Settings > General") { Self.openSettings(.general) }
        Limba.registerScreen("settings.display", title: "Settings > Display") { Self.openSettings(.display) }
    }

    @objc func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
    }

    static func openSettings(_ tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab")
        NSApp.activate(ignoringOtherApps: true)
        openSettingsAction?()
    }
}
