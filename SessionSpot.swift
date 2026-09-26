import AppKit
import SwiftUI
import Carbon
import SQLite3

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Hit: Identifiable, Hashable {
    let id: Int64
    let source: String
    let project: String
    let role: String
    let text: String
    let path: String
    let timestamp: String
    var started: Double
    let updated: Double
    let turnActive: Bool
    var title: String = ""
    var github: [GitHubRef] = []
    var desktopID: String?
    var sessionID: String {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return String(name.suffix(36))
    }
    var displayProject: String {
        let parts = URL(fileURLWithPath: project).pathComponents.filter { $0 != "/" }
        guard let last = parts.last else { return project }
        if let worktrees = parts.firstIndex(of: "worktrees"), worktrees > 1, worktrees + 1 < parts.count {
            return parts[worktrees - 2] + "  /  " + parts[worktrees + 1]
        }
        return last
    }
    func teaser(_ phrase: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let value = [flat, title, project].first {
            !phrase.isEmpty && $0.range(of: phrase, options: .caseInsensitive) != nil
        } ?? flat
        guard !phrase.isEmpty, let range = value.range(of: phrase, options: .caseInsensitive) else { return String(value.prefix(230)) }
        // Start at the match: even a narrow row must not truncate the matching words away.
        let end = value.index(range.upperBound, offsetBy: 65, limitedBy: value.endIndex) ?? value.endIndex
        return (range.lowerBound == value.startIndex ? "" : "…") + String(value[range.lowerBound..<end]) + (end == value.endIndex ? "" : "…")
    }
}

struct GitHubRef: Hashable {
    let url: String
    let label: String
}

@MainActor enum ProviderLogos {
    static let claude = Bundle.main.image(forResource: "ClaudeLogo")
    static let codex = Bundle.main.image(forResource: "CodexLogo")
}

final class Store {
    let path: String
    private let metadataHome: URL
    private var writer: OpaquePointer?
    private let queue = DispatchQueue(label: "sessionspot.index", qos: .utility)
    private var indexing = false
    private var repaired = false
    var onStatus: ((String) -> Void)?
    var onUnreadPaths: ((Set<String>) -> Void)?

