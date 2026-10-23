import CFNetwork
import Foundation

enum GitError: LocalizedError {
    case notARepository
    case notEmpty
    case command(String)
    case launch(String)

    var errorDescription: String? {
        switch self {
        case .notARepository: return "这个文件夹还不是 git 仓库"
        case .notEmpty: return "目标文件夹不是空的，请选择空文件夹或已有仓库"
        case .command(let message): return message
        case .launch(let message): return "无法启动 git：\(message)"
        }
    }
}

struct GitResult: Sendable {
    let code: Int32
    let output: String
    let error: String

    var ok: Bool { code == 0 }

    var shortError: String {
        let text = error.trimmed.isEmpty ? output.trimmed : error.trimmed
        guard !text.isEmpty else { return "退出码 \(code)" }
        return text.split(separator: "\n").suffix(2).joined(separator: " ")
    }
}

struct SyncOutcome: Sendable {
    let branch: String
    let summary: String
}

struct CommitOutcome: Sendable {
    let committed: Bool
    let hash: String
}

/// 直接驱动系统 git。不引入 libgit2：行为和用户在终端里看到的一致，出错也容易解释。
struct GitEngine: Sendable {
    var token: String = ""

    static let gitPath = "/usr/bin/git"

    // MARK: - 对外操作

    func isRepository(_ dir: URL) -> Bool {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return true }
        // rev-parse 会往上找父目录的仓库，必须确认仓库根就是这个文件夹本身
        guard let result = try? run(["rev-parse", "--show-toplevel"], in: dir), result.ok else { return false }
        let top = URL(fileURLWithPath: result.output.trimmed)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let target = dir.standardizedFileURL.resolvingSymlinksInPath()
        return top.path == target.path
    }

    func currentBranch(_ dir: URL) throws -> String {
        let head = try run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)
        if head.ok {
            let name = head.output.trimmed
            if !name.isEmpty, name != "HEAD" { return name }
        }
        if let symbolic = try? run(["symbolic-ref", "--short", "HEAD"], in: dir), symbolic.ok {
            let name = symbolic.output.trimmed
            if !name.isEmpty { return name }
        }
        return "main"
    }

    func remoteURL(_ dir: URL) -> String? {
        guard let result = try? run(["remote", "get-url", "origin"], in: dir), result.ok else { return nil }
        return result.output.trimmed
    }

    func clone(_ remote: String, into dir: URL) throws {
        let parent = dir.deletingLastPathComponent()
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard existing.filter({ $0 != ".DS_Store" }).isEmpty else { throw GitError.notEmpty }

        var argv = [Self.gitPath, "-C", parent.path]
        if remote.hasPrefix("http") {
            argv += Self.networkArguments(token: token)
        }
        argv += ["clone", remote, dir.path]
        let result = try Self.exec(argv, cwd: parent)
        guard result.ok else { throw GitError.command(result.shortError) }
    }

    func initialize(remote: String, in dir: URL) throws {
        if !isRepository(dir) {
            let result = try run(["init", "-b", "main"], in: dir)
            guard result.ok else { throw GitError.command(result.shortError) }
        }
        if !remote.trimmed.isEmpty {
            let current = remoteURL(dir)
            if current == nil {
                _ = try run(["remote", "add", "origin", remote.trimmed], in: dir)
            }
        }
    }

    /// 拉取 + 提交本地改动 + 推送。任何一步失败都尽量把后续步骤做完，最后把问题汇总给用户看。
    func sync(_ dir: URL) throws -> SyncOutcome {
        guard isRepository(dir) else { throw GitError.notARepository }
        guard remoteURL(dir) != nil else { throw GitError.command("没有配置 origin 远端") }

        let branch = try currentBranch(dir)
        var notes: [String] = []

        let headBefore = (try? run(["rev-parse", "HEAD"], in: dir))?.output.trimmed ?? ""
        let pull = try run(["pull", "--rebase", "--autostash", "origin", branch], in: dir, network: true)
        if !pull.ok {
            // 冲突时不要留一个半截的 rebase 状态：回退到本地，让用户手动处理
            if isRebaseInProgress(dir) {
                _ = try? run(["rebase", "--abort"], in: dir)
                notes.append("远端有冲突，已保留本地版本，请手动合并后再同步")
            } else {
                notes.append("拉取未完成：\(Self.friendlyMessage(for: pull))")
            }
        } else {
            let headAfterPull = (try? run(["rev-parse", "HEAD"], in: dir))?.output.trimmed ?? ""
            if !headBefore.isEmpty, headBefore != headAfterPull {
                notes.append("已拉取远端更新")
            }
        }

        let commit = try commitIfNeeded("note: 同步 \(Self.stamp())", in: dir)
        if commit.committed { notes.append("提交 \(commit.hash)") }

        let push = try run(["push", "-u", "origin", branch], in: dir, network: true)
        if !push.ok { notes.append("推送失败：\(Self.friendlyMessage(for: push))") }

        let summary = notes.isEmpty ? "已是最新" : notes.joined(separator: " · ")
        return SyncOutcome(branch: branch, summary: summary)
    }

    func isRebaseInProgress(_ dir: URL) -> Bool {
        let gitDir = dir.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("rebase-merge").path)
            || FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("rebase-apply").path)
    }

    func commitIfNeeded(_ message: String, in dir: URL) throws -> CommitOutcome {
        guard isRepository(dir) else { throw GitError.notARepository }
        let status = try run(["status", "--porcelain"], in: dir)
        guard !status.output.trimmed.isEmpty else { return CommitOutcome(committed: false, hash: "") }

        _ = try run(["add", "-A"], in: dir)

        var identity: [String] = []
        let email = (try? run(["config", "user.email"], in: dir))?.output.trimmed ?? ""
        if email.isEmpty {
            identity = ["-c", "user.name=TongMD", "-c", "user.email=tongmd@localhost"]
        }

        let commit = try run(identity + ["commit", "-m", message], in: dir)
        guard commit.ok else { throw GitError.command(commit.shortError) }

        let hash = (try? run(["rev-parse", "--short", "HEAD"], in: dir))?.output.trimmed ?? ""
        return CommitOutcome(committed: true, hash: hash)
    }

    /// 只读探测远端：验证仓库地址和 token 是否可用
    func lsRemote(_ remote: String) throws -> String {
        var argv = [Self.gitPath]
        if remote.hasPrefix("http") {
            argv += Self.networkArguments(token: token)
        }
        argv += ["ls-remote", "--heads", remote]

        let result = try Self.exec(argv, cwd: FileManager.default.temporaryDirectory)
        guard result.ok else { throw GitError.command(Self.friendlyMessage(for: result)) }
        let branches = result.output.split(separator: "\n").count
        return branches == 0 ? "仓库可访问（还没有分支）" : "仓库可访问 · \(branches) 个分支"
    }

    func changedFileCount(_ dir: URL) -> Int {
        guard let result = try? run(["status", "--porcelain"], in: dir) else { return 0 }
        return result.output.split(separator: "\n").count
    }

    // MARK: - 进程

    func run(_ args: [String], in dir: URL, network: Bool = false) throws -> GitResult {
        var argv = [Self.gitPath, "-C", dir.path]
        if network {
            argv += Self.networkArguments(token: token)
        }
        argv += args
        return try Self.exec(argv, cwd: dir)
    }

    static func authArguments(token: String) -> [String] {
        let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
        return [
            "-c", "http.extraheader=Authorization: Basic \(basic)",
            "-c", "credential.helper="
        ]
    }

    /// 所有走网络的操作统一加上的参数。
    /// 强制 HTTP/1.1 是因为在某些网络（代理、透明网关）下，Apple Git 的
    /// HTTP/2 会报 "Error in the HTTP2 framing layer"，而 HTTP/1.1 正常。
    /// 对笔记仓库这种小体量操作，性能差别可以忽略。
    static func networkArguments(token: String) -> [String] {
        var arguments = [
            "-c", "http.version=HTTP/1.1",
            // 始终禁用 git 的外部凭据助手：系统钥匙串里可能存着另一个 GitHub 账号，
            // 用它去推会得到「403 Write access not granted」，非常难查。
            "-c", "credential.helper="
        ]
        arguments += systemProxyArguments()
        if !token.isEmpty {
            arguments += authArguments(token: token)
        }
        return arguments
    }

    /// git 不会自动使用 macOS 的「系统代理」，只认环境变量和 git config。
    /// 这里把系统代理读出来显式传给 git，否则在需要代理的网络里会一直超时。
    static func systemProxyArguments() -> [String] {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return []
        }
        return proxyArguments(from: settings)
    }

    static func proxyArguments(from settings: [String: Any]) -> [String] {
        func flag(_ key: String) -> Bool { (settings[key] as? Int) == 1 }
        func host(_ key: String) -> String? {
            guard let value = settings[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        func port(_ key: String) -> Int? {
            if let value = settings[key] as? Int { return value }
            if let value = settings[key] as? NSNumber { return value.intValue }
            return nil
        }

        if flag("HTTPSEnable"), let host = host("HTTPSProxy"), let port = port("HTTPSPort") {
            return ["-c", "http.proxy=http://\(host):\(port)"]
        }
        if flag("HTTPEnable"), let host = host("HTTPProxy"), let port = port("HTTPPort") {
            return ["-c", "http.proxy=http://\(host):\(port)"]
        }
        if flag("SOCKSEnable"), let host = host("SOCKSProxy"), let port = port("SOCKSPort") {
            return ["-c", "http.proxy=socks5h://\(host):\(port)"]
        }
        return []
    }

    /// 给设置页显示的一行说明
    static func proxyDescription() -> String {
        let arguments = systemProxyArguments()
        guard let index = arguments.firstIndex(of: "http.proxy"), index + 1 < arguments.count else {
            return "直连"
        }
        return "系统代理 \(arguments[index + 1].replacingOccurrences(of: "http.proxy=", with: ""))"
    }

    /// 把 git 的原始报错翻译成能直接行动的中文
    static func friendlyMessage(for result: GitResult) -> String {
        let raw = result.shortError
        let text = raw.lowercased()

        if text.contains("authentication failed") || text.contains("could not read username") || text.contains("401") {
            return "认证失败：Token 无效或没有这个仓库的权限。到设置页点「从 gh 导入」或「验证连接」。"
        }
        if text.contains("http2 framing") || text.contains("http/2") {
            return "HTTP/2 连接被中间设备打断了。终端执行 git config --global http.version HTTP/1.1 后重试。"
        }
        if text.contains("write access to repository not granted") || text.contains("403") {
            return "Token 只有读权限，推送被拒绝。fine-grained token 要把 Contents 改成 Read and write；用 gh 的话运行 gh auth refresh -s repo。"
        }
        if text.contains("repository not found") || text.contains("404") {
            return "仓库不存在，或 Token 看不到它（fine-grained token 要在 Repository access 里勾选该仓库）。"
        }
        if text.contains("could not resolve host") || text.contains("network is unreachable") {
            return "网络不通：解析不到 github.com，检查代理或 VPN。"
        }
        if text.contains("permission denied (publickey)") {
            return "SSH 认证失败：检查 ssh key 是否已加到 GitHub。"
        }
        if text.contains("non-fast-forward") || text.contains("fetch first") {
            return "远端有你本地没有的提交，先拉取再推送（App 会自动重试一次）。"
        }
        return raw
    }

    static func exec(_ argv: [String], cwd: URL) throws -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.currentDirectoryURL = cwd

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/true"
        environment["GIT_PAGER"] = "cat"
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw GitError.launch(error.localizedDescription)
        }

        // 两个管道必须并发读，否则大输出会把子进程堵死
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        group.wait()
        process.waitUntilExit()

        return GitResult(
            code: process.terminationStatus,
            output: String(decoding: outBox.value, as: UTF8.self),
            error: String(decoding: errBox.value, as: UTF8.self)
        )
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
