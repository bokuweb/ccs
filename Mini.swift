import AppKit
import SwiftUI

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

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: window.used / 100)
                    .stroke(window.used >= 90 ? .orange : .accentColor,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(window.used.rounded()))%")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 39, height: 39)
            Text(window.label == "5 hours" ? "5h" : window.label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(width: 51)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label), \(Int(window.used.rounded())) percent used")
        .help(window.reset.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "\(window.label) usage")
    }
}

private struct MiniAccountRow: View {
    @ObservedObject var model: AccountsModel
    let account: SavedAccount

    private var isActive: Bool { model.active[account.provider] == account.id }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(account.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(account.name)
                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                } else {
                    Button("Switch") { model.activate(account) }
                        .font(.system(size: 10, weight: .medium))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let usage = model.usage[account.id], !usage.windows.isEmpty {
                HStack(alignment: .top, spacing: 2) {
                    ForEach(usage.windows) { window in UsageRing(window: window) }
                }
            } else {
                Text(model.refreshing ? "Loading…" : "No usage")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .bottomLeading) {
            if let error = model.usage[account.id]?.error {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(error)
                    .offset(x: 3, y: 4)
            }
        }
    }
}

private struct MiniView: View {
    @ObservedObject var accounts: AccountsModel
    let quit: () -> Void

    private var popoverHeight: CGFloat {
        min(500, max(230, CGFloat(158 + accounts.accounts.count * 78 + (accounts.message.isEmpty ? 0 : 34))))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: MiniMenuBarIcon.makeImage())
                    .foregroundStyle(.tint)
                Text("ccs mini").font(.system(size: 14, weight: .semibold))
                Spacer()
                if accounts.refreshing { ProgressView().controlSize(.small) }
                Button { accounts.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .disabled(accounts.refreshing)
                    .help("Refresh usage")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(AccountProvider.allCases) { provider in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(provider.rawValue)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Menu {
                                    Button("Import current login") { accounts.importCurrent(provider) }
                                    Button("Add account…") { accounts.add(provider) }
                                        .disabled(accounts.signingIn != nil)
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 11, weight: .semibold))
                                        .frame(width: 20, height: 18)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Add or import \(provider.rawValue) account")
                            }
                            let saved = accounts.accounts.filter { $0.provider == provider }
                            if saved.isEmpty {
                                Text("No saved accounts")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 7)
                            } else {
                                ForEach(saved) { account in
                                    MiniAccountRow(model: accounts, account: account)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }

            if accounts.signingIn != nil || !accounts.message.isEmpty {
                Divider()
                HStack(spacing: 7) {
                    if accounts.signingIn != nil { ProgressView().controlSize(.mini) }
                    Text(accounts.message.isEmpty ? "Waiting for sign-in…" : accounts.message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(accounts.message)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Divider()
            HStack {
                Text("Usage used")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit ccs mini", action: quit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 354, height: popoverHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                accounts.refresh()
            }
        }
    }
}

@MainActor private final class MiniDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private var popover: NSPopover!
    private let accounts = AccountsModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = MiniMenuBarIcon.makeImage()
        status.button?.toolTip = "ccs mini: usage and accounts"
        status.button?.target = self
        status.button?.action = #selector(toggle)

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MiniView(accounts: accounts) { NSApp.terminate(nil) })
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = status.button {
            // Pick up accounts added or removed by the full ccs app since the last open.
            do { accounts.accounts = try accounts.repository.load() }
            catch { accounts.message = "Cannot load saved accounts: \(error.localizedDescription)" }
            accounts.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
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
