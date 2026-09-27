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

Archived sessions are hidden by default. Enable **Include archived** above the search results to show them. ccs indexes user and assistant text; tool results and thinking blocks are excluded. Changes to the history file formats may require parser updates.

If a Claude CLI session has no matching Claude Desktop entry, clicking it opens an in-app preview rather than another desktop session.

## Accounts and usage

Open **Settings → Accounts** to save logins. **Import current** saves an existing CLI login; if Claude Code is signed out, it opens `claude auth login` in Terminal and imports the account after sign-in. **Add account** signs in through the installed `codex` or `claude` CLI in Terminal and your browser, using an isolated configuration directory so the current login stays active. Credentials are saved in macOS Keychain; account labels and identifiers are saved in Application Support.

Saved accounts show available five-hour and weekly usage, reset times, and the last successful update. Usage refreshes every minute while Accounts is visible. A failed refresh keeps the last values and shows an error; expired credentials require another sign-in.

**Switch** saves the outgoing credentials and activates the selected account for new CLI sessions. Existing CLI sessions may need a restart to reload credentials. Removing a saved account does not log the CLI out. Codex switching closes Codex Desktop, updates the shared `~/.codex/auth.json`, and reopens Desktop with that same `CODEX_HOME`; sessions and settings remain shared. Claude switching closes Claude Desktop, selects the saved Desktop profile for that account, updates Claude Code authentication (`~/.claude.json` plus Keychain), and reopens Desktop. Claude Desktop has a separate login: sign in once when an account is first selected, and later switches reuse that login. Desktop profiles are kept in `~/Library/Application Support/ccs/accounts/claude-desktop/profiles`; existing profiles are moved, not copied or deleted. **Restart Desktop** is available for an active account. Codex requires file-based credential storage: `cli_auth_credentials_store = "keyring"` and `"auto"` are rejected with setup instructions. API-key accounts and custom configuration locations are not supported. Usage endpoints require subscription OAuth accounts and may change.

## Build and test

Quit ccs before running the build script. The script refuses to replace a running app because that invalidates its live code signature and causes Keychain authentication failures. If this happened with an older build, quit and reopen ccs, then refresh Accounts. A rebuilt ad hoc app may require Keychain access approval again; saved accounts do not need to be deleted.

Run `./build.sh` on macOS to build `ccs.app` and `ccs.zip`. The local build uses ad hoc signing and is not notarized. Distribution without a Gatekeeper override requires a Developer ID Application certificate and notarization (Apple Developer Program membership required). The app source is in `ccs.swift`, `Settings.swift`, and `Accounts.swift`.

For a distribution build, install a Developer ID Application certificate with its private key in Keychain Access, then run `CCS_CODESIGN_IDENTITY='Developer ID Application: NAME (TEAM_ID)' CCS_OUTPUT_DIR=/path/to/release ./build.sh`, replacing `NAME` and `TEAM_ID` with your certificate's values. This signs the app with the hardened runtime and a secure timestamp. Submit the resulting `ccs.zip` with `xcrun notarytool submit /path/to/release/ccs.zip --keychain-profile PROFILE --wait`, then run `xcrun stapler staple /path/to/release/ccs.app`. Recreate `ccs.zip` from the stapled app before distributing it. The notary keychain profile must be set up separately using Apple's `notarytool store-credentials` command.

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
