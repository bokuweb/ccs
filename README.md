<div align="center">
  <img src="assets/ccs-ghost.png" width="120" height="120" alt="ccs bookmark ghost mascot">
  <h1>ccs</h1>
  <p>Find your Claude Code and Codex conversations from the macOS menu bar.</p>
</div>

<p align="center">
  <img src="assets/search-demo.gif" width="800" alt="Demo of searching Claude Code and Codex sessions in ccs">
</p>

ccs searches local session titles, conversation text, and project paths. Results open in Codex or Claude Desktop, with an in-app preview available from each row.

## Get started

1. Unzip `ccs.zip`, move `ccs.app` to `/Applications`, and launch it. The bookmark ghost appears in the menu bar.
2. Press `⌘⇧Space` or click the ghost to open search.
3. Type a query. Use `Ctrl+N` / `Ctrl+P` to move through results, `Enter` to open the selected session, or click the preview icon on its row. Press `Esc` to close search.

Open **Settings** with the gear button or `⌘,` to change the shortcut. Press a combination with Command, Option, or Control in the hotkey field. If that shortcut is already in use, ccs keeps the previous one. You can also enable **Launch ccs at login**; macOS may ask you to allow it in **System Settings → General → Login Items**.

## Search and session status

- Results are sorted by session start time, newest first, with the session title as the main heading. The Claude and Codex marks have no surrounding tile. Search matches literal, case-insensitive substrings, and excerpts begin at a match.
- Linked GitHub pull requests and issues appear in results and can be opened from a row's context menu. ccs uses titles and pull request links from Claude Desktop when available and also finds issue and pull request URLs in conversation text.
- **Running** means a Claude session is responding or a Codex session has a lock. **Idle** means a Claude process is open but not responding. **History** means no active session was detected. Status refreshes every 12 seconds.
- An orange dot on the menu bar ghost means an assistant has written a new message since you last opened or previewed at least one session. Unread sessions also have a dot by their title. Existing history starts as read when unread tracking is first enabled.

The first indexing pass can take time for large histories. Later passes ingest new content every 12 seconds. Search is local, and the index is stored at `~/Library/Application Support/ccs/index.sqlite3`. Existing SessionSpot data is copied on first launch.

### Supported history

| Source | History files |
| --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl` |
| Codex | `~/.codex/sessions/**/*.jsonl` and `~/.codex/archived_sessions/**/*.jsonl` |

Archived sessions are hidden by default. Enable **Settings → General → Include archived sessions** to show them. ccs indexes user and assistant text; tool results and thinking blocks are excluded. Changes to the history file formats may require parser updates.

If a Claude CLI session has no matching Claude Desktop entry, clicking it opens an in-app preview rather than another desktop session.

## Accounts and usage

Open **Settings → Accounts** to save logins. **Import current** saves an existing CLI login; if Claude Code is signed out, it opens `claude auth login` in Terminal and imports the account after sign-in. **Add account** signs in through the installed `codex` or `claude` CLI in Terminal and your browser, using an isolated configuration directory so the current login stays active. Credentials are saved in macOS Keychain; account labels and identifiers are saved in Application Support.

Saved accounts show available five-hour and weekly usage, reset times, and the last successful update. Usage refreshes every minute while Accounts is visible. A failed refresh keeps the last values and shows an error; expired credentials require another sign-in.

**Switch** saves the outgoing credentials and activates the selected account for new CLI sessions. Restart existing clients to reload credentials. Removing a saved account does not log the CLI out. Switching targets the default `~/.codex` directory and Claude Code authentication (`~/.claude.json` plus Keychain); Claude Desktop uses a separate login. Codex requires file-based credential storage: `cli_auth_credentials_store = "keyring"` and `"auto"` are rejected with setup instructions. API-key accounts and custom configuration locations are not supported. Usage endpoints require subscription OAuth accounts and may change.

## Build and test

Quit ccs before running the build script. The script refuses to replace a running app because that invalidates its live code signature and causes Keychain authentication failures. If this happened with an older build, quit and reopen ccs, then refresh Accounts. A rebuilt ad hoc app may require Keychain access approval again; saved accounts do not need to be deleted.

Run `./build.sh` on macOS to build `ccs.app` and `ccs.zip`. The local build uses ad hoc signing and is not notarized. Distribution without a Gatekeeper override requires a Developer ID Application certificate and notarization (Apple Developer Program membership required). The app source is in `ccs.swift`, `Settings.swift`, and `Accounts.swift`.

For a local distribution build, set `CCS_CODESIGN_IDENTITY` to the Developer ID Application identity and optionally set `CCS_OUTPUT_DIR` to an output directory. The script signs with the hardened runtime and a secure timestamp. Submit the resulting ZIP with `xcrun notarytool submit ccs.zip --keychain-profile PROFILE --wait`, staple `ccs.app` with `xcrun stapler staple ccs.app`, then recreate the ZIP from the stapled app.

### Release artifact

Publishing a GitHub release starts `.github/workflows/release.yml`. The workflow builds with the Developer ID Application certificate, notarizes and staples the app, and uploads `ccs.zip` as a GitHub Actions artifact named `ccs-TAG-macos`. Actions artifacts are retained for 90 days. A local `notarytool` keychain profile is not available on GitHub's runner.

Configure these repository Actions secrets before publishing a release:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64 encoding of a password-protected `.p12` export containing the Developer ID Application certificate and its private key. |
| `MACOS_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12`. |
| `APPLE_ID` | Apple Account email used for notarization. |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for that Apple Account. |

The certificate must belong to team `66U862VS9W` and have the identity `Developer ID Application: Satoshi Ueki (66U862VS9W)`. Keep the `.p12` and passwords out of the repository. On macOS, the certificate secret can be uploaded without printing its contents with `base64 -i /path/to/certificate.p12 | gh secret set MACOS_CERTIFICATE_P12_BASE64 --repo bokuweb/ccs`. Set the other secrets through GitHub's repository settings or `gh secret set`.

Run the credential-isolated account tests without accessing real logins:

```sh
swiftc -parse-as-library -framework AppKit -framework SwiftUI -framework Security Accounts.swift tests/AccountsTests.swift -o /tmp/ccs-account-tests
/tmp/ccs-account-tests
```

Run the search regression fixtures:

```sh
swiftc -D TESTING -parse-as-library -framework AppKit -framework SwiftUI -framework Carbon -framework Security -framework ServiceManagement -lsqlite3 ccs.swift Accounts.swift Settings.swift tests/SearchTests.swift -o /tmp/ccs-search-tests
/tmp/ccs-search-tests
```
