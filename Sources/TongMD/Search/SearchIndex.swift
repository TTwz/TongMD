import Foundation
import SQLite3

/// 中文友好切词：CJK 按「单字 + 相邻两字」切，拉丁/数字按单词切。
/// 这样 FTS5 的 unicode61 分词器也能支持任意长度的中文查询。
enum SearchTokenizer {
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // 日文假名
             0x3400...0x4DBF,   // 扩展 A
             0x4E00...0x9FFF,   // 基本汉字
             0xAC00...0xD7AF,   // 韩文
             0xF900...0xFAFF:   // 兼容汉字
            return true
        default:
            return false
        }
    }

    /// 索引侧：把文本压成用空格分隔的 token 串
    static func indexTokens(_ text: String) -> String {
        var tokens: [String] = []
        var cjkRun: [Character] = []
        var word = ""

        func flushCJK() {
            guard !cjkRun.isEmpty else { return }
            for character in cjkRun { tokens.append(String(character)) }
            if cjkRun.count > 1 {
                for index in 0..<(cjkRun.count - 1) {
                    tokens.append(String(cjkRun[index]) + String(cjkRun[index + 1]))
                }
            }
            cjkRun.removeAll()
        }
        func flushWord() {
            guard !word.isEmpty else { return }
            tokens.append(word.lowercased())
            word = ""
        }

        for character in text {
            guard let scalar = character.unicodeScalars.first else { continue }
            if isCJK(scalar) {
                flushWord()
                cjkRun.append(character)
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                flushCJK()
                word.append(character)
            } else {
                flushCJK()
                flushWord()
            }
        }
        flushCJK()
        flushWord()
        return tokens.joined(separator: " ")
    }

    /// 查询侧：中文 ≥2 字取相邻两字，单字取本身；拉丁取整词
    static func queryTokens(_ query: String) -> [String] {
        var tokens: [String] = []
        var cjkRun: [Character] = []
        var word = ""

        func flushCJK() {
            guard !cjkRun.isEmpty else { return }
            if cjkRun.count == 1 {
                tokens.append(String(cjkRun[0]))
            } else {
                for index in 0..<(cjkRun.count - 1) {
                    tokens.append(String(cjkRun[index]) + String(cjkRun[index + 1]))
                }
            }
            cjkRun.removeAll()
        }
        func flushWord() {
            guard !word.isEmpty else { return }
            tokens.append(word.lowercased())
            word = ""
        }

        for character in query {
            guard let scalar = character.unicodeScalars.first else { continue }
            if isCJK(scalar) {
                flushWord()
                cjkRun.append(character)
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                flushCJK()
                word.append(character)
            } else {
                flushCJK()
                flushWord()
            }
        }
        flushCJK()
        flushWord()
        return tokens
    }
}

/// 基于 SQLite FTS5 的全文索引，替代全库内存扫描。
/// 索引文件放在 Application Support，不进笔记库、不会被 git 同步。
final class SearchIndex {
    struct Document {
        let path: String
        let title: String
        let body: String
    }

    struct Hit {
        let path: String
        /// bm25 是「越小越相关」，这里转成正数用于排序
        let score: Double
    }

    private let queue = DispatchQueue(label: "dev.tong.TongMD.search-index")
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let dbPath: URL
    private var pendingUpserts = 0

    private static let docsSchema = """
    CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(path UNINDEXED, title, body, tokenize='unicode61');
    """

