import Foundation

/// 从 gh CLI 拿现成的 token。
/// GUI 应用从 Finder 启动时 PATH 很窄，不能指望 `gh` 在 PATH 里，所以直接找常见安装位置。
enum GhCLI {
    static func executablePath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/opt/local/bin/gh",
            "/usr/bin/gh"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isAvailable() -> Bool {
        executablePath() != nil
    }

    static func token() throws -> String {
        guard let path = executablePath() else {
            throw GhError.notInstalled
        }
        let result = try GitEngine.exec([path, "auth", "token"], cwd: FileManager.default.temporaryDirectory)
        let value = result.output.trimmed
        guard result.ok, !value.isEmpty else {
            throw GhError.notLoggedIn
        }
        return value
    }

    enum GhError: LocalizedError {
        case notInstalled
        case notLoggedIn

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "没找到 gh CLI。可以安装（brew install gh）后点这个按钮，或直接去网页创建 Token。"
            case .notLoggedIn:
                return "gh 还没登录。先在终端运行 gh auth login，再回来点「从 gh 导入」。"
            }
        }
    }
}
