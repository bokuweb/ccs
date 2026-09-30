import AppKit
import Combine
import ServiceManagement
import SwiftUI

private enum MiniStyle {
    static let accent = Color(red: 0.34, green: 0.64, blue: 1.0)
    static let active = Color(red: 0.38, green: 0.84, blue: 0.59)
    static let panelTop = Color(red: 0.17, green: 0.18, blue: 0.20)
    static let panelBottom = Color(red: 0.13, green: 0.14, blue: 0.16)
}

// Match the full app's menu bar ghost.
private enum MiniMenuBarIcon {
    static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let ghost = NSBezierPath()
            ghost.move(to: NSPoint(x: 4, y: 8))
            ghost.curve(to: NSPoint(x: 10, y: 1), controlPoint1: NSPoint(x: 4, y: 3.5), controlPoint2: NSPoint(x: 6.4, y: 1))
            ghost.curve(to: NSPoint(x: 16, y: 8), controlPoint1: NSPoint(x: 13.6, y: 1), controlPoint2: NSPoint(x: 16, y: 3.5))
            ghost.line(to: NSPoint(x: 16, y: 16))
            ghost.curve(to: NSPoint(x: 14.8, y: 16.7), controlPoint1: NSPoint(x: 16, y: 16.9), controlPoint2: NSPoint(x: 15.5, y: 17.1))
            ghost.line(to: NSPoint(x: 10.5, y: 14.5))
            ghost.curve(to: NSPoint(x: 9.5, y: 14.5), controlPoint1: NSPoint(x: 10.2, y: 14.3), controlPoint2: NSPoint(x: 9.8, y: 14.3))
            ghost.line(to: NSPoint(x: 5.2, y: 16.7))
            ghost.curve(to: NSPoint(x: 4, y: 16), controlPoint1: NSPoint(x: 4.5, y: 17.1), controlPoint2: NSPoint(x: 4, y: 16.9))
            ghost.line(to: NSPoint(x: 4, y: 11.5))
            ghost.curve(to: NSPoint(x: 2, y: 9), controlPoint1: NSPoint(x: 2.5, y: 11), controlPoint2: NSPoint(x: 1.8, y: 10))
            ghost.curve(to: NSPoint(x: 3.2, y: 8.6), controlPoint1: NSPoint(x: 2, y: 8.2), controlPoint2: NSPoint(x: 2.7, y: 8.1))
            ghost.curve(to: NSPoint(x: 4, y: 9), controlPoint1: NSPoint(x: 3.5, y: 8.9), controlPoint2: NSPoint(x: 3.8, y: 9))
            ghost.close()
            ghost.windingRule = .evenOdd
            ghost.appendOval(in: NSRect(x: 6.6, y: 6.5, width: 1.8, height: 1.8))
            ghost.appendOval(in: NSRect(x: 11.6, y: 6.5, width: 1.8, height: 1.8))
            ghost.move(to: NSPoint(x: 9, y: 8.8))
            ghost.curve(to: NSPoint(x: 11, y: 8.8), controlPoint1: NSPoint(x: 9.6, y: 9), controlPoint2: NSPoint(x: 10.4, y: 9))
            ghost.curve(to: NSPoint(x: 9, y: 8.8), controlPoint1: NSPoint(x: 11, y: 10.2), controlPoint2: NSPoint(x: 9, y: 10.2))
            ghost.close()
            NSColor.black.setFill()
            ghost.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ccs mini"
        return image
    }
}

private struct UsageRing: View {
    let window: UsageWindow
    @State private var displayedUsage = 0.0

    private var ringColor: Color {
        if window.used >= 85 { return Color(red: 1.0, green: 0.39, blue: 0.39) }
        if window.used >= 60 { return Color(red: 1.0, green: 0.69, blue: 0.32) }
        return MiniStyle.accent
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(.white.opacity(0.10), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: displayedUsage / 100)
                    .stroke(AngularGradient(colors: [ringColor.opacity(0.65), ringColor], center: .center,
                                            startAngle: .degrees(-90), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(displayedUsage.rounded()))%")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 33, height: 33)
            Text(window.label == "5 hours" ? "5h" : window.label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .frame(width: 43)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label), \(Int(window.used.rounded())) percent used")
        .help(window.reset.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "\(window.label) usage")
        .onAppear { withAnimation(.easeOut(duration: 0.7)) { displayedUsage = window.used } }
        .onChange(of: window.used) { _, value in
            withAnimation(.easeOut(duration: 0.7)) { displayedUsage = value }
        }
    }
}

private struct MiniAccountRow: View {
    @ObservedObject var model: AccountsModel
    let account: SavedAccount

