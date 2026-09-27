import AppKit
import SwiftUI
import Security
import CryptoKit

// Credentials never enter UserDefaults or the account metadata file.
protocol CredentialVault {
    func read(_ service: String, _ account: String) throws -> Data?
    func write(_ data: Data, _ service: String, _ account: String) throws
    func remove(_ service: String, _ account: String) throws
}
struct KeychainVault: CredentialVault {
    func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        var signatureStatus = errSecSuccess
        if status == errSecAuthFailed {
            var code: SecCode?
            signatureStatus = SecCodeCopySelf([], &code)
            if signatureStatus == errSecSuccess, let code {
                signatureStatus = SecCodeCheckValidity(code, [], nil)
            }
        }
        throw AccountError.message(Self.errorMessage(status, signatureStatus: signatureStatus))
    }
    static func errorMessage(_ status: OSStatus, signatureStatus: OSStatus = errSecSuccess) -> String {
        if status == errSecAuthFailed && signatureStatus != errSecSuccess {
            return "ccs was updated while running or its signature is invalid. Quit and reopen ccs, then refresh Accounts. If this persists, rebuild after quitting ccs. Saved accounts have not been removed."
        }
        switch status {
        case errSecAuthFailed:
            return "Keychain access was denied. Allow ccs access if macOS asks, then refresh Accounts. If no prompt appears, quit and reopen ccs and check that the login keychain is unlocked in Keychain Access."
        case errSecUserCanceled:
            return "Keychain access was canceled. Refresh Accounts to try again."
        case errSecInteractionNotAllowed:
            return "Keychain interaction is unavailable. Unlock your Mac and the login keychain, then refresh Accounts."
        default:
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain error (\(status)): \(detail)"
        }
    }
    func read(_ service: String, _ account: String) throws -> Data? {
        var q = query(service, account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return result as? Data
    }
    func write(_ data: Data, _ service: String, _ account: String) throws {
        let q = query(service, account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var new = q; new[kSecValueData as String] = data
            new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(new as CFDictionary, nil))
        } else { try check(status) }
    }
    func remove(_ service: String, _ account: String) throws {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}
enum AccountError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
enum AccountProvider: String, Codable, CaseIterable, Identifiable {
    case codex = "Codex", claude = "Claude"
    var id: String { rawValue }
    var command: String { rawValue.lowercased() }
}
struct SavedAccount: Codable, Identifiable {
    var id: String
    var provider: AccountProvider
    var identity: String
    var name: String
}
struct AccountSecret: Codable {
    var credentials: Data
    var profile: Data?
}
struct UsageWindow: Identifiable {
    var label: String
    var used: Double
    var reset: Date?
    var id: String { label }
}
struct AccountUsage {
    var windows: [UsageWindow] = []
    var updated: Date?
    var error: String?
}

