# ccs

ccs is a macOS menu bar app for searching local Claude Code and Codex conversations.

## Use

1. Unzip `ccs.zip`, move `ccs.app` to `/Applications`, and launch it. It stays in the menu bar.
2. Press `⌘⇧Space` or click the menu bar search icon to open the search panel.
3. Type to search session titles, conversation text, and project paths. Press `Ctrl+N` or `Ctrl+P` to select the next or previous session, and `Enter` to open the selected session. You can also click a session to open it in Codex or Claude Desktop. Use the icon at the right to preview the conversation. Linked GitHub pull requests and issues appear in the row and can be opened from its context menu. Press `Esc` to close the panel.

The session list and search results are always sorted by session start time, newest first. Session titles are the primary heading. The Claude and Codex icons have transparent backgrounds. ccs prefers titles and pull request links stored by Claude Desktop, and also detects issue and pull request URLs in conversation text.

For Claude sessions, ccs checks the associated process and conversation log. A green spinner and **Running** mean the session is responding; **Idle** means its process is open but it is not responding. For Codex sessions, a session lock indicates **Running**. **History** means no active session was detected. Status updates every 12 seconds.

An orange dot in the menu bar means at least one session has a new assistant message since you last opened or previewed it. Unread sessions also have a dot beside their title. Opening or previewing a session marks it as read. On the first run with unread tracking, existing history starts as read.

The first indexing pass may take time for large histories. Subsequent passes ingest new content every 12 seconds. The local index is stored at `~/Library/Application Support/ccs/index.sqlite3`. Existing SessionSpot data is copied on first launch. Keyword search runs locally.

## Supported history

- Claude Code: `~/.claude/projects/**/*.jsonl`
- Codex: `~/.codex/sessions/**/*.jsonl` and `~/.codex/archived_sessions/**/*.jsonl`

ccs indexes user and assistant text. Tool results and thinking blocks are excluded. Changes to the history file formats may require parser updates.

If a Claude CLI session has no matching Claude Desktop entry, clicking it opens an in-app preview. ccs does not open another desktop session as a fallback.

## Build

Run `./build.sh` on macOS to build the app and zip archive. The local build uses ad hoc signing and is not notarized. For distribution without a Gatekeeper override, sign with a Developer ID Application certificate and notarize the app (Apple Developer Program membership required). Source is in `ccs.swift`, `Settings.swift`, and `Accounts.swift`. In Settings → General, enable “Launch ccs at login” to keep the menu bar app available after sign-in.

## Settings and accounts

Open the gear button (or `⌘,`) for settings. In **General**, click the hotkey field and press a shortcut with Command, Option, or Control. The setting persists across launches; a conflicting shortcut leaves the previous binding intact. Turn on **Launch ccs at login** to start it automatically after sign-in. macOS may ask you to allow it in **System Settings → General → Login Items**.

In **Accounts**, use **Import current** to save an existing login, or **Add account** to sign in through the installed `codex` / `claude` CLI in Terminal and your browser. If Claude Code is signed out, **Import current** opens `claude auth login` in Terminal and imports the account after sign-in completes. Adding uses an isolated configuration directory and leaves the current login active. Saved credentials live in macOS Keychain; account labels and identifiers live in Application Support.

Each saved account shows available five-hour and weekly usage, reset times, and the last successful update. Usage refreshes every minute while Accounts is visible. Fetch failures retain the last values and display an error; expired saved credentials require signing in again. **Switch** preserves the outgoing credentials and activates the selected account for new CLI sessions. Restart existing clients to reload credentials. Removing a saved account does not log the CLI out.

Switching targets default `~/.codex` and Claude Code authentication (`~/.claude.json` plus Keychain). Claude Desktop has a separate login. Codex currently requires file-based credential storage; configurations using `cli_auth_credentials_store = "keyring"` or `"auto"` are rejected with setup instructions. API-key accounts and custom configuration locations are not supported. Usage endpoints require subscription OAuth accounts and may change.

Run the credential-isolated regression tests without accessing real logins:

```sh
swiftc -parse-as-library -framework AppKit -framework SwiftUI -framework Security Accounts.swift tests/AccountsTests.swift -o /tmp/ccs-account-tests
/tmp/ccs-account-tests
```

## Search regression tests

Search uses literal, case-insensitive substrings. Result excerpts start at a match so row truncation keeps it visible, including matches in titles and full project paths.

Run the isolated fixtures on macOS:

```sh
swiftc -D TESTING -parse-as-library -framework AppKit -framework SwiftUI -framework Carbon -framework Security -framework ServiceManagement -lsqlite3 ccs.swift Accounts.swift Settings.swift tests/SearchTests.swift -o /tmp/ccs-search-tests
/tmp/ccs-search-tests
```