    private var isActive: Bool { model.active[account.provider] == account.id }
    private var activeLabel: String {
        account.provider == .codex ? "CLI active" : (model.desktopActive == account.id ? "Code + Desktop active" : "Code active")
    }
    private var usageStatus: String {
        guard let error = model.usage[account.id]?.error else { return "No usage" }
        if error.contains("HTTP 429") { return "Rate limited" }
        if error.contains("Sign in again") { return "Sign in again" }
        return "Unavailable"
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(account.name)
                HStack(spacing: 5) {
                    if isActive {
                        Circle().fill(MiniStyle.active).frame(width: 6, height: 6)
                        Text(activeLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(MiniStyle.active)
                    }
                    Group {
                        Button(isActive ? (account.provider == .codex ? "Restart Desktop" : "Switch Desktop") : "Switch") { model.activate(account, refreshUsage: false) }
                            .font(.system(size: 10, weight: .medium))
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.07), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.13), lineWidth: 0.5))
                            .disabled(model.switchingCodex || model.switchingClaude)
                            .contextMenu {
                                if account.provider == .claude { Button("Reconnect Desktop…") { model.reconnectClaudeDesktop(account) } }
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.loadingUsage.contains(account.id) {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(MiniStyle.accent)
                    Text("Loading…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Loading usage for \(account.name)")
            } else if let usage = model.usage[account.id], !usage.windows.isEmpty {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(usage.windows) { window in UsageRing(window: window) }
                    if let error = usage.error { warning(error) }
                }
            } else {
                HStack(spacing: 4) {
                    if let error = model.usage[account.id]?.error { warning(error) }
                    Text(usageStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 59)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [.white.opacity(isActive ? 0.085 : 0.065),
                                              .white.opacity(0.035)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.white.opacity(isActive ? 0.12 : 0.07), lineWidth: 0.5)
                }
        }
    }

    private func warning(_ error: String) -> some View {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 10))
            .foregroundStyle(.orange)
            .help(error)
    }
}

private struct MiniView: View {
    @ObservedObject var accounts: AccountsModel

    static let width: CGFloat = 310

    static func height(for accounts: AccountsModel) -> CGFloat {
        let rowCount = max(2, accounts.accounts.count)
        let rowGaps = max(0, accounts.accounts.count - 2)
        let messageHeight: CGFloat = accounts.signingIn != nil || !accounts.message.isEmpty ? 38 : 0
        return min(500, CGFloat(16 + 46 + 10 + rowCount * 59 + rowGaps * 5) + messageHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(AccountProvider.allCases) { provider in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Capsule()
                                    .fill(MiniStyle.accent.opacity(0.85))
                                    .frame(width: 2, height: 10)
                                Text(provider.rawValue)
                                    .font(.system(size: 11, weight: .semibold))
                                    .tracking(0.2)
                                    .foregroundStyle(.white.opacity(0.74))
                                Spacer()
                                Menu {
                                    Button("Import current login") { accounts.importCurrent(provider) }
                                    Button("Add account…") { accounts.add(provider) }
                                        .disabled(accounts.signingIn != nil)
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 11, weight: .semibold))
                                        .frame(width: 18, height: 18)
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("Add or import \(provider.rawValue) account")
                                .disabled(accounts.switchingClaude || accounts.switchingCodex)
                            }
                            .frame(height: 18)
                            let saved = accounts.accounts.filter { $0.provider == provider }
                            if saved.isEmpty {
                                Text("No saved accounts")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(height: 59)
                            } else {
                                VStack(spacing: 5) {
                                    ForEach(saved) { account in
                                        MiniAccountRow(model: accounts, account: account)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(8)
            }

            if accounts.signingIn != nil || !accounts.message.isEmpty {
                HStack(spacing: 7) {
                    if accounts.signingIn != nil { ProgressView().controlSize(.mini) }
                    Text(accounts.message.isEmpty ? "Waiting for sign-in…" : accounts.message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(accounts.message)
                    Spacer(minLength: 0)
                    if accounts.switchingClaude { Button("Cancel") { accounts.cancelDesktopSwitch() }.font(.system(size: 10)) }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
            }
        }
        .frame(width: Self.width, height: Self.height(for: accounts))
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [MiniStyle.panelTop, MiniStyle.panelBottom],
                                     startPoint: .top, endPoint: .bottom))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.20), lineWidth: 0.75))
        .preferredColorScheme(.dark)
    }
}

