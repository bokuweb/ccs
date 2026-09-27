import Foundation
import Security

final class MemoryVault: CredentialVault {
    var values: [String: Data] = [:]
    var onWrite: ((String) throws -> Void)?
    func read(_ service: String, _ account: String) throws -> Data? { values[service + account] }
    func write(_ data: Data, _ service: String, _ account: String) throws { values[service + account] = data; try onWrite?(service) }
    func remove(_ service: String, _ account: String) throws { values[service + account] = nil }
}
final class UsageURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@main struct AccountsTests {
    static func main() async throws {
        assert(KeychainVault.errorMessage(errSecAuthFailed, signatureStatus: errSecCSStaticCodeChanged).contains("Quit and reopen"))
        assert(KeychainVault.errorMessage(errSecAuthFailed).contains("access was denied"))
        assert(KeychainVault.errorMessage(errSecUserCanceled).contains("canceled"))
        assert(KeychainVault.errorMessage(errSecInteractionNotAllowed).contains("Unlock"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = MemoryVault()
        let repository = AccountRepository(home: root, vault: vault)
        func codex(_ id: String, token: String = "access", refreshed: String = "") throws -> AccountSecret {
            let payload = try repository.encode(["sub": id, "email": "\(id)@example.com"]).base64EncodedString()
            return AccountSecret(credentials: try repository.encode(["last_refresh": refreshed, "tokens": ["id_token": "header.\(payload).sig", "account_id": id, "access_token": token]]))
        }
        var accounts: [SavedAccount] = []
        let first = try repository.store(codex("one"), provider: .codex, accounts: &accounts)
        let second = try repository.store(codex("two"), provider: .codex, accounts: &accounts)
        try repository.secureWrite(codex("one", token: "rotated").credentials, to: root.appendingPathComponent(".codex/auth.json"))
        try repository.activate(second, accounts: &accounts)
        let saved = try repository.object(repository.secret(first).credentials)
        assert((saved["tokens"] as? [String: String])?["access_token"] == "rotated", "outgoing refreshed credentials preserved")
        assert(tryIdentity(repository, .codex) == second.identity, "switch writes target identity")
        _ = try repository.store(codex("two", token: "new"), provider: .codex, accounts: &accounts)
        assert(accounts.count == 2, "reauth deduplicates")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(".codex/auth.json").path)
        assert((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try repository.activate(first, accounts: &accounts)
        let legacyDesktop = repository.root.appendingPathComponent("desktop/\(second.id)")
        let desktopAuth = legacyDesktop.appendingPathComponent("codex/auth.json")
        try repository.secureWrite(codex("two", token: "desktop-rotated", refreshed: "2026-09-28T01:00:00Z").credentials, to: desktopAuth)
        try repository.importLegacyDesktopCredentials(second)
        try repository.activate(second, accounts: &accounts)
        let switched = try repository.object(Data(contentsOf: root.appendingPathComponent(".codex/auth.json")))
        assert((switched["tokens"] as? [String: String])?["access_token"] == "desktop-rotated", "desktop refresh survives CLI switch")
        let launch = CodexDesktopLauncher.arguments(app: URL(fileURLWithPath: "/Applications/Codex.app"), home: root)
        assert(launch == ["--env", "CODEX_HOME=\(root.appendingPathComponent(".codex").path)", "/Applications/Codex.app"])
        try repository.secureWrite(codex("two", token: "shared-rotated", refreshed: "2026-09-28T02:00:00Z").credentials, to: root.appendingPathComponent(".codex/auth.json"))
        try repository.activate(second, accounts: &accounts)
        let sameAccount = try repository.object(Data(contentsOf: root.appendingPathComponent(".codex/auth.json")))
        assert((sameAccount["tokens"] as? [String: String])?["access_token"] == "shared-rotated", "same-account restart keeps refreshed token")
        let meta = try String(contentsOf: repository.root.appendingPathComponent("accounts.json"), encoding: .utf8)
        assert(!meta.contains("access_token") && !meta.contains("rotated"), "metadata contains no secrets")
        let invalid = SavedAccount(id: second.id, provider: .codex, identity: "wrong", name: "wrong")
        do { try repository.activate(invalid, accounts: &accounts); fatalError("mismatch accepted") } catch {}
        assert(tryIdentity(repository, .codex) == second.identity)
        try repository.secureWrite(Data("cli_auth_credentials_store = \"keyring\"".utf8), to: root.appendingPathComponent(".codex/config.toml"))
        do { try repository.activate(first, accounts: &accounts); fatalError("keyring unexpectedly overwritten") } catch {}
        func claude(_ id: String) throws -> AccountSecret {
            AccountSecret(credentials: try repository.encode(["claudeAiOauth": ["accessToken": id]]), profile: try repository.encode(["accountUuid": id, "emailAddress": "\(id)@example.com"]))
        }
        let claudeOne = try repository.store(claude("c1"), provider: .claude, accounts: &accounts)
        let claudeTwo = try repository.store(claude("c2"), provider: .claude, accounts: &accounts)
        try repository.activate(claudeOne, accounts: &accounts)
        var config = try repository.object(Data(contentsOf: root.appendingPathComponent(".claude.json")))
        config["unrelatedSetting"] = true
        try repository.secureWrite(repository.encode(config), to: root.appendingPathComponent(".claude.json"))
        try repository.secureWrite(claude("c1").credentials, to: root.appendingPathComponent(".claude/.credentials.json"))
        try repository.activate(claudeTwo, accounts: &accounts)
        assert(tryIdentity(repository, .claude) == claudeTwo.identity)
        let after = try repository.object(Data(contentsOf: root.appendingPathComponent(".claude.json")))
        assert(after["unrelatedSetting"] as? Bool == true)
        let fallback = try Data(contentsOf: root.appendingPathComponent(".claude/.credentials.json"))
        assert(fallback == claudeTwoSecret(repository, claudeTwo), "fallback and Keychain agree")
        let refreshedClaude = try repository.encode(["claudeAiOauth": ["accessToken": "rotated-c2"]])
        try vault.write(refreshedClaude, repository.claudeService(directory: nil), repository.user)
        try repository.secureWrite(refreshedClaude, to: root.appendingPathComponent(".claude/.credentials.json"))
        try repository.activate(claudeTwo, accounts: &accounts)
        assert(tryRead(vault, repository) == refreshedClaude, "same-account restart keeps refreshed Claude token")
        assert(claudeTwoSecret(repository, claudeTwo) == refreshedClaude, "refreshed Claude token is saved")
        // Fail the profile write after the Keychain change and verify rollback.
        vault.onWrite = { service in
            guard service == repository.claudeService(directory: nil) else { return }
            vault.onWrite = nil
            try FileManager.default.removeItem(at: root.appendingPathComponent(".claude.json"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude.json"), withIntermediateDirectories: false)
        }
        let oldKeychain = try vault.read(repository.claudeService(directory: nil), repository.user)
        do { try repository.activate(claudeOne, accounts: &accounts); fatalError("invalid profile accepted") } catch {}
        assert(tryRead(vault, repository) == oldKeychain)
        let restoredFallback = try Data(contentsOf: root.appendingPathComponent(".claude/.credentials.json"))
        assert(restoredFallback == refreshedClaude, "failed switch restores fallback credentials")
        try FileManager.default.removeItem(at: root.appendingPathComponent(".claude.json"))
        let desktopOneUUID = UUID().uuidString.lowercased()
        let desktopTwoUUID = UUID().uuidString.lowercased()
        let desktopOne = SavedAccount(id: UUID().uuidString, provider: .claude, identity: "\(desktopOneUUID):org", name: "first")
        let desktopTwo = SavedAccount(id: UUID().uuidString, provider: .claude, identity: "\(desktopTwoUUID):org", name: "second")
        let desktopProfiles = ClaudeDesktopProfiles(repository: repository)
        try repository.secureWrite(repository.encode(["lastKnownAccountUuid": desktopOneUUID]), to: desktopProfiles.desktop.appendingPathComponent("config.json"))
        try repository.secureWrite(Data("first-profile".utf8), to: desktopProfiles.desktop.appendingPathComponent("sentinel"))
        let needsSignIn = try desktopProfiles.select(desktopTwo, accounts: [desktopOne, desktopTwo])
        assert(!needsSignIn, "new Desktop login needs sign-in")
        assert(desktopProfiles.selectedID() == desktopTwo.id)
        let firstSaved = try String(contentsOf: desktopProfiles.profiles.appendingPathComponent("\(desktopOne.id)/sentinel"), encoding: .utf8)
        assert(firstSaved == "first-profile")
        try repository.secureWrite(repository.encode(["lastKnownAccountUuid": desktopTwoUUID]), to: desktopProfiles.desktop.appendingPathComponent("config.json"))
        try repository.secureWrite(Data("second-profile".utf8), to: desktopProfiles.desktop.appendingPathComponent("sentinel"))
        let restoredLogin = try desktopProfiles.select(desktopOne, accounts: [desktopOne, desktopTwo])
        assert(restoredLogin, "saved Desktop login is restored")
        assert(desktopProfiles.desktopUUID() == desktopOneUUID)
        let firstRestored = try String(contentsOf: desktopProfiles.desktop.appendingPathComponent("sentinel"), encoding: .utf8)
        let secondSaved = try String(contentsOf: desktopProfiles.profiles.appendingPathComponent("\(desktopTwo.id)/sentinel"), encoding: .utf8)
        assert(firstRestored == "first-profile" && secondSaved == "second-profile")
        let wrongUUID = UUID().uuidString.lowercased()
        try repository.secureWrite(repository.encode(["lastKnownAccountUuid": wrongUUID]), to: desktopProfiles.profiles.appendingPathComponent("\(desktopTwo.id)/config.json"))
        do { _ = try desktopProfiles.select(desktopTwo, accounts: [desktopOne, desktopTwo]); fatalError("mismatched Desktop profile accepted") } catch {}
        assert(desktopProfiles.desktopUUID() == desktopOneUUID, "mismatch leaves current Desktop profile untouched")
        let usage = AccountRepository.parseUsage(["rate_limit": ["primary_window": ["used_percent": 28, "limit_window_seconds": 18000, "reset_at": 1900000000]]], provider: .codex)
        assert(usage.count == 1 && usage[0].used == 28 && usage[0].label == "5 hours")
        assert(AccountRepository.parseUsage(["rate_limit": ["primary_window": [:]]], provider: .codex).isEmpty, "missing usage is not zero")
        let claudeUsage = AccountRepository.parseUsage(["five_hour": ["utilization": 120, "resets_at": "2026-09-26T12:00:00.000Z"]], provider: .claude)
        assert(claudeUsage[0].used == 100 && claudeUsage[0].reset != nil)
        let refreshAccount = SavedAccount(id: UUID().uuidString, provider: .claude, identity: "\(UUID().uuidString.lowercased()):", name: "refresh@example.com")
        let refreshUUID = String(refreshAccount.identity.split(separator: ":").first!)
        let refreshSecret = AccountSecret(credentials: try repository.encode(["claudeAiOauth": ["accessToken": "expired", "refreshToken": "refresh-old", "expiresAt": 1]]), profile: try repository.encode(["accountUuid": refreshUUID, "emailAddress": refreshAccount.name]))
        let storedRefresh = try repository.store(refreshSecret, provider: .claude, accounts: &accounts)
        try repository.secureWrite(repository.encode(["oauthAccount": ["accountUuid": refreshUUID, "emailAddress": refreshAccount.name]]), to: root.appendingPathComponent(".claude.json"))
        try vault.write(refreshSecret.credentials, repository.claudeService(directory: nil), repository.user)
        var usageRequests = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        UsageURLProtocol.handler = { request in
            if request.url?.path == "/v1/oauth/token" {
                var bodyData = request.httpBody ?? Data()
                if bodyData.isEmpty, let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        bodyData.append(contentsOf: buffer[..<count])
                    }
                }
                let body = try repository.object(bodyData)
                assert(body["refresh_token"] as? String == "refresh-old")
                assert(body["client_id"] as? String == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
                return (200, try repository.encode(["access_token": "renewed", "refresh_token": "refresh-new", "expires_in": 3600]))
            }
            usageRequests += 1
            if usageRequests == 1 {
                assert(request.value(forHTTPHeaderField: "Authorization") == "Bearer expired")
                return (401, Data())
            }
            assert(request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed")
            return (200, try repository.encode(["five_hour": ["utilization": 42, "resets_at": "2026-09-28T12:00:00Z"]]))
        }
        let refreshedUsage = try await repository.usage(storedRefresh, session: session)
        assert(refreshedUsage.windows.first?.used == 42 && usageRequests == 2, "expired Claude token is refreshed and usage retried")
        let savedRefresh = try repository.object(repository.secret(storedRefresh).credentials)["claudeAiOauth"] as! [String: Any]
        assert(savedRefresh["refreshToken"] as? String == "refresh-new", "rotated refresh token is saved")
        let activeRefresh = try repository.object(tryRead(vault, repository)!)["claudeAiOauth"] as! [String: Any]
        assert(activeRefresh["accessToken"] as? String == "renewed", "active Claude Code login receives refreshed token")
        print("Account tests passed: switching, token preservation, Claude Desktop profiles, usage parsing, Claude OAuth refresh and retry.")
    }
    static func tryIdentity(_ repo: AccountRepository, _ provider: AccountProvider) -> String { try! repo.identity(repo.capture(provider)!, provider: provider).0 }
    static func claudeTwoSecret(_ repo: AccountRepository, _ account: SavedAccount) -> Data { try! repo.secret(account).credentials }
    static func tryRead(_ vault: MemoryVault, _ repo: AccountRepository) -> Data? { try! vault.read(repo.claudeService(directory: nil), repo.user) }
}