    init(path: URL) throws {
        dbPath = path
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw NSError(domain: "TongMD.SearchIndex", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法打开搜索索引"])
        }
        db = handle
        sqlite3_busy_timeout(handle, 2000)

        let schema = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS notes(path TEXT PRIMARY KEY);
        CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(path UNINDEXED, title, body, tokenize='unicode61');
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            db = nil
            throw NSError(domain: "TongMD.SearchIndex", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法初始化搜索索引"])
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    var documentCount: Int {
        queue.sync {
            guard let db else { return 0 }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM notes", -1, &statement, nil) == SQLITE_OK else {
                return 0
            }
            return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
        }
    }

    /// 全量重建（结构变化、启动时）。
    /// 直接 DROP + CREATE 而不是 DELETE：FTS5 的 DELETE 只打墓碑，
    /// 频繁重建会让文件持续变大；重建表则复用同一批页。
    func replaceAll(_ documents: [Document]) {
        queue.sync {
            guard let db else { return }
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            sqlite3_exec(db, "DROP TABLE IF EXISTS docs", nil, nil, nil)
            sqlite3_exec(db, Self.docsSchema, nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM notes", nil, nil, nil)
            for document in documents {
                insert(document, db: db)
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            checkpoint(db)
        }
    }

    /// 合并 FTS 段、回收空间；平时由 upsert 计数自动触发
    func optimize() {
        queue.sync {
            guard let db else { return }
            optimizeLocked(db)
            checkpoint(db)
        }
    }

    /// 彻底压缩：优化 + checkpoint + VACUUM
    func compact() {
        queue.sync {
            guard let db else { return }
            optimizeLocked(db)
            sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            sqlite3_exec(db, "VACUUM", nil, nil, nil)
            checkpoint(db)
        }
    }

    /// 索引占用的总字节数（含 WAL）
    var sizeBytes: Int {
        let base = dbPath
        let paths = [base.path, base.path + "-wal", base.path + "-shm"]
        return paths.reduce(0) { total, path in
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            return total + size
        }
    }

    /// 单篇更新（保存时）
    func upsert(_ document: Document) {
        queue.sync {
            guard let db else { return }
            removeRows(path: document.path, db: db)
            insert(document, db: db)

            // 每 200 次写入整理一次，避免墓碑越积越多
            pendingUpserts += 1
            if pendingUpserts >= 200 {
                pendingUpserts = 0
                optimizeLocked(db)
                checkpoint(db)
            }
        }
    }

    func remove(path: String) {
        queue.sync {
            guard let db else { return }
            removeRows(path: path, db: db)
        }
    }

    func search(_ query: String, limit: Int = 60) throws -> [Hit] {
        let tokens = SearchTokenizer.queryTokens(query)
        guard !tokens.isEmpty else { return [] }

        let expression = tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " AND ")

        return try queue.sync {
            guard let db else { return [] }
            // 列权重：path 不参与，title 权重高，body 权重 1
            let sql = """
            SELECT path, bm25(docs, 0.0, 8.0, 1.0) AS rank
            FROM docs
            WHERE docs MATCH ?
            ORDER BY rank
            LIMIT ?;
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "TongMD.SearchIndex", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "搜索语句准备失败"])
            }
            sqlite3_bind_text(statement, 1, expression, -1, transient)
            sqlite3_bind_int(statement, 2, Int32(limit))

            var hits: [Hit] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let pathPointer = sqlite3_column_text(statement, 0) else { continue }
                let path = String(cString: pathPointer)
                let rank = sqlite3_column_double(statement, 1)
                hits.append(Hit(path: path, score: -rank))
            }
            return hits
        }
    }

    // MARK: - 内部

    private func insert(_ document: Document, db: OpaquePointer) {
        let body = SearchTokenizer.indexTokens(document.body)
        let title = SearchTokenizer.indexTokens(document.title)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO docs(path, title, body) VALUES(?, ?, ?)", -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, document.path, -1, transient)
        sqlite3_bind_text(statement, 2, title, -1, transient)
        sqlite3_bind_text(statement, 3, body, -1, transient)
        sqlite3_step(statement)

        var noteStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO notes(path) VALUES(?)", -1, &noteStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(noteStatement, 1, document.path, -1, transient)
            sqlite3_step(noteStatement)
        }
        sqlite3_finalize(noteStatement)
    }

    private func optimizeLocked(_ db: OpaquePointer) {
        sqlite3_exec(db, "INSERT INTO docs(docs) VALUES('optimize')", nil, nil, nil)
    }

    private func checkpoint(_ db: OpaquePointer) {
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
    }

    private func removeRows(path: String, db: OpaquePointer) {
        for sql in ["DELETE FROM docs WHERE path = ?", "DELETE FROM notes WHERE path = ?"] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(statement, 1, path, -1, transient)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }
}
