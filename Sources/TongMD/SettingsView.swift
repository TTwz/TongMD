import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("笔记库") {
                    LabeledContent("文件夹") {
                        Text(model.vaultPath ?? "未选择")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(model.vaultPath == nil ? .secondary : .primary)
                    }
                    HStack {
                        Button("选择文件夹…") { model.pickVaultFolder() }
                        Button("克隆仓库到此…") { model.cloneRepo() }
                        Spacer()
                        if !model.branch.isEmpty {
                            Text("分支 \(model.branch)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("GitHub") {
                    TextField(
                        "仓库地址",
                        text: $model.repoURLString,
                        prompt: Text("https://github.com/用户名/仓库.git")
                    )
                    .textFieldStyle(.roundedBorder)

                    SecureField(
                        "Personal Access Token",
                        text: $model.token,
                        prompt: Text("粘贴 ghp_… 或 github_pat_…（用 SSH 地址时可以留空）")
                    )
                    .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Button("打开 Token 页面") { model.openTokenPage() }
                        Button("从 gh 导入") { model.importTokenFromGh() }
                        Button("验证连接") { model.testConnection() }
                            .disabled(model.repoURLString.trimmed.isEmpty || model.isBusy)
                        Button("清除") { model.clearToken() }
                            .disabled(model.token.isEmpty)
                        Spacer()
                    }

                    DisclosureGroup("不知道 Token 从哪拿？") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("方式一：用 gh CLI（最省事）")
                                .font(.caption.weight(.semibold))
                            Text("终端运行一次 `gh auth login`（选 GitHub.com → HTTPS → 浏览器登录）。回到这里点「从 gh 导入」，Token 会自动填好，有效期跟 gh 走。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("方式二：网页创建 fine-grained token")
                                .font(.caption.weight(.semibold))
                                .padding(.top, 2)
                            Text("1. 点上面的「打开 Token 页面」\n2. Repository access 选 Only select repositories，勾选笔记仓库\n3. Permissions → Repository permissions → Contents 设为 Read and write\n4. Generate token，复制以 ghp_ 或 github_pat_ 开头的那串")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("方式三：用 SSH 地址")
                                .font(.caption.weight(.semibold))
                                .padding(.top, 2)
                            Text("如果本机已经有 GitHub 的 SSH key，仓库地址填 git@github.com:用户名/仓库.git，Token 留空即可，git 会走 ssh-agent。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }

                    Text("Token 存在 ~/Library/Application Support/TongMD/credentials.json（权限 600，仅当前用户可读），只在 clone/pull/push 时通过 http.extraheader 临时传给 git，不会写进 .git/config。改用文件是为了避开 ad-hoc 签名导致的钥匙串授权弹窗。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("保存后自动本地提交", isOn: $model.autoCommit)
                    Text("只 commit 不 push；推送仍然手动按 ⇧⌘S，避免写两句话就产生一次远程提交。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("附件与体积") {
                    LabeledContent("附件") {
                        Text("\(model.attachmentStats.count) 个 · \(model.attachmentStats.formattedTotal)")
                            .foregroundStyle(.secondary)
                    }
                    if model.attachmentStats.count > 0 {
                        LabeledContent("最大") {
                            Text("\(model.attachmentStats.largestName) · \(model.attachmentStats.formattedLargest)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(model.attachmentStats.isLarge
                         ? "附件偏大，git 仓库会跟着膨胀。建议压缩图片，或把大附件放到独立仓库 / 对象存储，必要时用 Git LFS。"
                         : "粘贴图片会自动存到当前笔记所在目录的 assets/ 下，并以相对路径引用；单个文件超过 10MB 或总量超过 100MB 时这里会提醒。")
                        .font(.caption)
                        .foregroundStyle(model.attachmentStats.isLarge ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("现有文件夹") {
                    HStack {
                        Button("初始化为 git 仓库") { model.initRepoHere() }
                            .disabled(model.vaultURL == nil)
                        Text("会用上面填的地址作为 origin（如果填了）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("同步状态") {
                    Text("网络：\(GitEngine.proxyDescription())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.syncState.color)
                            .frame(width: 6, height: 6)
                        Text(model.syncState.text)
                            .font(.callout)
                            .foregroundStyle(model.syncState.isFailure ? .red : .secondary)
                            .lineLimit(2)
                        Spacer()
                    }
                    if model.vaultURL != nil {
                        Button("立即同步") { model.sync() }
                            .disabled(model.isBusy)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 520)
        .onAppear { model.refreshAttachmentStatsNow() }
    }
}
