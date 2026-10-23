import Foundation

/// Token 存储在 Application Support 下的 0600 文件里。
///
/// 为什么不用钥匙串：App 是 ad-hoc 签名，身份每次构建都会变，macOS 无法校验
/// 访问者身份，于是每次启动读 token 都会弹「想要使用钥匙串中的机密信息」。
/// 文件方案没有 ACL 校验，启动静默；代价是 token 以明文存在于本机，
/// 仅靠 POSIX 权限（0600）保护，同用户的其它进程理论上可读。
enum TokenStore {
    /// 测试用：把目录指到临时位置，避免污染真实配置
    static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("TongMD", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("credentials.json")
    }

    static func load() -> String {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["githubToken"] as? String else {
            return ""
        }
        return token
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if token.isEmpty {
                try? fileManager.removeItem(at: fileURL)
                return true
            }
            let json = try JSONSerialization.data(withJSONObject: ["githubToken": token], options: [.prettyPrinted])
            try json.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }
}
