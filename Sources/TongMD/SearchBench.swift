#if DEBUG
import Foundation

/// 开发期基准：对比 FTS 索引与内存扫描在 1000 篇笔记上的表现
enum SearchBench {
    static func run() -> Int32 {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TongMD-search-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let words = ["同步", "设计", "本地", "写入", "冲突", "笔记", "索引", "搜索", "附件", "文件夹", "版本", "提交", "网络", "代理", "渲染", "预览"]
        var documents: [SearchIndex.Document] = []
        for index in 0..<1000 {
            var body = ""
            for _ in 0..<40 {
                body += words.randomElement()! + "，"
            }
            documents.append(SearchIndex.Document(
                path: "/notes/\(index).md",
                title: "笔记 \(index) \(words[index % words.count])",
                body: body
            ))
        }

        let dbURL = root.appendingPathComponent("bench.sqlite3")
        guard let index = try? SearchIndex(path: dbURL) else {
            print("索引创建失败")
            return 1
        }

        let buildStart = Date()
        index.replaceAll(documents)
        let buildMs = Date().timeIntervalSince(buildStart) * 1000

        let queries = ["同步", "设计", "同步 设计", "冲突", "本地 写入", "代理"]
        var indexTotal = 0.0
        var indexCount = 0
        for _ in 0..<10 {
            for query in queries {
                let start = Date()
                _ = try? index.search(query)
                indexTotal += Date().timeIntervalSince(start) * 1000
                indexCount += 1
            }
        }

        let pairs = documents.map { (note: Note(url: URL(fileURLWithPath: $0.path), root: URL(fileURLWithPath: "/notes")), text: $0.body) }
        var scanTotal = 0.0
        var scanCount = 0
        for _ in 0..<2 {
            for query in queries {
                let start = Date()
                _ = SearchEngine.search(query: query, in: pairs)
                scanTotal += Date().timeIntervalSince(start) * 1000
                scanCount += 1
            }
        }

        print(String(format: "索引 1000 篇：%.0f ms", buildMs))
        print(String(format: "FTS 查询平均：%.2f ms（%d 次）", indexTotal / Double(indexCount), indexCount))
        print(String(format: "内存扫描平均：%.1f ms（%d 次）", scanTotal / Double(scanCount), scanCount))

        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int) ?? 0
        let walSize = (try? FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? Int) ?? 0
        print("索引体积：\(ByteCountFormatter.string(fromByteCount: Int64(fileSize + walSize), countStyle: .file))")
        return 0
    }
}
#endif