final class AccountRepository {
    let home: URL
    let root: URL
    let vault: CredentialVault
    let service = "ccs Accounts"
    let legacyService = "SessionSpot Accounts"
    var user: String {
        let name = NSUserName()
        return name.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil ? name : "claude-code-user"
    }
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, root: URL? = nil, vault: CredentialVault = KeychainVault()) {
        self.home = home
        self.root = root ?? home.appendingPathComponent("Library/Application Support/ccs/accounts")
        self.vault = vault
        if root == nil && !FileManager.default.fileExists(atPath: self.root.path) {
            let legacy = home.appendingPathComponent("Library/Application Support/SessionSpot/accounts")
            if FileManager.default.fileExists(atPath: legacy.path) {
                try? FileManager.default.createDirectory(at: self.root.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: legacy, to: self.root)
            }
        }
    }
    func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AccountError.message("Invalid account data.") }
        return result
    }
    func encode(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    func secureWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Set permissions on the temporary inode before it becomes visible at the destination.
        let temp = url.deletingLastPathComponent().appendingPathComponent(".ccs-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw AccountError.message("Cannot write account data.") }
        defer { try? FileManager.default.removeItem(at: temp) }
        guard rename(temp.path, url.path) == 0 else { throw AccountError.message("Cannot replace account data (\(errno)).") }
    }
    func load() throws -> [SavedAccount] {
        let file = root.appendingPathComponent("accounts.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([SavedAccount].self, from: Data(contentsOf: file))
    }
    func save(_ accounts: [SavedAccount]) throws { try secureWrite(JSONEncoder().encode(accounts), to: root.appendingPathComponent("accounts.json")) }
    func secret(_ account: SavedAccount) throws -> AccountSecret {
        guard let data = try vault.read(service, account.id) ?? vault.read(legacyService, account.id) else { throw AccountError.message("Saved credentials are missing. Sign in again.") }
        return try JSONDecoder().decode(AccountSecret.self, from: data)
    }
    func jwt(_ value: String?) -> [String: Any] {
        guard let part = value?.split(separator: ".").dropFirst().first else { return [:] }
        var base = String(part).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        guard let data = Data(base64Encoded: base) else { return [:] }
        return (try? object(data)) ?? [:]
    }
    func identity(_ secret: AccountSecret, provider: AccountProvider) throws -> (String, String) {
        let auth = try object(secret.credentials)
        if provider == .codex {
            guard let tokens = auth["tokens"] as? [String: Any], let access = tokens["access_token"] as? String, !access.isEmpty else { throw AccountError.message("Sign in with a ChatGPT account. API-key accounts do not expose subscription usage.") }
            let claims = jwt(tokens["id_token"] as? String)
            let accessClaims = jwt(access)
            let scoped = (claims["https://api.openai.com/auth"] as? [String: Any]) ?? [:]
            guard let account = tokens["account_id"] as? String ?? scoped["chatgpt_account_id"] as? String,
                  let subject = claims["sub"] as? String ?? accessClaims["sub"] as? String else { throw AccountError.message("Cannot identify this Codex account. Sign in again.") }
            return ("\(subject):\(account)", claims["email"] as? String ?? "Codex · \(account.prefix(8))")
        }
        guard let oauth = auth["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String, !token.isEmpty else { throw AccountError.message("Claude subscription credentials were not found. Run claude auth login first.") }
        let profile = try secret.profile.map(object) ?? [:]
        guard let uuid = profile["accountUuid"] as? String ?? profile["emailAddress"] as? String else { throw AccountError.message("Claude account identity is missing. Complete sign-in and retry.") }
        let org = profile["organizationUuid"] as? String ?? ""
        return ("\(uuid):\(org)", profile["emailAddress"] as? String ?? "Claude · \(uuid.prefix(8))")
    }
    func claudeService(directory: URL?) -> String {
        guard let directory else { return "Claude Code-credentials" }
        let path = directory.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hash.prefix(8))"
    }
    static func claudeLoggedIn() throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "claude auth status"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 127 { throw AccountError.message("Claude CLI was not found. Install Claude Code before importing an account.") }
        guard let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = status["loggedIn"] as? Bool else {
            throw AccountError.message("Could not check Claude sign-in. Run claude auth status in Terminal.")
        }
        return loggedIn
    }
    func capture(_ provider: AccountProvider, directory: URL? = nil) throws -> AccountSecret? {
        if provider == .codex {
            let dir = directory ?? home.appendingPathComponent(".codex")
            let config = (try? String(contentsOf: dir.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
            if directory == nil && config.range(of: #"(?m)^\s*cli_auth_credentials_store\s*=\s*["'](?:keyring|auto)["']"#, options: .regularExpression) != nil {
                throw AccountError.message("Codex uses Keychain authentication. Set cli_auth_credentials_store = \"file\" in ~/.codex/config.toml and sign in before importing or switching.")
            }
            let file = dir.appendingPathComponent("auth.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return AccountSecret(credentials: try Data(contentsOf: file))
        }
        let dir = directory ?? home.appendingPathComponent(".claude")
        let credentials = try vault.read(claudeService(directory: directory), user)
        let fallback = dir.appendingPathComponent(".credentials.json")
        guard let data = try credentials ?? (FileManager.default.fileExists(atPath: fallback.path) ? Data(contentsOf: fallback) : nil) else { return nil }
        let profileURL = directory == nil ? home.appendingPathComponent(".claude.json") : dir.appendingPathComponent(".claude.json")
        let config = try object(Data(contentsOf: profileURL))
        return AccountSecret(credentials: data, profile: try (config["oauthAccount"] as? [String: Any]).map(encode))
    }
    @discardableResult func store(_ secret: AccountSecret, provider: AccountProvider, accounts: inout [SavedAccount]) throws -> SavedAccount {
        let (identity, name) = try identity(secret, provider: provider)
        let account = accounts.first { $0.provider == provider && $0.identity == identity } ?? SavedAccount(id: UUID().uuidString, provider: provider, identity: identity, name: name)
        try vault.write(JSONEncoder().encode(secret), service, account.id)
        if !accounts.contains(where: { $0.id == account.id }) { accounts.append(account) }
        try save(accounts)
        return account
    }
    func activate(_ account: SavedAccount, accounts: inout [SavedAccount]) throws {
        let target = try secret(account)
        guard try identity(target, provider: account.provider).0 == account.identity else { throw AccountError.message("Account identity mismatch. Sign in again.") }
        // Save the outgoing account, including rotated tokens, before replacing anything.
        if let current = try capture(account.provider) { try store(current, provider: account.provider, accounts: &accounts) }
        if account.provider == .codex {
            try secureWrite(target.credentials, to: home.appendingPathComponent(".codex/auth.json"))
        } else {
            let profileURL = home.appendingPathComponent(".claude.json")
            let oldProfile = try? Data(contentsOf: profileURL)
            var config = try oldProfile.map(object) ?? [:]
            config["oauthAccount"] = try target.profile.map(object)
            let old = try vault.read(claudeService(directory: nil), user)
            let fallback = home.appendingPathComponent(".claude/.credentials.json")
            let oldFallback = FileManager.default.fileExists(atPath: fallback.path) ? try Data(contentsOf: fallback) : nil
            try vault.write(target.credentials, claudeService(directory: nil), user)
            do {
                if oldFallback != nil { try secureWrite(target.credentials, to: fallback) }
                try secureWrite(encode(config), to: profileURL)
            } catch {
                do {
                    if let old { try vault.write(old, claudeService(directory: nil), user) }
                    else { try vault.remove(claudeService(directory: nil), user) }
                    if let oldFallback { try secureWrite(oldFallback, to: fallback) }
                } catch { throw AccountError.message("Switch failed and rollback failed. Saved accounts are intact; sign in again before continuing.") }
                throw error
            }
        }
    }
    static func parseUsage(_ json: [String: Any], provider: AccountProvider) -> [UsageWindow] {
        let container = provider == .codex ? (json["rate_limit"] as? [String: Any] ?? [:]) : json
        let keys = provider == .codex ? ["primary_window", "secondary_window"] : ["five_hour", "seven_day"]
        return keys.enumerated().compactMap { index, key in
            guard let value = container[key] as? [String: Any], let used = (value[provider == .codex ? "used_percent" : "utilization"] as? NSNumber)?.doubleValue, used.isFinite else { return nil }
            let reset: Date?
            if let seconds = value["reset_at"] as? Double { reset = Date(timeIntervalSince1970: seconds) }
            else if let text = value["resets_at"] as? String {
                let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds)
                reset = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            } else { reset = nil }
            let seconds = (value["limit_window_seconds"] as? Int) ?? (index == 0 ? 18000 : 604800)
            let label = seconds == 18000 ? "5 hours" : seconds == 604800 ? "Weekly" : "\(seconds / 3600) hours"
            return UsageWindow(label: label, used: min(100, max(0, used)), reset: reset)
        }
    }
    func usage(_ account: SavedAccount) async throws -> AccountUsage {
        let auth = try object(secret(account).credentials)
        let codex = account.provider == .codex
        let tokens = auth[codex ? "tokens" : "claudeAiOauth"] as? [String: Any] ?? [:]
        guard let access = tokens[codex ? "access_token" : "accessToken"] as? String else { throw AccountError.message("Sign in again to load usage.") }
        var request = URLRequest(url: URL(string: codex ? "https://chatgpt.com/backend-api/wham/usage" : "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if codex {
            request.setValue(tokens["account_id"] as? String, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
            request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        } else {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AccountError.message(code == 401 || code == 403 ? "Sign in again to refresh usage." : "Usage unavailable (HTTP \(code)). Retry later.") }
        let windows = Self.parseUsage(try object(data), provider: account.provider)
        guard !windows.isEmpty else { throw AccountError.message("Usage limits are not available for this account.") }
        return AccountUsage(windows: windows, updated: Date())
    }
}

@MainActor final class AccountsModel: ObservableObject {
    @Published var accounts: [SavedAccount] = []
    @Published var active: [AccountProvider: String] = [:]
    @Published var usage: [String: AccountUsage] = [:]
    @Published var message = ""
    @Published var refreshing = false
    @Published var signingIn: AccountProvider?
    let repository: AccountRepository
    private var loginTask: Task<Void, Never>?
    init(repository: AccountRepository = AccountRepository()) {
        self.repository = repository
        do { accounts = try repository.load() } catch { message = "Cannot load saved accounts: \(error.localizedDescription)" }
    }
    func syncActive() throws {
        for provider in AccountProvider.allCases {
            if let current = try repository.capture(provider) {
                let identity = try repository.identity(current, provider: provider).0
                if let saved = accounts.first(where: { $0.provider == provider && $0.identity == identity }) {
                    try repository.store(current, provider: provider, accounts: &accounts)
                    active[provider] = saved.id
                } else { active[provider] = nil }
            } else { active[provider] = nil }
        }
    }
    func importCurrent(_ provider: AccountProvider) {
        if provider == .claude {
            Task {
                do {
                    let loggedIn = try await Task.detached { try AccountRepository.claudeLoggedIn() }.value
                    if loggedIn { importCapturedCurrent(provider) }
                    else { signInCurrentClaude() }
                } catch { message = error.localizedDescription }
            }
            return
        }
        importCapturedCurrent(provider)
    }
    private func importCapturedCurrent(_ provider: AccountProvider) {
        do {
            guard let secret = try repository.capture(provider) else { throw AccountError.message("No \(provider.rawValue) login found. Use Add account to sign in.") }
            let account = try repository.store(secret, provider: provider, accounts: &accounts)
            active[provider] = account.id
            message = "Imported \(account.name)."
            refresh()
        } catch { message = error.localizedDescription }
    }
    private func signInCurrentClaude() {
        guard signingIn == nil else { return }
        do {
            let directory = repository.root.appendingPathComponent("login-current-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let script = directory.appendingPathComponent("sign-in.command")
            let text = "#!/bin/zsh -l\nunset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR\nclaude auth login\nresult=$?\nif [ $result -eq 0 ]; then touch \(quote(directory.appendingPathComponent("complete").path)); else touch \(quote(directory.appendingPathComponent("failed").path)); fi\nexit $result\n"
            try repository.secureWrite(Data(text.utf8), to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            guard NSWorkspace.shared.open(script) else { throw AccountError.message("Could not open Terminal for Claude sign-in.") }
            signingIn = .claude
            message = "Claude Code is signed out. Complete claude auth login in Terminal and your browser; ccs will import it automatically."
            loginTask = Task {
                defer {
                    try? FileManager.default.removeItem(at: directory)
                    signingIn = nil
                }
                for _ in 0..<300 {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("failed").path) {
                        message = "Claude sign-in failed. Run claude auth login in Terminal and retry Import current."; return
                    }
                    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("complete").path) {
                        importCapturedCurrent(.claude)
                        return
                    }
                }
                message = "Claude sign-in timed out. Run claude auth login in Terminal and retry Import current."
            }
        } catch { message = error.localizedDescription }
    }
    func activate(_ account: SavedAccount) {
        do {
            try repository.activate(account, accounts: &accounts)
            active[account.provider] = account.id
            message = "Switched to \(account.name). New CLI sessions use this account. Restart existing clients to reload credentials."
            refresh()
        } catch { message = error.localizedDescription }
    }
    func remove(_ account: SavedAccount) {
        do {
            let remaining = accounts.filter { $0.id != account.id }
            try repository.save(remaining)
            try repository.vault.remove(repository.service, account.id)
            try repository.vault.remove(repository.legacyService, account.id)
            accounts = remaining; usage[account.id] = nil
            if active[account.provider] == account.id { active[account.provider] = nil }
            message = "Removed saved account. The CLI remains signed in."
        } catch { message = error.localizedDescription }
    }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            // A missing login for one provider must not hide the other provider's usage.
            for provider in AccountProvider.allCases where accounts.contains(where: { $0.provider == provider }) {
                do {
                    if let current = try repository.capture(provider) {
                        let identity = try repository.identity(current, provider: provider).0
                        if let saved = accounts.first(where: { $0.provider == provider && $0.identity == identity }) {
                            try repository.store(current, provider: provider, accounts: &accounts)
                            active[provider] = saved.id
                        } else { active[provider] = nil }
                    } else { active[provider] = nil }
                } catch { active[provider] = nil }
            }
            for account in accounts {
                do { usage[account.id] = try await repository.usage(account) }
                catch {
                    var old = usage[account.id] ?? AccountUsage()
                    old.error = error.localizedDescription; usage[account.id] = old
                }
            }
        }
    }
    func add(_ provider: AccountProvider) {
        guard signingIn == nil else { return }
        do {
            let directory = repository.root.appendingPathComponent("login-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if provider == .codex { try repository.secureWrite(Data("cli_auth_credentials_store = \"file\"\n".utf8), to: directory.appendingPathComponent("config.toml")) }
            func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let script = directory.appendingPathComponent("sign-in.command")
            let env = provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
            let command = provider == .codex ? "codex login" : "claude auth login"
            let text = "#!/bin/zsh -l\nunset OPENAI_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN\nexport \(env)=\(quote(directory.path))\n\(command)\nresult=$?\nif [ $result -eq 0 ]; then touch \(quote(directory.appendingPathComponent("complete").path)); else touch \(quote(directory.appendingPathComponent("failed").path)); fi\nexit $result\n"
            try repository.secureWrite(Data(text.utf8), to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            guard NSWorkspace.shared.open(script) else { throw AccountError.message("Could not open Terminal for sign-in.") }
            signingIn = provider; message = "Complete \(provider.rawValue) sign-in in Terminal and your browser. Your current account stays active."
            loginTask = Task {
                defer {
                    try? repository.vault.remove(repository.claudeService(directory: directory), repository.user)
                    try? FileManager.default.removeItem(at: directory)
                    signingIn = nil
                }
                for _ in 0..<300 {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("failed").path) {
                        message = "Sign-in failed. Check Terminal, verify the CLI is installed, and retry."; return
                    }
                    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("complete").path) {
                        do {
                            guard let secret = try repository.capture(provider, directory: directory) else { throw AccountError.message("Sign-in finished without credentials.") }
                            let account = try repository.store(secret, provider: provider, accounts: &accounts)
                            message = "Added \(account.name). Click Switch to use it."
                            refresh()
                        } catch { message = error.localizedDescription }
                        return
                    }
                }
                message = "Sign-in timed out. Close the sign-in Terminal and retry."
            }
        } catch { message = error.localizedDescription }
    }
}

