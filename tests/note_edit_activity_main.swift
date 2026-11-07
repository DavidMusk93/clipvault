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
        -- Autosave burst: six body changes inside 180s of each other = one edit.
        INSERT INTO compose_ops VALUES
          ('b1','burst',100,'v1','h1'), ('b2','burst',140,'v2','h2'),
          ('b3','burst',200,'v3','h3'), ('b4','burst',260,'v4','h4'),
          ('b5','burst',300,'v5','h5'), ('b6','burst',330,'v6','h6');
        -- Two sittings: 181s of silence in between breaks the burst in two.
        INSERT INTO compose_ops VALUES
          ('t1','two',1000,'v1','g1'), ('t2','two',1060,'v2','g2'),
          ('t3','two',1170,'v3','g3'), ('t4','two',1351,'v4','g4'),
          ('t5','two',1400,'v5','g5');
        -- Still being typed: the newest burst has not gone quiet yet.
        INSERT INTO compose_ops VALUES
          ('o1','open',5000,'v1','p1'), ('o2','open',5010,'v2','p2');
        -- A long typing session with autosave every 60s stays one edit.
        INSERT INTO compose_ops VALUES
          ('y1','typing',2000,'v1','q1'), ('y2','typing',2060,'v2','q2'),
          ('y3','typing',2120,'v3','q3'), ('y4','typing',2180,'v4','q4'),
          ('y5','typing',2240,'v5','q5'), ('y6','typing',2300,'v6','q6');
        """)
        let ids = ["note", "legacy", "capture", "new", "untouched", "burst", "two", "open", "typing"]
        func counts(now: Double) -> [String: Int] {
            var stmt: OpaquePointer?
            let sql = NoteEditActivity.countSQL(placeholders: ids.map { _ in "?" }.joined(separator: ","))
            precondition(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, id) in ids.enumerated() {
                _ = id.withCString { sqlite3_bind_text(stmt, Int32(i + 1), $0, -1, transient) }
            }
            sqlite3_bind_double(stmt, Int32(ids.count + 1), now)
            var out: [String: Int] = [:]
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                out[String(cString: sqlite3_column_text(stmt, 0))] = Int(sqlite3_column_int(stmt, 1))
                rc = sqlite3_step(stmt)
            }
            precondition(rc == SQLITE_DONE)
            return out
        }

        // Everything is long quiet: each burst is already a finished edit.
        let settled = counts(now: 9_999_999)
        precondition(settled == [
            "note": 1, "legacy": 1, "burst": 1, "two": 2, "open": 1, "typing": 1,
        ], "unexpected counts: \(settled)")
        precondition(settled["capture"] == nil, "evaluations are outside note edit activity")
        precondition(settled["new", default: 0] == 0, "creation is not an edit")
        precondition(settled["untouched", default: 0] == 0)
        precondition(settled["outside"] == nil, "page projection must not scan unrelated items")

        // Same data, mid-typing: the open burst has not earned an edit yet.
        let midTyping = counts(now: 5_100)
        precondition(midTyping["open", default: -1] == 0, "a burst still in progress is not an edit: \(midTyping)")
        precondition(midTyping["two", default: -1] == 2, "closed bursts keep counting: \(midTyping)")
        // Exactly 180s of silence is not quiet any more; 179s still is.
        precondition(counts(now: 5_190)["open", default: -1] == 1, "180s silence closes the burst")
        precondition(counts(now: 5_189)["open", default: -1] == 0, "179s silence keeps the burst open")
        // Two bursts, the second one still open: only the closed one counts.
        precondition(counts(now: 1_531)["two", default: -1] == 1, "open burst is withheld")
        precondition(counts(now: 1_580)["two", default: -1] == 2, "both bursts closed")
        print("Note edit activity: body changes, undo, replay, legacy, note scope, 180s burst debounce OK")
    }
}
