# SessionSpot

SessionSpot is a macOS menu bar app for searching local Claude Code and Codex conversations.

## Use

1. Unzip `SessionSpot.zip` and launch `SessionSpot.app`. It stays in the menu bar.
2. Press `⌘⇧Space` or click the menu bar search icon to open the search panel.
3. Type to search conversation text and project names. Press `Ctrl+N` or `Ctrl+P` to select the next or previous session, and `Enter` to open the selected session. You can also click a session to open it in Codex or Claude Desktop. Use the icon at the right to preview the conversation. Linked GitHub pull requests and issues appear in the row and can be opened from its context menu. Press `Esc` to close the panel.

The session list and search results are always sorted by session start time, newest first. Session titles are the primary heading. The Claude and Codex icons have transparent backgrounds. SessionSpot prefers titles and pull request links stored by Claude Desktop, and also detects issue and pull request URLs in conversation text.

For Claude sessions, SessionSpot checks the associated process and conversation log. A green spinner and **Running** mean the session is responding; **Idle** means its process is open but it is not responding. For Codex sessions, a session lock indicates **Running**. **History** means no active session was detected. Status updates every 12 seconds.

An orange dot in the menu bar means at least one session has a new assistant message since you last opened or previewed it. Unread sessions also have a dot beside their title. Opening or previewing a session marks it as read. On the first run with unread tracking, existing history starts as read.

The first indexing pass may take time for large histories. Subsequent passes ingest new content every 12 seconds. The local index is stored at `~/Library/Application Support/SessionSpot/index.sqlite3`. Keyword search runs locally.

## Supported history

- Claude Code: `~/.claude/projects/**/*.jsonl`
- Codex: `~/.codex/sessions/**/*.jsonl` and `~/.codex/archived_sessions/**/*.jsonl`

SessionSpot indexes user and assistant text. Tool results and thinking blocks are excluded. Changes to the history file formats may require parser updates.

If a Claude CLI session has no matching Claude Desktop entry, clicking it opens an in-app preview. SessionSpot does not open another desktop session as a fallback.

## Build

Run `./build.sh` on macOS to build the app and zip archive. The app uses ad hoc signing and is not notarized for the App Store. Source is in `SessionSpot.swift`.