struct AccountsView: View {
    @ObservedObject var model: AccountsModel
    @State private var removing: SavedAccount?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Accounts").font(.system(size: 18, weight: .semibold))
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small) }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.disabled(model.refreshing)
            }
            Text("Manage Codex and Claude Code subscriptions. Switching applies to new CLI sessions; existing clients may need a restart. Claude Desktop login is separate.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(AccountProvider.allCases) { provider in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(provider.rawValue).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Button("Import current") { model.importCurrent(provider) }
                                Button("＋ Add account") { model.add(provider) }.disabled(model.signingIn != nil)
                            }
                            ForEach(model.accounts.filter { $0.provider == provider }) { account in
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack {
                                        Text(account.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Spacer()
                                        if model.active[provider] == account.id {
                                            Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                        } else { Button("Switch") { model.activate(account) } }
                                        Button { removing = account } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary)
                                    }
                                    if let usage = model.usage[account.id] {
                                        ForEach(usage.windows) { window in
                                            HStack(spacing: 10) {
                                                Text(window.label).frame(width: 48, alignment: .leading)
                                                ProgressView(value: window.used, total: 100).tint(window.used >= 90 ? .orange : .accentColor).frame(width: 110)
                                                Text("\(Int(window.used))% used").monospacedDigit()
                                                Spacer()
                                                if let reset = window.reset { Text("Resets \(reset, style: .relative)").foregroundStyle(.secondary) }
                                            }
                                        }
                                        if let error = usage.error { Text(error).foregroundStyle(.orange) }
                                        if let updated = usage.updated { Text("Updated \(updated, style: .relative) ago\(usage.error == nil ? "" : " · Stale")").foregroundStyle(.secondary) }
                                    } else { Text("Usage not loaded").foregroundStyle(.secondary) }
                                }
                                .padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                            }
                            if !model.accounts.contains(where: { $0.provider == provider }) {
                                Text("No saved accounts. Import the current login or add another account.").foregroundStyle(.secondary).padding(.vertical, 8)
                            }
                        }
                    }
                }
            }
            if model.signingIn != nil { ProgressView("Waiting for sign-in…").controlSize(.small) }
            if !model.message.isEmpty { Text(model.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .font(.system(size: 11)).padding(22)
        .onAppear { model.refresh() }
        .task { while !Task.isCancelled { do { try await Task.sleep(for: .seconds(60)) } catch { return }; model.refresh() } }
        .alert("Remove saved account?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let removing { model.remove(removing) }; removing = nil }
        } message: { Text("This removes the saved credentials from ccs. It does not sign the CLI out.") }
    }
}
