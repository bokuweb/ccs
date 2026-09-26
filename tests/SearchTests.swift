import Foundation
import SQLite3

@main struct SearchTests {
    static func main() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("search.sqlite3").path
        let store = Store(databasePath: path, metadataHome: directory)
        var db: OpaquePointer?
        precondition(sqlite3_open(path, &db) == SQLITE_OK)
        let bodies = ["hello keyboard world", "keyboat unrelated", "literal 100% value", "literal under_score", "literal back\\slash", "日本語検索", "nothing relevant", "KEYBOARD again"]
        for (i, body) in bodies.enumerated() {
            let file = directory.appendingPathComponent("fixture-\(i).jsonl").path
            let project = i == 6 ? "/projects/keyboard" : "/projects/sample"
            let sql = "INSERT INTO files(path,offset,size,started) VALUES('\(file)',0,0,\(i)); INSERT INTO messages(id,file,source,project,role,body,stamp) VALUES(\(i+1),'\(file)','Codex','\(project)','user','\(body)',''); INSERT INTO search(rowid,body) VALUES(\(i+1),'\(body)');"
            precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        func exec(_ sql: String, on connection: OpaquePointer? = nil) {
            precondition(sqlite3_exec(connection ?? db, sql, nil, nil, nil) == SQLITE_OK)
        }
        func add(_ id: Int, source: String = "Codex", body: String = "unrelated conversation") {
            let file = directory.appendingPathComponent("fixture-\(id).jsonl").path
            exec("INSERT INTO files(path,offset,size,started) VALUES('\(file)',0,0,\(id)); INSERT INTO messages(id,file,source,project,role,body,stamp) VALUES(\(id),'\(file)','\(source)','/projects/sample','user','\(body)',''); INSERT INTO search(rowid,body) VALUES(\(id),'\(body)');")
        }
        add(20, source: "Claude", body: "model選択は画像のようにロゴ表示して。")
        add(21, source: "Claude")
        add(22)
        add(23, body: "表示バグ is in the older matching message")
        exec("INSERT INTO messages(id,file,source,project,role,body,stamp) SELECT 24,file,source,project,role,'latest unrelated message','' FROM messages WHERE id=23; INSERT INTO search(rowid,body) VALUES(24,'latest unrelated message');")
        let claudeRoot = directory.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        try! FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        let claudeFile = claudeRoot.appendingPathComponent("session.json")
        func writeClaudeTitle(_ title: String) {
            try! JSONSerialization.data(withJSONObject: ["cliSessionId": "fixture-20", "title": title, "sessionId": "desktop-20"]).write(to: claudeFile)
        }
        writeClaudeTitle("モデル選択ロゴ表示とClaude表示バグ")
        let custom = directory.appendingPathComponent("fixture-21")
        try! FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: ["customTitle": "CLI表示バグ"]).write(to: custom.appendingPathComponent("custom-title.json"))
        let codexRoot = directory.appendingPathComponent(".codex")
        try! FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        var state: OpaquePointer?
        precondition(sqlite3_open(codexRoot.appendingPathComponent("state_5.sqlite").path, &state) == SQLITE_OK)
        exec("CREATE TABLE threads(id TEXT, name TEXT, title TEXT, created_at REAL); INSERT INTO threads VALUES('fixture-22','Codex表示バグ','old title',22),('fixture-23','','表示バグ',23);", on: state)
        defer { sqlite3_close(db); sqlite3_close(state) }
        func check(_ phrase: String, _ ids: Set<Int64>, verify: @escaping ([Hit]) -> Void = { _ in }) {
            let done = DispatchSemaphore(value: 0)
            store.query(phrase) { hits in
                precondition(Set(hits.map(\.id)) == ids, "Unexpected results for \(phrase): \(hits.map(\.id))")
                precondition(Set(hits.map(\.path)).count == hits.count)
                precondition(hits.map(\.started) == hits.map(\.started).sorted(by: >))
                if !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let q = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                    precondition(hits.allSatisfy { $0.teaser(q).range(of: q, options: .caseInsensitive) != nil })
                }
                verify(hits)
                done.signal()
            }
            precondition(done.wait(timeout: .now() + 10) == .success)
        }
        check("keyboard", [1,7,8])
        check("  keyboard  ", [1,7,8])
        check("100%", [3])
        check("_", [4])
        check("back\\slash", [5])
        check("日本", [6])
        check("日本語検索", [6])
        check("no-such-match", [])
        check("表示", [20,21,22,23])
        check("表示バグ", [20,21,22,23]) { hits in
            precondition(hits.first(where: { $0.id == 20 })?.desktopID == "desktop-20")
            precondition(hits.first(where: { $0.id == 23 })?.text == "表示バグ is in the older matching message")
        }
        check("codex表示バグ", [22])
        check("old title", [])
        check("", Set(1...8).union([20,21,22,24]))
        // Title changes must be searchable without reindexing the message logs.
        writeClaudeTitle("改名後のタイトル")
        exec("UPDATE threads SET name='Renamed session' WHERE id='fixture-22'", on: state)
        check("表示バグ", [21,23])
        check("改名後", [20])
        check("renamed", [22])
        // A title-only result older than the normal recent/search limits must still be found.
        for id in 100...230 { add(id) }
        check("改名後", [20])
        let body = "編集テストは「戻る」の遷移完了前に、残っていた編集画面を操作していました。プレビューと編集画面のURL・表示状態を待つように直します。新規作成後の再読み込みも、エディタの初期化完了を待ってから保存内容を検証します。"
        var hit = Hit(id: 1, source: "Codex", project: "/projects/hidden/表示/project", role: "assistant", text: body, path: "test", timestamp: "", started: 0, updated: 0, turnActive: false)
        precondition(hit.teaser("表示").hasPrefix("…表示状態"))
        hit.title = String(repeating: "long title ", count: 20) + "表示バグ"
        precondition(hit.teaser("表示バグ") == "…表示バグ")
        precondition(hit.teaser("hidden").hasPrefix("…hidden"))
        print("Search regression tests passed")
    }
}
