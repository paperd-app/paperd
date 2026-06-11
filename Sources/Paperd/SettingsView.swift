import SwiftUI
import AppKit
import PaperdCore

/// 設定画面（→ docs/09 9節）。
/// 一般（politeプール用メール）/ 連携（S2 APIキー・MCPスニペット）/ ワーカーの最小構成。
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("mailto") private var mailto = ""
    @AppStorage("s2APIKey") private var s2APIKey = ""
    @AppStorage("workerDir") private var workerDir = ""
    @AppStorage("autoStartWorker") private var autoStartWorker = true
    @State private var lastAccessText: String?

    var body: some View {
        TabView(selection: $model.settingsTab) {
            generalTab
                .tabItem { Label("一般", systemImage: "gear") }
                .tag(AppModel.SettingsTab.general)
            integrationTab
                .tabItem { Label("連携", systemImage: "link") }
                .tag(AppModel.SettingsTab.integration)
            workerTab
                .tabItem { Label("ワーカー", systemImage: "cpu") }
                .tag(AppModel.SettingsTab.worker)
        }
        // 可変サイズ + 最小サイズ（固定サイズだと内容増で切れる → docs/09 9節）
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    }

    var generalTab: some View {
        Form {
            Section("ライブラリ") {
                LabeledContent("場所") {
                    Text(LibraryLayout.defaultRoot.path).textSelection(.enabled)
                }
            }
            Section("外部API") {
                TextField("メールアドレス（politeプール用）", text: $mailto)
                Text("Crossref / OpenAlex / Unpaywall へのリクエストに付与されます。設定変更はアプリ再起動後に反映されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    var integrationTab: some View {
        Form {
            Section("Semantic Scholar") {
                SecureField("APIキー（任意）", text: $s2APIKey)
                Text("引用グラフ取得のレートリミット緩和に推奨。x-api-keyヘッダで送信されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Claude連携（MCP）") {
                // 登録導線（→ docs/07 6節）
                LabeledContent("Claude Code") {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.mcpAddCommand, forType: .string)
                    } label: {
                        Label("登録コマンドをコピー", systemImage: "terminal")
                    }
                }
                Text(model.mcpAddCommand)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(2)
                LabeledContent("その他クライアント") {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.mcpSnippet, forType: .string)
                    } label: {
                        Label("設定スニペットをコピー", systemImage: "doc.on.clipboard")
                    }
                }
                Text("claude_desktop_config.json / .mcp.json に貼り付けると、Claudeからライブラリを検索・参照できます。")
                    .font(.caption).foregroundStyle(.secondary)
                // 接続の可視化（→ docs/07 6節）
                LabeledContent("最終アクセス") {
                    Text(lastAccessText ?? "記録なし（まだ接続されていません）")
                        .foregroundStyle(lastAccessText == nil ? .secondary : .primary)
                }
                .task {
                    while !Task.isCancelled {
                        lastAccessText = model.mcpLastAccessText
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                    }
                }
            }

            // Claudeスキル（→ docs/07 6.1節）
            Section("Claudeスキル") {
                SkillInstallSection()
            }

            // サンプルプロンプト（既定折りたたみ → docs/07 6.1節）
            Section {
                DisclosureGroup("試してみる（Claudeに貼り付け）") {
                    ForEach(SettingsView.samplePrompts, id: \.self) { prompt in
                        HStack(spacing: 6) {
                            Text(prompt).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(prompt, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc").font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help("コピー")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    var workerTab: some View {
        Form {
            Section("状態") {
                // 状態表示と自動起動（→ docs/09 9節）
                HStack(spacing: 10) {
                    WorkerIndicator()
                    Spacer()
                    switch model.workerStatus {
                    case .running:
                        Button("停止") { model.stopWorker() }.controlSize(.small)
                    case .stopped:
                        Button("起動") { model.startWorker() }.controlSize(.small)
                    case .notSetup:
                        EmptyView()
                    }
                }
                Toggle("アプリ起動時にワーカーを自動起動", isOn: $autoStartWorker)
                Text("ワーカーはPDF変換とSemantic検索を担うバックグラウンドプロセスです。通常は自動管理され、操作は不要です。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("セットアップ") {
                // uvの検出状態（GUIアプリのPATH問題対策 → docs/01 3.3節）
                if UVLocator.find() == nil {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("uv が見つかりません。ワーカーの実行にはuvが必要です。")
                            .font(.callout)
                        Spacer()
                        Button("インストールコマンドをコピー") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install uv", forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
                WorkerSetupView(workerDir: $workerDir)
            }
        }
        .formStyle(.grouped)
    }
}

/// Pythonワーカーのセットアップと起動（→ docs/01 3.3節の最小実装）。
/// フルのウィザード（進捗バー・中断再開）はv1リリース前の磨き込み課題。
struct WorkerSetupView: View {
    @Binding var workerDir: String
    @State private var log = ""
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("worker/ ディレクトリのパス", text: $workerDir)
                Button("選択…") { pickDirectory() }
            }
            HStack(spacing: 8) {
                Button("環境構築（uv sync --extra ml）") {
                    run(["uv", "sync", "--extra", "ml"])
                }
                .disabled(isRunning || workerDir.isEmpty)
                Button("ワーカーを起動") {
                    startWorker()
                }
                .disabled(isRunning || workerDir.isEmpty)
                if isRunning { ProgressView().controlSize(.small) }
            }
            Text("環境構築はDocling + PyTorchで2〜3GBのダウンロードを伴います。embeddingモデル（bge-m3、約2GB）は初回利用時に取得されます。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(log.isEmpty ? "ログ出力" : log)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 140)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            workerDir = url.path
        }
    }

    func run(_ command: [String]) {
        isRunning = true
        log = "$ \(command.joined(separator: " "))\n"
        let dir = workerDir
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    await MainActor.run { log += line + "\n" }
                }
                process.waitUntilExit()
                let status = process.terminationStatus
                await MainActor.run {
                    log += status == 0 ? "✅ 完了\n" : "❌ 終了コード \(status)\n"
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    log += "❌ \(error)\n"
                    isRunning = false
                }
            }
        }
    }

    /// worker.lock経由の常駐起動。アプリ終了後もMCPから再利用される
    func startWorker() {
        let dir = workerDir
        log = "ワーカーを起動中…\n"
        isRunning = true
        Task.detached {
            do {
                let manager = WorkerProcessManager(workerDirectory: URL(fileURLWithPath: dir))
                let client = try await manager.startOrReuseVerified()
                let health = try await client.health()
                await MainActor.run {
                    log += "✅ 起動: \(client.baseURL) (model_loaded: \(health.modelLoaded))\n"
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    log += "❌ \(error)\n"
                    isRunning = false
                }
            }
        }
    }
}

extension SettingsView {
    static let samplePrompts = [
        "ライブラリから分極スイッチングに関する論文を探して、要点を比較して",
        "「Attention is All you Need」の手法の章を全文から要約して",
        "強誘電体について文献調査して。重要な未所持論文があれば提案して",
        "この論文の変換ミスをPDFと照合して修正して",
    ]
}

/// Claudeスキルのインストール（→ docs/07 6.1節）
struct SkillInstallSection: View {
    @State private var installer: SkillInstaller?
    @State private var status: SkillInstaller.Status = .notInstalled
    @State private var skills: [String] = []
    @State private var showConfirm = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Claudeスキル").font(.callout.weight(.medium))
                Spacer()
                statusBadge
                Button(buttonTitle) { showConfirm = true }
                    .controlSize(.small)
                    .disabled(installer == nil || skills.isEmpty || status == .installed)
            }
            Text(skills.isEmpty
                 ? "（このビルドにはスキルが同梱されていません）"
                 : "文献調査・変換修正・執筆引用の定型ワークフロー（\(skills.joined(separator: " / "))）をClaude Codeのスキルとしてインストールします。")
                .font(.caption).foregroundStyle(.secondary)
            if let message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "\(skills.count) 個のスキルをインストールしますか？",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("インストール") { install() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("~/.claude/skills/ に書き込まれます（既存の同名スキルは上書き）。Claude Codeの次回起動から有効になります。")
        }
    }

    var buttonTitle: String {
        switch status {
        case .notInstalled: return "インストール…"
        case .needsUpdate: return "更新…"
        case .installed: return "インストール済み"
        }
    }

    @ViewBuilder
    var statusBadge: some View {
        switch status {
        case .installed:
            Label("インストール済み", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .needsUpdate:
            Label("更新あり", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.orange)
        case .notInstalled:
            EmptyView()
        }
    }

    func reload() {
        guard let resources = Bundle.main.resourceURL else { return }
        let source = resources.appendingPathComponent("skills")
        let inst = SkillInstaller(sourceDir: source)
        installer = inst
        skills = inst.bundledSkills()
        status = inst.overallStatus()
    }

    func install() {
        guard let installer else { return }
        do {
            try installer.installAll()
            status = installer.overallStatus()
            message = "インストールしました（\(SkillInstaller.defaultDestDir.path)）"
        } catch {
            message = nil
        }
    }
}
