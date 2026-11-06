import Foundation
import SQLite3

@main
struct NoteEditActivityTests {
    static func main() {
        var db: OpaquePointer?
        precondition(sqlite3_open(":memory:", &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) {
            var error: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &error)
            let message = error.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(error)
            precondition(rc == SQLITE_OK, message)
        }
        exec("""
        CREATE TABLE compose_ops (id TEXT PRIMARY KEY, item_id TEXT, ts REAL, body TEXT, content_hash TEXT);
        CREATE INDEX idx_compose_ops_item_ts ON compose_ops(item_id, ts);
        CREATE TABLE user_evaluations (id TEXT PRIMARY KEY, item_id TEXT, ts REAL);
        CREATE INDEX idx_eval_item_ts ON user_evaluations(item_id, ts);
        -- Deliberately insert out of order; replay/no-op snapshots must not add edits.
        INSERT INTO compose_ops VALUES ('n4','note',4,'B','b'), ('n1','note',1,'A','a'),
          ('n3','note',3,'B','b'), ('n2','note',2,'A','a'),
          ('n5','note',5,'A','a'), ('n6','note',6,'B','b');
        INSERT OR IGNORE INTO compose_ops VALUES ('n6','note',6,'B','b');
        INSERT INTO compose_ops VALUES ('l1','legacy',1,'first',NULL),
          ('l2','legacy',2,'second',''), ('l3','legacy',3,'second',NULL),
          ('l4','legacy',4,'second','modern-hash'), ('l5','legacy',5,'third','third-hash'),
          ('s1','new',1,'just created','s'), ('x1','outside',1,'A','a'),
          ('x2','outside',2,'B','b');
        INSERT INTO user_evaluations VALUES ('e1','note',7), ('e2','capture',1),
          ('e3','capture',2), ('e4','outside',2);
        """)
        let ids = ["note", "legacy", "capture", "new", "untouched"]
        var stmt: OpaquePointer?
        let sql = NoteEditActivity.countSQL(placeholders: ids.map { _ in "?" }.joined(separator: ","))
        precondition(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, id) in ids.enumerated() {
            _ = id.withCString { sqlite3_bind_text(stmt, Int32(i + 1), $0, -1, transient) }
        }
        var counts: [String: Int] = [:]
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            counts[String(cString: sqlite3_column_text(stmt, 0))] = Int(sqlite3_column_int(stmt, 1))
            rc = sqlite3_step(stmt)
        }
        precondition(rc == SQLITE_DONE)
        precondition(counts == ["note": 3, "legacy": 2], "unexpected counts: \(counts)")
        precondition(counts["capture"] == nil, "evaluations are outside note edit activity")
        precondition(counts["new", default: 0] == 0, "creation is not an edit")
        precondition(counts["untouched", default: 0] == 0)
        precondition(counts["outside"] == nil, "page projection must not scan unrelated items")
        print("Note edit activity: body changes, undo, replay, legacy, note scope OK")
    }
}