private final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor private final class MiniDelegate: NSObject, NSApplicationDelegate {
    private let loginItemConfiguredKey = "miniLaunchAtLoginConfigured"
    private var status: NSStatusItem!
    private var panel: MiniPanel!
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var modelSubscription: AnyCancellable?
    private let accounts = AccountsModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureLoginItemOnFirstLaunch()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = MiniMenuBarIcon.makeImage()
        status.button?.toolTip = "ccs mini: usage and accounts"
        status.button?.target = self
        status.button?.action = #selector(toggle)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        panel = MiniPanel(contentRect: NSRect(x: 0, y: 0, width: MiniView.width, height: MiniView.height(for: accounts)),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.title = "ccs mini"
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: MiniView(accounts: accounts))
        modelSubscription = accounts.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizePanel() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard panel != nil else { return true }
        sender.activate(ignoringOtherApps: true)
        showPanel()
        return false
    }

    @objc private func toggle() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            hidePanel()
            let menu = NSMenu()
            let serviceStatus = SMAppService.mainApp.status
            let loginItem = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            loginItem.target = self
            loginItem.state = serviceStatus == .enabled || serviceStatus == .requiresApproval ? .on : .off
            loginItem.isEnabled = !isRunningFromDiskImage
            if serviceStatus == .requiresApproval {
                menu.addItem(withTitle: "Allow in System Settings…", action: #selector(openLoginItemSettings), keyEquivalent: "").target = self
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit ccs mini", action: #selector(quit), keyEquivalent: "q").target = self
            if let button = status.button { menu.popUp(positioning: nil, at: .zero, in: button) }
            return
        }
        if panel.isVisible {
            hidePanel()
            return
        }
        showPanel()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private var isRunningFromDiskImage: Bool {
        (try? Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    }

    private func configureLoginItemOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: loginItemConfiguredKey), !isRunningFromDiskImage else { return }
        let service = SMAppService.mainApp
        guard service.status != .notFound else { return }
        if service.status == .notRegistered {
            do { try service.register() }
            catch {
                NSLog("ccs mini: Could not enable Launch at Login: %@", error.localizedDescription)
                return
            }
        }
        defaults.set(true, forKey: loginItemConfiguredKey)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            } else {
                try service.register()
            }
            UserDefaults.standard.set(true, forKey: loginItemConfiguredKey)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func showPanel() {
        // Reopening an already visible panel must not install duplicate event monitors.
        hidePanel()
        // Pick up accounts added or removed by the full ccs app since the last open.
        do { accounts.accounts = try accounts.repository.load() }
        catch { accounts.message = "Cannot load saved accounts: \(error.localizedDescription)" }
        accounts.refresh(forceUsage: true)
        resizePanel()
        if let button = status.button, let buttonWindow = button.window,
           let screen = buttonWindow.screen {
            let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let visible = screen.visibleFrame.insetBy(dx: 4, dy: 4)
            let x = max(visible.minX, min(buttonRect.midX - panel.frame.width / 2, visible.maxX - panel.frame.width))
            let y = max(visible.minY, min(buttonRect.minY - panel.frame.height - 4, visible.maxY - panel.frame.height))
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            // A menu bar item can be unavailable when the menu bar has no room.
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.hidePanel() }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.hidePanel()
            return nil
        }
    }

    private func resizePanel() {
        guard panel != nil else { return }
        let height = MiniView.height(for: accounts)
        guard panel.frame.height != height else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: panel.isVisible)
    }

    private func hidePanel() {
        panel.orderOut(nil)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}

@main @MainActor private struct MiniMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = MiniDelegate()
        app.delegate = delegate
        app.run()
    }
}
