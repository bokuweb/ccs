import AppKit
import SwiftUI
import Carbon
import ServiceManagement

struct AppShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String
    static let standard = AppShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey), key: "Space")
    var label: String {
        (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") +
        (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") +
        (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") +
        (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + key
    }
    static func from(_ event: NSEvent) -> AppShortcut? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let special: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        guard let key = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
        return AppShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key)
    }
}
@MainActor final class SettingsModel: ObservableObject {
    @Published var shortcut: AppShortcut
    @Published var recording = false
    @Published var error = ""
    @Published var launchAtLogin = false
    @Published var loginItemMessage = ""
    var register: ((AppShortcut) -> Bool)?
    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: "globalShortcut") ?? UserDefaults(suiteName: "local.sessionspot.app")?.data(forKey: "globalShortcut")
        shortcut = saved.flatMap { try? JSONDecoder().decode(AppShortcut.self, from: $0) } ?? .standard
        if defaults.data(forKey: "globalShortcut") == nil, let saved { defaults.set(saved, forKey: "globalShortcut") }
        refreshLoginItem()
    }
    func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginItemMessage = status == .requiresApproval ? "Allow ccs in System Settings → General → Login Items." : ""
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginItem()
        } catch {
            refreshLoginItem()
            loginItemMessage = error.localizedDescription
        }
    }
    func set(_ value: AppShortcut) {
        guard register?(value) == true else { error = "That shortcut could not be registered. Try a different combination."; return }
        shortcut = value
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: "globalShortcut")
        error = ""; recording = false
    }
}
struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var settings: SettingsModel
    final class Recorder: NSButton {
        var settings: SettingsModel?
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) {
            settings?.recording = true; settings?.error = ""; window?.makeFirstResponder(self)
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard settings?.recording == true else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event); return true
        }
        override func keyDown(with event: NSEvent) {
            guard let settings, settings.recording else { super.keyDown(with: event); return }
            if event.keyCode == kVK_Escape { settings.recording = false; return }
            guard let shortcut = AppShortcut.from(event) else { settings.error = "Include Command, Option, or Control."; return }
            settings.set(shortcut)
        }
        override func resignFirstResponder() -> Bool { settings?.recording = false; return super.resignFirstResponder() }
    }
    func makeNSView(context: Context) -> Recorder {
        let button = Recorder(); button.settings = settings; button.isBordered = false
        button.alignment = .center
        button.focusRingType = .none
        button.font = .systemFont(ofSize: 17, weight: .medium)
        button.setAccessibilityLabel("ccs global shortcut")
        return button
    }
    func updateNSView(_ button: Recorder, context: Context) { button.title = settings.recording ? "Press shortcut…" : settings.shortcut.label }
}
struct SettingsView: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var accounts: AccountsModel
    @ObservedObject var search: Model
    @State var tab: Int
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                tabButton("General", icon: "gearshape", value: 0)
                tabButton("Accounts", icon: "person.crop.circle", value: 1)
            }.padding(14).frame(maxWidth: .infinity)
            Divider()
            if tab == 0 {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 22) {
                        Text("ccs Hotkey").foregroundStyle(.secondary).frame(width: 140, alignment: .trailing)
                        ShortcutRecorder(settings: settings)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(width: 250, height: 44)
                            .background(Color.white.opacity(settings.recording ? 0.18 : 0.09), in: RoundedRectangle(cornerRadius: 8))
                    }
                    HStack {
                        Spacer().frame(width: 162)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Click to record a shortcut. Press Esc to cancel.").foregroundStyle(.secondary)
                            Button("Restore default (⌘⇧Space)") { settings.set(.standard) }
                            if !settings.error.isEmpty { Text(settings.error).foregroundStyle(.orange) }
                        }
                    }
                    HStack(spacing: 22) {
                        Text("Startup").foregroundStyle(.secondary).frame(width: 140, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Launch ccs at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                            if !settings.loginItemMessage.isEmpty { Text(settings.loginItemMessage).foregroundStyle(.orange) }
                        }
                    }
                    HStack(spacing: 22) {
                        Text("Search").foregroundStyle(.secondary).frame(width: 140, alignment: .trailing)
                        Toggle("Include archived sessions", isOn: $search.includeArchived)
                    }
                    Spacer()
                }.font(.system(size: 12)).padding(.top, 42).padding(.horizontal, 24)
            } else { AccountsView(model: accounts) }
        }
        .frame(width: 600, height: 470)
        .background(Color(red: 0.105, green: 0.106, blue: 0.115))
        .preferredColorScheme(.dark)
    }
    func tabButton(_ label: String, icon: String, value: Int) -> some View {
        Button { tab = value; settings.recording = false } label: {
            VStack(spacing: 5) { Image(systemName: icon).font(.system(size: 22)); Text(label).font(.system(size: 12, weight: .medium)) }
                .frame(width: 90, height: 55)
                .background(tab == value ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).foregroundStyle(tab == value ? .white : .gray)
    }
}