    init(databasePath: String? = nil, metadataHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.metadataHome = metadataHome
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SessionSpot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = databasePath ?? dir.appendingPathComponent("index.sqlite3").path
        sqlite3_open(path, &writer)
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, offset INTEGER NOT NULL, size INTEGER NOT NULL, started REAL NOT NULL DEFAULT 0, updated REAL NOT NULL DEFAULT 0, turn_active INTEGER NOT NULL DEFAULT 0, state_scanned INTEGER NOT NULL DEFAULT 0)")
        exec("ALTER TABLE files ADD COLUMN started REAL NOT NULL DEFAULT 0")
        exec("ALTER TABLE files ADD COLUMN turn_active INTEGER NOT NULL DEFAULT 0")
        exec("ALTER TABLE files ADD COLUMN state_scanned INTEGER NOT NULL DEFAULT 0")
        exec("ALTER TABLE files ADD COLUMN updated REAL NOT NULL DEFAULT 0")
        exec("CREATE TABLE IF NOT EXISTS messages(id INTEGER PRIMARY KEY, file TEXT NOT NULL, source TEXT NOT NULL, project TEXT NOT NULL, role TEXT NOT NULL, body TEXT NOT NULL, stamp TEXT NOT NULL)")
        exec("CREATE INDEX IF NOT EXISTS messages_file ON messages(file)")
        exec("CREATE INDEX IF NOT EXISTS messages_role_file_id ON messages(role,file,id)")
        exec("CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(body, tokenize='trigram')")
        exec("CREATE TABLE IF NOT EXISTS read_state(path TEXT PRIMARY KEY, assistant_id INTEGER NOT NULL)")
        exec("CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    }
    deinit { sqlite3_close(writer) }
    private func exec(_ sql: String) { sqlite3_exec(writer, sql, nil, nil, nil) }
    private func prepare(_ sql: String, db: OpaquePointer?) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }
    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }
    private static func parseTimestamp(_ value: String) -> Double? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date.timeIntervalSince1970 }
        return ISO8601DateFormatter().date(from: value)?.timeIntervalSince1970
    }
    private func recentTurnState(_ file: String, size: Int64) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: file) else { return false }
        defer { try? handle.close() }
        let count = min(size, 16 * 1024 * 1024)
        try? handle.seek(toOffset: UInt64(size - count))
        guard let data = try? handle.readToEnd() else { return false }
        let lines = data.split(separator: 10)
        for line in lines.reversed() {
            guard line.contains(Data("\"event_msg\"".utf8)),
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any], let event = payload["type"] as? String else { continue }
            if event == "task_started" { return true }
            if event == "task_complete" || event == "turn_aborted" { return false }
        }
        return false
    }
    func refresh() {
        queue.async { [weak self] in
            guard let self, !self.indexing else { return }
            self.indexing = true
            defer { self.indexing = false }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let roots = [home + "/.claude/projects", home + "/.codex/sessions", home + "/.codex/archived_sessions"]
            var paths: [String] = []
            for root in roots {
                guard let en = FileManager.default.enumerator(atPath: root) else { continue }
                for case let relative as String in en where relative.hasSuffix(".jsonl") { paths.append(root + "/" + relative) }
            }
            paths.sort()
            var changed = 0
            for (i, file) in paths.enumerated() {
                if self.index(file) { changed += 1 }
                if i % 30 == 0 { self.onStatus?("Indexing · \(i + 1)/\(paths.count) files") }
            }
            if !self.repaired { self.repairStartedTimes(); self.repaired = true }
            self.initializeUnreadTracking()
            self.publishUnreadPaths()
            self.onStatus?("\(paths.count) session files · \(changed) updated")
        }
    }
    private func initializeUnreadTracking() {
        let check = prepare("SELECT 1 FROM metadata WHERE key='unread_initialized'", db: writer)
        let initialized = sqlite3_step(check) == SQLITE_ROW
        sqlite3_finalize(check)
        guard !initialized else { return }
        exec("BEGIN")
        exec("INSERT OR REPLACE INTO read_state(path,assistant_id) SELECT file,MAX(id) FROM messages WHERE role='assistant' GROUP BY file")
        exec("INSERT OR REPLACE INTO metadata(key,value) VALUES('unread_initialized','1')")
        exec("COMMIT")
    }
    private func publishUnreadPaths() {
        let sql = "SELECT latest.file FROM (SELECT file,MAX(id) AS assistant_id FROM messages WHERE role='assistant' GROUP BY file) latest LEFT JOIN read_state r ON r.path=latest.file WHERE latest.assistant_id > COALESCE(r.assistant_id,0)"
        guard let statement = prepare(sql, db: writer) else { return }
        var paths = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) { paths.insert(String(cString: value)) }
        }
        sqlite3_finalize(statement)
        onUnreadPaths?(paths)
    }
    func markRead(_ path: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let sql = "INSERT INTO read_state(path,assistant_id) SELECT file,MAX(id) FROM messages WHERE file=? AND role='assistant' GROUP BY file ON CONFLICT(path) DO UPDATE SET assistant_id=MAX(read_state.assistant_id,excluded.assistant_id)"
            if let statement = self.prepare(sql, db: self.writer) {
                self.bind(statement, 1, path)
                sqlite3_step(statement)
                sqlite3_finalize(statement)
            }
            self.publishUnreadPaths()
        }
    }
    private func repairStartedTimes() {
        let state = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite").path
        var source: OpaquePointer?
        var dates: [String: Double] = [:]
        if sqlite3_open_v2(state, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
           let stmt = prepare("SELECT id,created_at FROM threads", db: source) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let id = sqlite3_column_text(stmt, 0) { dates[String(cString: id)] = Double(sqlite3_column_int64(stmt, 1)) }
            }
            sqlite3_finalize(stmt)
        }
        if source != nil { sqlite3_close(source) }
        let select = prepare("SELECT path,started FROM files", db: writer)
        let stamp = prepare("SELECT stamp FROM messages WHERE file=? AND stamp!='' ORDER BY id LIMIT 1", db: writer)
        let update = prepare("UPDATE files SET started=? WHERE path=?", db: writer)
        while sqlite3_step(select) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(select, 0) else { continue }
            let file = String(cString: raw)
            let old = sqlite3_column_double(select, 1)
            var started = 0.0
            if file.contains("/.codex/") {
                let id = String(URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent.suffix(36))
                started = dates[id] ?? 0
            } else {
                bind(stamp, 1, file)
                if sqlite3_step(stamp) == SQLITE_ROW, let raw = sqlite3_column_text(stamp, 0) {
                    started = Self.parseTimestamp(String(cString: raw)) ?? 0
                }
                sqlite3_reset(stamp); sqlite3_clear_bindings(stamp)
            }
            if started > 0 && started != old {
                sqlite3_bind_double(update, 1, started); bind(update, 2, file)
                sqlite3_step(update); sqlite3_reset(update); sqlite3_clear_bindings(update)
            }
        }
        sqlite3_finalize(select); sqlite3_finalize(stamp); sqlite3_finalize(update)
    }
    private func index(_ file: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file), let size = attrs[.size] as? NSNumber else { return false }
        let fileSize = size.int64Value
        var oldOffset: Int64 = 0
        var scanned = false
        var turnActive = false
        var previousStarted = 0.0
        var started = ((attrs[.creationDate] ?? attrs[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
        let updated = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? started
        let select = prepare("SELECT offset,state_scanned,turn_active,started FROM files WHERE path=?", db: writer)
        bind(select, 1, file)
        if sqlite3_step(select) == SQLITE_ROW {
            oldOffset = sqlite3_column_int64(select, 0)
            scanned = sqlite3_column_int(select, 1) != 0
            turnActive = sqlite3_column_int(select, 2) != 0
            previousStarted = sqlite3_column_double(select, 3)
        }
        sqlite3_finalize(select)
        if previousStarted > 0 { started = previousStarted }
        if fileSize == oldOffset && !scanned {
            let state = file.contains("/.codex/") ? recentTurnState(file, size: fileSize) : false
            let update = prepare("UPDATE files SET started=?,updated=?,turn_active=?,state_scanned=1 WHERE path=?", db: writer)
            sqlite3_bind_double(update, 1, started)
            sqlite3_bind_double(update, 2, updated)
            sqlite3_bind_int(update, 3, state ? 1 : 0)
            bind(update, 4, file)
            sqlite3_step(update); sqlite3_finalize(update)
            return false
        }
        if fileSize == oldOffset && scanned {
            let update = prepare("UPDATE files SET updated=? WHERE path=? AND updated!=?", db: writer)
            sqlite3_bind_double(update, 1, updated); bind(update, 2, file); sqlite3_bind_double(update, 3, updated)
            sqlite3_step(update); sqlite3_finalize(update)
            return false
        }
        exec("BEGIN")
        if fileSize < oldOffset {
            let ids = prepare("SELECT id FROM messages WHERE file=?", db: writer)
            bind(ids, 1, file)
            let delFts = prepare("DELETE FROM search WHERE rowid=?", db: writer)
            while sqlite3_step(ids) == SQLITE_ROW {
                sqlite3_bind_int64(delFts, 1, sqlite3_column_int64(ids, 0))
                sqlite3_step(delFts); sqlite3_reset(delFts)
            }
            sqlite3_finalize(ids); sqlite3_finalize(delFts)
            let del = prepare("DELETE FROM messages WHERE file=?", db: writer)
            bind(del, 1, file); sqlite3_step(del); sqlite3_finalize(del)
            oldOffset = 0
            turnActive = false
        }
        guard let handle = FileHandle(forReadingAtPath: file) else { exec("ROLLBACK"); return false }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: UInt64(scanned ? oldOffset : 0)) } catch { exec("ROLLBACK"); return false }
        let ins = prepare("INSERT INTO messages(file,source,project,role,body,stamp) VALUES(?,?,?,?,?,?)", db: writer)
        let fts = prepare("INSERT INTO search(rowid,body) VALUES(?,?)", db: writer)
        let up = prepare("INSERT INTO files(path,offset,size,started,updated,turn_active,state_scanned) VALUES(?,?,?,?,?,?,1) ON CONFLICT(path) DO UPDATE SET offset=excluded.offset,size=excluded.size,started=excluded.started,updated=excluded.updated,turn_active=excluded.turn_active,state_scanned=1", db: writer)
        var pending = Data()
        var offset = scanned ? oldOffset : 0
        var lastGood = oldOffset
        let source = file.contains("/.claude/") ? "Claude" : "Codex"
        let folder = URL(fileURLWithPath: file).deletingLastPathComponent().lastPathComponent
        var project = source == "Claude" ? folder.replacingOccurrences(of: "-Users-", with: "~/").replacingOccurrences(of: "-", with: "/") : "Codex"
        while true {
            let chunk = (try? handle.read(upToCount: 256 * 1024)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            pending.append(chunk)
            while let end = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: end)
                offset += Int64(end + 1)
                lastGood = offset
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    if source == "Codex", obj["type"] as? String == "event_msg", let payload = obj["payload"] as? [String: Any], let event = payload["type"] as? String {
                        if event == "task_started" { turnActive = true }
                        if event == "task_complete" || event == "turn_aborted" { turnActive = false }
                    }
                    if source == "Codex", obj["type"] as? String == "session_meta", let p = obj["payload"] as? [String: Any], let cwd = p["cwd"] as? String { project = cwd }
                    if source == "Claude", let cwd = obj["cwd"] as? String { project = cwd }
                    if offset > oldOffset, let item = extract(obj, source: source) {
                        for i in 0..<6 { bind(ins, Int32(i + 1), [file, source, project, item.0, item.1, item.2][i]) }
                        if sqlite3_step(ins) == SQLITE_DONE {
                            sqlite3_bind_int64(fts, 1, sqlite3_last_insert_rowid(writer)); bind(fts, 2, item.1)
                            sqlite3_step(fts); sqlite3_reset(fts); sqlite3_clear_bindings(fts)
                        }
                        sqlite3_reset(ins); sqlite3_clear_bindings(ins)
                    }
                }
                pending.removeSubrange(...end)
            }
        }
        bind(up, 1, file)
        sqlite3_bind_int64(up, 2, max(lastGood, oldOffset))
        sqlite3_bind_int64(up, 3, fileSize)
        sqlite3_bind_double(up, 4, started)
        sqlite3_bind_double(up, 5, updated)
        sqlite3_bind_int(up, 6, turnActive ? 1 : 0)
        sqlite3_step(up)
        sqlite3_finalize(ins); sqlite3_finalize(fts); sqlite3_finalize(up)
        exec("COMMIT")
        return true
    }
    private func extract(_ o: [String: Any], source: String) -> (String, String, String)? {
        let stamp = o["timestamp"] as? String ?? ""
        var role = ""
        var blocks: Any?
        if source == "Claude" {
            guard let t = o["type"] as? String, t == "user" || t == "assistant", let msg = o["message"] as? [String: Any] else { return nil }
            role = t; blocks = msg["content"]
        } else {
            guard o["type"] as? String == "response_item", let p = o["payload"] as? [String: Any], p["type"] as? String == "message", let r = p["role"] as? String, r == "user" || r == "assistant" else { return nil }
            role = r; blocks = p["content"]
        }
        var text = ""
        if let s = blocks as? String { text = s }
        if let arr = blocks as? [[String: Any]] {
            text = arr.compactMap { b in
                let type = b["type"] as? String ?? ""
                guard ["text", "input_text", "output_text"].contains(type) else { return nil }
                return b["text"] as? String
            }.joined(separator: "\n")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (role, String(text.prefix(20_000)), stamp)
    }
    private struct SessionMetadata {
        var codex: [String: (String, Double)]
        var claude: [String: [String: Any]]
    }
    private func loadSessionMetadata() -> SessionMetadata {
        var codex: [String: (String, Double)] = [:]
        var claude: [String: [String: Any]] = [:]
        let claudeRoot = metadataHome.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        if let files = FileManager.default.enumerator(at: claudeRoot, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let cli = info["cliSessionId"] as? String else { continue }
                claude[cli] = info
            }
        }
        let state = metadataHome.appendingPathComponent(".codex/state_5.sqlite").path
        var stateDB: OpaquePointer?
        if sqlite3_open_v2(state, &stateDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            if let stmt = prepare("SELECT id,COALESCE(NULLIF(name,''),title),created_at FROM threads", db: stateDB) {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let id = sqlite3_column_text(stmt, 0), let title = sqlite3_column_text(stmt, 1) else { continue }
                    codex[String(cString: id)] = (String(cString: title), Double(sqlite3_column_int64(stmt, 2)))
                }
                sqlite3_finalize(stmt)
            }
        }
        if stateDB != nil { sqlite3_close(stateDB) }
        return SessionMetadata(codex: codex, claude: claude)
    }
    private func externalTitle(_ hit: Hit, metadata: SessionMetadata) -> String? {
        if hit.source == "Codex" { return metadata.codex[hit.sessionID]?.0 }
        if let title = metadata.claude[hit.sessionID]?["title"] as? String, !title.isEmpty { return title }
        let customTitle = URL(fileURLWithPath: hit.path).deletingPathExtension().appendingPathComponent("custom-title.json")
        guard let data = try? Data(contentsOf: customTitle),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let title = json["customTitle"], !title.isEmpty else { return nil }
        return title
    }
    private func enrich(_ hits: inout [Hit], db: OpaquePointer?, metadata: SessionMetadata) {
        let codex = metadata.codex
        let claude = metadata.claude
        let linksPattern = try? NSRegularExpression(pattern: "https?://github\\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/(pull|issues)/([0-9]+)", options: .caseInsensitive)
        let first = prepare("SELECT body,stamp FROM messages WHERE file=? AND role='user' ORDER BY id LIMIT 1", db: db)
        let links = prepare("SELECT body FROM messages WHERE file=? AND body LIKE '%github.com/%' LIMIT 40", db: db)
        for i in hits.indices {
            let session = hits[i].sessionID
            if hits[i].source == "Codex", let info = codex[session] {
                if info.1 > 0 { hits[i].started = info.1 }
            }
            if hits[i].source == "Claude" {
                if let info = claude[session] {
                    hits[i].desktopID = info["sessionId"] as? String
                    if let created = info["createdAt"] as? NSNumber { hits[i].started = created.doubleValue / 1000 }
                }
            }
            if let title = externalTitle(hits[i], metadata: metadata) { hits[i].title = title }
            bind(first, 1, hits[i].path)
            if sqlite3_step(first) == SQLITE_ROW {
                if hits[i].title.isEmpty, let raw = sqlite3_column_text(first, 0) {
                    let value = String(cString: raw).split(separator: "\n").map(String.init).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
                    hits[i].title = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(110))
                }
                if hits[i].source == "Claude", hits[i].desktopID == nil, let raw = sqlite3_column_text(first, 1), let date = Self.parseTimestamp(String(cString: raw)) {
                    hits[i].started = date
                }
            }
            sqlite3_reset(first); sqlite3_clear_bindings(first)
            if hits[i].title.isEmpty { hits[i].title = hits[i].displayProject }
            bind(links, 1, hits[i].path)
            var refs: [GitHubRef] = []
            while sqlite3_step(links) == SQLITE_ROW {
                guard let raw = sqlite3_column_text(links, 0) else { continue }
                let body = String(cString: raw)
                for match in linksPattern?.matches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body)) ?? [] {
                    guard let range = Range(match.range, in: body) else { continue }
                    let url = String(body[range])
                    let part = url.split(separator: "/")
                    guard part.count >= 7 else { continue }
                    let label = (part[5] == "pull" ? "PR" : "Issue") + " #" + part[6]
                    if !refs.contains(where: { $0.url == url }) { refs.append(GitHubRef(url: url, label: label)) }
                }
            }
            sqlite3_reset(links); sqlite3_clear_bindings(links)
            if let prs = claude[session]?["prs"] as? [[String: Any]] {
                for pr in prs {
                    guard let url = pr["url"] as? String, let number = pr["prNumber"] as? Int else { continue }
                    if !refs.contains(where: { $0.url == url }) { refs.insert(GitHubRef(url: url, label: "PR #\(number)"), at: 0) }
                }
            }
            hits[i].github = Array(refs.prefix(3))
        }
        sqlite3_finalize(first); sqlite3_finalize(links)
    }
    func query(_ phrase: String, completion: @escaping ([Hit]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var db: OpaquePointer?
            guard sqlite3_open_v2(self.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { completion([]); return }
            defer { sqlite3_close(db) }
            let q = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let order = "f.started DESC,f.updated DESC"
            let sql: String
            if q.isEmpty {
                sql = "SELECT m.id,m.source,m.project,m.role,m.body,m.file,m.stamp,f.started,f.updated,f.turn_active FROM messages m JOIN files f ON f.path=m.file WHERE m.id IN (SELECT max(id) FROM messages GROUP BY file) ORDER BY \(order),m.id DESC LIMIT 80"
            } else if q.count >= 3 {
                sql = "SELECT m.id,m.source,m.project,m.role,m.body,m.file,m.stamp,f.started,f.updated,f.turn_active FROM messages m JOIN files f ON f.path=m.file WHERE m.id IN (SELECT max(m2.id) FROM search s JOIN messages m2 ON m2.id=s.rowid WHERE s.body LIKE ? ESCAPE '\\' GROUP BY m2.file) ORDER BY \(order),m.id DESC LIMIT 120"
            } else {
                sql = "SELECT m.id,m.source,m.project,m.role,m.body,m.file,m.stamp,f.started,f.updated,f.turn_active FROM messages m JOIN files f ON f.path=m.file WHERE m.id IN (SELECT max(m2.id) FROM messages m2 WHERE m2.body LIKE ? ESCAPE '\\' GROUP BY m2.file) ORDER BY \(order),m.id DESC LIMIT 120"
            }
            guard let st = self.prepare(sql, db: db) else { completion([]); return }
            if !q.isEmpty { self.bind(st, 1, "%" + q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%") }
            var hits: [Hit] = []
            while sqlite3_step(st) == SQLITE_ROW {
                func col(_ n: Int32) -> String { guard let p = sqlite3_column_text(st, n) else { return "" }; return String(cString: p) }
                hits.append(Hit(id: sqlite3_column_int64(st, 0), source: col(1), project: col(2), role: col(3), text: col(4), path: col(5), timestamp: col(6), started: sqlite3_column_double(st, 7), updated: sqlite3_column_double(st, 8), turnActive: sqlite3_column_int(st, 9) != 0))
            }
            sqlite3_finalize(st)
            if !q.isEmpty {
                if let byProject = self.prepare("SELECT m.id,m.source,m.project,m.role,m.body,m.file,m.stamp,f.started,f.updated,f.turn_active FROM messages m JOIN files f ON f.path=m.file WHERE m.id IN (SELECT max(id) FROM messages WHERE project LIKE ? ESCAPE '\\' GROUP BY file) ORDER BY \(order),m.id DESC LIMIT 60", db: db) {
                    self.bind(byProject, 1, "%" + q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%")
                    var seen = Set(hits.map(\.id))
                    while sqlite3_step(byProject) == SQLITE_ROW {
                        func col(_ n: Int32) -> String { guard let p = sqlite3_column_text(byProject, n) else { return "" }; return String(cString: p) }
                        let hit = Hit(id: sqlite3_column_int64(byProject, 0), source: col(1), project: col(2), role: col(3), text: col(4), path: col(5), timestamp: col(6), started: sqlite3_column_double(byProject, 7), updated: sqlite3_column_double(byProject, 8), turnActive: sqlite3_column_int(byProject, 9) != 0)
                        if seen.insert(hit.id).inserted { hits.append(hit) }
                    }
                    sqlite3_finalize(byProject)
                }
            }
            let metadata = self.loadSessionMetadata()
            if !q.isEmpty {
                // Titles live outside the message index and may change without a log append.
                // Scan every session before limiting results so older title-only hits remain searchable.
                let titleSQL = "SELECT m.id,m.source,m.project,m.role,m.body,m.file,m.stamp,f.started,f.updated,f.turn_active FROM messages m JOIN files f ON f.path=m.file WHERE m.id IN (SELECT max(id) FROM messages GROUP BY file)"
                if let titles = self.prepare(titleSQL, db: db) {
                    let existing = Set(hits.map(\.path))
                    while sqlite3_step(titles) == SQLITE_ROW {
                        func col(_ n: Int32) -> String { guard let p = sqlite3_column_text(titles, n) else { return "" }; return String(cString: p) }
                        let hit = Hit(id: sqlite3_column_int64(titles, 0), source: col(1), project: col(2), role: col(3), text: col(4), path: col(5), timestamp: col(6), started: sqlite3_column_double(titles, 7), updated: sqlite3_column_double(titles, 8), turnActive: sqlite3_column_int(titles, 9) != 0)
                        if !existing.contains(hit.path),
                           let title = self.externalTitle(hit, metadata: metadata),
                           title.range(of: q, options: .caseInsensitive) != nil { hits.append(hit) }
                    }
                    sqlite3_finalize(titles)
                }
            }
            self.enrich(&hits, db: db, metadata: metadata)
            var seenFiles = Set<String>()
            hits = hits.filter { seenFiles.insert($0.path).inserted }
            hits.sort {
                $0.started == $1.started ? $0.id > $1.id : $0.started > $1.started
            }
            completion(Array(hits.prefix(q.isEmpty ? 80 : 120)))
        }
    }
}

@MainActor final class Model: ObservableObject {
    @Published var query = "" { didSet { selected = nil; highlightedID = nil; listRevision += 1; search() } }
    @Published var listRevision = 0
    @Published var results: [Hit] = []
    @Published var highlightedID: Int64?
    @Published var selected: Hit?
    @Published var status = "Preparing index…"
    @Published var claudeProcesses = Set<String>()
    @Published var claudeWorking = Set<String>()
    @Published var codexLocks = Set<String>()
    @Published var unreadPaths = Set<String>() { didSet { onUnreadChanged?(unreadPaths.count) } }
    var onUnreadChanged: ((Int) -> Void)?
    let store = Store()
    private var generation = 0
    init() {
        store.onStatus = { [weak self] s in DispatchQueue.main.async {
            guard let self else { return }
            self.status = s
            if !s.hasPrefix("Indexing") { self.search() }
        } }
        store.onUnreadPaths = { [weak self] paths in DispatchQueue.main.async {
            if self?.unreadPaths != paths { self?.unreadPaths = paths }
        } }
        search()
        store.refresh()
        refreshProcesses()
        Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refresh(); self?.refreshProcesses() }
        }
    }
    func isRunning(_ hit: Hit) -> Bool {
        hit.source == "Claude" ? claudeWorking.contains(hit.sessionID) : codexLocks.contains(hit.sessionID)
    }
    func isOpen(_ hit: Hit) -> Bool {
        hit.source == "Claude" && claudeProcesses.contains(hit.sessionID)
    }
    func preview(_ hit: Hit) {
        store.markRead(hit.path)
        selected = hit
    }
    nonisolated private static func claudeTurnActive(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 256_000 ? size - 256_000 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return false }
        for line in data.split(separator: 10).reversed() {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            if type == "system", event["subtype"] as? String == "turn_duration" { return false }
            if type == "assistant", let message = event["message"] as? [String: Any] {
                return message["stop_reason"] as? String != "end_turn"
            }
            if type == "user" { return true }
        }
        return false
    }
    nonisolated private static func newClaudeSession(pid: String, hits: [Hit]) -> String? {
        func output(_ executable: String, _ arguments: [String]) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        guard let startedText = output("/bin/ps", ["-p", pid, "-o", "lstart="])?.trimmingCharacters(in: .whitespacesAndNewlines),
              let cwdOutput = output("/usr/sbin/lsof", ["-a", "-p", pid, "-d", "cwd", "-Fn"]),
              let cwd = cwdOutput.split(separator: "\n").first(where: { $0.hasPrefix("n") }).map({ String($0.dropFirst()) }) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        guard let started = formatter.date(from: startedText)?.timeIntervalSince1970 else { return nil }
        return hits.filter {
            $0.source == "Claude" && $0.project == cwd && abs($0.started - started) < 180
        }.min(by: { abs($0.started - started) < abs($1.started - started) })?.sessionID
    }
    func openSession(_ hit: Hit) {
        if hit.source == "Claude", hit.desktopID == nil {
            preview(hit)
            status = "This CLI session has no matching Claude Desktop entry"
            return
        }
        let address: String
        if let desktopID = hit.desktopID, hit.source == "Claude" {
            address = "claude://code/continue?session=\(desktopID)&source=sessionspot"
        } else {
            address = "codex://threads/\(hit.sessionID)"
        }
        if let url = URL(string: address), NSWorkspace.shared.open(url) {
            store.markRead(hit.path)
            NSApp.keyWindow?.orderOut(nil)
        } else {
            status = "Could not open the desktop app"
        }
    }
    func refreshProcesses() {
        let claudeHits = results.filter { $0.source == "Claude" }
        let claudePaths = claudeHits.map { ($0.sessionID, $0.path) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "pid=,command="]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
            do { try process.run() } catch { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let string = String(decoding: data, as: UTF8.self)
            let regex = try? NSRegularExpression(pattern: "--(?:resume|session-id)(?:=|\\s+)([0-9a-fA-F-]{36})")
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            var ids = Set((regex?.matches(in: string, range: range) ?? []).compactMap { match -> String? in
                guard let r = Range(match.range(at: 1), in: string) else { return nil }
                return String(string[r]).lowercased()
            })
            for line in string.split(separator: "\n") {
                let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                guard fields.count == 2, Int(fields[0]) != nil else { continue }
                let command = String(fields[1])
                guard let flags = command.range(of: " --"),
                      command[..<flags.lowerBound].hasSuffix("/claude"),
                      regex?.firstMatch(in: command, range: NSRange(command.startIndex..<command.endIndex, in: command)) == nil else { continue }
                if let id = Self.newClaudeSession(pid: String(fields[0]), hits: claudeHits) { ids.insert(id) }
            }
            let working = Set(claudePaths.compactMap { id, path in
                ids.contains(id) && Self.claudeTurnActive(at: path) ? id : nil
            })
            let locks = Process()
            locks.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            locks.arguments = ["-Fn", "+D", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/thread-writer-locks").path]
            let lockPipe = Pipe(); locks.standardOutput = lockPipe; locks.standardError = Pipe()
            var lockIDs = Set<String>()
            if (try? locks.run()) != nil {
                let output = String(decoding: lockPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                locks.waitUntilExit()
                for line in output.split(separator: "\n") where line.hasPrefix("n") && line.hasSuffix(".lock") {
                    lockIDs.insert(String(URL(fileURLWithPath: String(line.dropFirst())).deletingPathExtension().lastPathComponent).lowercased())
                }
            }
            DispatchQueue.main.async {
                self?.claudeProcesses = ids
                self?.claudeWorking = working
                self?.codexLocks = lockIDs
            }
        }
    }
    func search() {
        generation += 1
        let current = generation
        store.query(query) { [weak self] hits in
            DispatchQueue.main.async {
                guard let self, current == self.generation else { return }
                self.results = hits
                if !hits.contains(where: { $0.id == self.highlightedID }) {
                    self.highlightedID = hits.first?.id
                }
                self.refreshProcesses()
            }
        }
    }

    var highlightedHit: Hit? {
        results.first(where: { $0.id == highlightedID }) ?? results.first
    }

    func moveSelection(_ offset: Int) {
        guard !results.isEmpty else { highlightedID = nil; return }
        selected = nil
        let index = results.firstIndex(where: { $0.id == highlightedID }) ?? 0
        highlightedID = results[min(max(index + offset, 0), results.count - 1)].id
    }

}

struct SearchView: View {
    @ObservedObject var model: Model
    @FocusState private var focus: Bool
    @State private var hoveredID: Int64?
    private let surface = Color(red: 0.105, green: 0.106, blue: 0.115)
    private let raised = Color(red: 0.18, green: 0.18, blue: 0.19)
    private let muted = Color.white.opacity(0.52)
    private func accent(_ hit: Hit) -> Color { hit.source == "Claude" ? Color(red: 1, green: 0.59, blue: 0.35) : Color(red: 0.42, green: 0.75, blue: 1) }
    private var searchPhrase: String { model.query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func highlighted(_ value: String) -> Text {
        var result = AttributedString(value)
        guard !searchPhrase.isEmpty else { return Text(result) }
        var start = value.startIndex
        while start < value.endIndex,
              let range = value.range(of: searchPhrase, options: .caseInsensitive, range: start..<value.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: result),
               let upper = AttributedString.Index(range.upperBound, within: result) {
                result[lower..<upper].foregroundColor = .yellow
                result[lower..<upper].backgroundColor = .yellow.opacity(0.16)
            }
            start = range.upperBound
        }
        return Text(result)
    }
    private func date(_ value: Double) -> String {
        guard value > 0 else { return "" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = Calendar.current.isDateInToday(Date(timeIntervalSince1970: value)) ? "H:mm" : "M/d H:mm"
        return f.string(from: Date(timeIntervalSince1970: value))
    }
    private func statusLabel(_ hit: Hit) -> some View {
        let running = model.isRunning(hit)
        let waiting = !running && model.isOpen(hit)
        return HStack(spacing: 6) {
            if running {
                ProgressView().controlSize(.mini).frame(width: 13, height: 13).tint(.green)
            } else {
                Circle().fill(waiting ? Color.orange : Color.white.opacity(0.34)).frame(width: 6, height: 6)
            }
            Text(running ? "Running" : waiting ? "Idle" : "History")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(running ? Color.green : waiting ? Color.orange : muted)
    }
    private func sessionRow(_ hit: Hit) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let logo = hit.source == "Claude" ? ProviderLogos.claude : ProviderLogos.codex {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    highlighted(hit.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)
                    if model.unreadPaths.contains(hit.path) {
                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                            .accessibilityLabel("Unread")
                    }
                    if !hit.github.isEmpty {
                        Image(systemName: "link").font(.system(size: 10, weight: .bold)).foregroundStyle(muted)
                    }
                }
                HStack(spacing: 6) {
                    Text(hit.source).foregroundStyle(accent(hit))
                    Text("·")
                    highlighted(hit.displayProject).lineLimit(1)
                    if !hit.github.isEmpty {
                        Text("·")
                        Text(hit.github.map(\.label).joined(separator: ", ")).lineLimit(1)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(muted)
                if !searchPhrase.isEmpty {
                    highlighted(hit.teaser(searchPhrase))
                        .font(.system(size: 11))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 7) {
                statusLabel(hit)
                Text(date(hit.started)).font(.system(size: 11)).foregroundStyle(muted)
            }
            .frame(minWidth: 64, alignment: .trailing)
            Button { model.preview(hit) } label: {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 12))
                    .foregroundStyle(muted)
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
            .help("Preview conversation")
        }
        .padding(.horizontal, 13)
        .frame(height: searchPhrase.isEmpty ? 64 : 84)
        .frame(maxWidth: .infinity)
        .background(model.highlightedID == hit.id ? raised : hoveredID == hit.id ? Color.white.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onHover { hoveredID = $0 ? hit.id : nil }
        .onTapGesture { model.openSession(hit) }
        .contextMenu {
            Button("Preview conversation") { model.preview(hit) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)]) }
            ForEach(hit.github, id: \.url) { ref in
                Button(ref.label) { if let url = URL(string: ref.url) { NSWorkspace.shared.open(url) } }
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                TextField("Search sessions and conversations…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .regular))
                    .focused($focus)
                    .onSubmit { if let hit = model.highlightedHit { model.openSession(hit) } }
            }
            .padding(.horizontal, 24)
            .frame(height: 76)
            Divider().overlay(.white.opacity(0.05))
            HStack(spacing: 8) {
                Text(model.query.isEmpty ? "Recent sessions" : "Search results")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(muted)
                Text("\(model.results.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()
                Text("Newest started first")
            }
            .font(.system(size: 11))
            .foregroundStyle(muted)
            .padding(.horizontal, 25)
            .frame(height: 42)
            if let hit = model.selected {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button { model.selected = nil } label: { Label("Search results", systemImage: "chevron.left") }
                            .buttonStyle(.plain)
                        Spacer()
                        statusLabel(hit)
                    }
                    highlighted(hit.title).font(.system(size: 20, weight: .semibold)).lineLimit(2)
                    Text("\(hit.source) · \(hit.displayProject) · Started \(date(hit.started))")
                        .font(.system(size: 11)).foregroundStyle(muted)
                    ScrollView {
                        highlighted(hit.text).font(.system(size: 13)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    .background(raised, in: RoundedRectangle(cornerRadius: 10))
                    HStack {
                        Spacer()
                        if hit.source != "Claude" || hit.desktopID != nil { Button("Open in app") { model.openSession(hit) } }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)]) }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.results) { hit in sessionRow(hit).id(hit.id) }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                    }
                    .id(model.listRevision)
                    .onChange(of: model.highlightedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            Divider().overlay(.white.opacity(0.05))
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16)).foregroundStyle(.white.opacity(0.36))
                Text(model.status).lineLimit(1)
                Spacer(minLength: 12)
                Button("Refresh") { model.store.refresh() }.buttonStyle(.plain)
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain)
                Text("Open  ↵")
                    .foregroundStyle(.white.opacity(0.8))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)
            .padding(.horizontal, 21)
            .frame(height: 43)
            .background(Color.white.opacity(0.035))
        }
        .background(surface)
        .onAppear { focus = true }
    }
}

