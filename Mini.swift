import AppKit
import SwiftUI

private struct MiniView: View {
    @ObservedObject var accounts: AccountsModel
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AccountsView(model: accounts)
            Divider()
            HStack {
                Text("ccs mini").foregroundStyle(.secondary)
                Spacer()
                Button("Quit ccs mini", action: quit)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
        }
        .frame(width: 600, height: 500)
        .background(Color(red: 0.105, green: 0.106, blue: 0.115))
        .preferredColorScheme(.dark)
    }
}

@MainActor private final class MiniDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let icon = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "ccs mini accounts") {
            icon.isTemplate = true
            status.button?.image = icon
        } else {
            status.button?.title = "ccs"
        }
        status.button?.toolTip = "ccs mini: usage and accounts"
        status.button?.target = self
        status.button?.action = #selector(toggle)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ccs mini"
        window.isReleasedWhenClosed = false
        // SecurityAgent can take focus while Keychain asks for access.
        window.level = .floating
        window.hidesOnDeactivate = false
    }

    @objc private func toggle() {
        if window.isVisible {
            window.orderOut(nil)
            return
        }
        // Reload saved accounts on every open so changes made by ccs are visible.
        let accounts = AccountsModel()
        window.contentView = NSHostingView(rootView: MiniView(accounts: accounts) { NSApp.terminate(nil) })
        if let button = status.button, let buttonWindow = button.window, let screen = buttonWindow.screen {
            let buttonFrame = buttonWindow.convertToScreen(button.frame)
            let visible = screen.visibleFrame
            let x = min(max(buttonFrame.midX - 300, visible.minX), visible.maxX - 600)
            window.setFrameTopLeftPoint(NSPoint(x: x, y: buttonFrame.minY - 8))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