final class SearchPanel: NSPanel {
    var onMoveSelection: ((Int) -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.control, .command, .option, .shift]) == .control {
            if event.keyCode == kVK_ANSI_N { onMoveSelection?(1); return }
            if event.keyCode == kVK_ANSI_P { onMoveSelection?(-1); return }
        }
        super.sendEvent(event)
    }
}

// Vector template keeps the bookmark ghost sharp and lets macOS choose its tint.
private enum MenuBarIcon {
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
            // Even-odd cutouts stay transparent when used as a menu bar template.
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
        image.accessibilityDescription = "SessionSpot"
        return image
    }
}

@MainActor private final class UnreadBadgeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var panel: SearchPanel!
    var status: NSStatusItem!
    var hotKey: EventHotKeyRef?
    private let unreadBadge = UnreadBadgeView()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = MenuBarIcon.makeImage()
        if let button = status.button {
            unreadBadge.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(unreadBadge)
            NSLayoutConstraint.activate([
                unreadBadge.widthAnchor.constraint(equalToConstant: 5),
                unreadBadge.heightAnchor.constraint(equalToConstant: 5),
                unreadBadge.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: 6),
                unreadBadge.topAnchor.constraint(equalTo: button.centerYAnchor, constant: -8)
            ])
        }
        status.button?.target = self; status.button?.action = #selector(toggle)
        model.onUnreadChanged = { [weak self] count in self?.updateUnreadIndicator(count) }
        updateUnreadIndicator(model.unreadPaths.count)
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 580), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true; panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor(red: 0.105, green: 0.106, blue: 0.115, alpha: 1)
        panel.contentView = NSHostingView(rootView: SearchView(model: model))
        panel.onMoveSelection = { [weak model] offset in model?.moveSelection(offset) }
        panel.center()
        let id = EventHotKeyID(signature: OSType(0x53535054), id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKey)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        toggle()
    }
    @objc func toggle() {
        if panel.isVisible { panel.orderOut(nil) }
        else { model.listRevision += 1; panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
    @objc func refresh() { model.store.refresh() }
    private func updateUnreadIndicator(_ count: Int) {
        status.length = NSStatusItem.squareLength
        unreadBadge.isHidden = count == 0
        status.button?.toolTip = count == 0 ? "No unread sessions" : "\(count) unread session\(count == 1 ? "" : "s")"
    }
    @objc func quit() { NSApp.terminate(nil) }
}

#if !TESTING
@main @MainActor struct SessionSpotMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

#endif
