import SwiftUI
import AppKit
import PaperdCore

/// 設定画面（→ docs/09 9節）。
/// 一般（politeプール用メール）/ 連携（S2 APIキー・MCPスニペット）/ ワーカーの最小構成。
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("mailto") private var mailto = ""
    @AppStorage("s2APIKey") private var s2APIKey = ""
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
                    Text(lastAccessText ?? String(localized: "記録なし（まだ接続されていません）"))
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

            // Claudeエージェント（文献調査オーケストレーションのサブエージェント → docs/07 6.2節, docs/12）
            Section("Claudeエージェント") {
                AgentInstallSection()
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
                // Python 3.11+ の検出状態（GUIアプリのPATH問題対策 → docs/01 3.3節）
                if PythonLocator.find() == nil {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Python 3.11+ が見つかりません。ワーカーの実行に必要です。")
                            .font(.callout)
                        Spacer()
                        Button("インストールコマンドをコピー") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install python@3.11", forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
                WorkerSetupView()
            }
        }
        .formStyle(.grouped)
    }
}

/// Pythonワーカーのセットアップと起動（→ docs/01 3.3節の最小実装）。
/// worker パスは AppModel が起動時に 1 回解決し、ここでは EnvironmentObject から参照する。
/// セットアップ手順は PaperdCore の `WorkerEnvironmentSetup` に集約。
/// フルのウィザード（進捗バー・中断再開）はv1リリース前の磨き込み課題。
struct WorkerSetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var log = ""
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("worker パス") {
                Text(model.workerDirectory?.path ?? String(localized: "未検出"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(model.workerDirectory == nil ? .secondary : .primary)
            }
            HStack(spacing: 8) {
                Button("環境構築（venv + pip install）") {
                    setupVenv()
                }
                .disabled(isRunning || model.workerDirectory == nil)
                Button("ワーカーを起動") {
                    startWorker()
                }
                .disabled(isRunning || model.workerDirectory == nil)
                if isRunning { ProgressView().controlSize(.small) }
            }
            Text("環境構築はDocling + PyTorchで2〜3GBのダウンロードを伴います。embeddingモデル（bge-m3、約2GB）は初回利用時に取得されます。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(log.isEmpty ? String(localized: "ログ出力") : log)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 140)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// `WorkerEnvironmentSetup.run()` を呼んでログをストリーミング表示
    func setupVenv() {
        guard let workerDir = model.workerDirectory else {
            log = String(localized: "❌ worker パスが解決できません。\n")
            return
        }
        guard let python = PythonLocator.find() else {
            log = String(localized: "❌ Python 3.11+ が見つかりません。上の案内に従ってインストールしてください。\n")
            return
        }
        let setup = WorkerEnvironmentSetup(workerDir: workerDir, python: python)
        isRunning = true
        log = "$ Python: \(python)\n$ worker: \(workerDir.path)\n"
        Task.detached {
            do {
                try await setup.run { line in
                    Task { @MainActor in log += line + "\n" }
                }
                await MainActor.run {
                    log += String(localized: "✅ 完了\n")
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    log += "❌ \(error.localizedDescription)\n"
                    isRunning = false
                }
            }
        }
    }

    /// worker.lock経由の常駐起動。アプリ終了後もMCPから再利用される
    func startWorker() {
        guard let workerDir = model.workerDirectory else {
            log = String(localized: "❌ worker パスが解決できません。\n")
            return
        }
        log = String(localized: "ワーカーを起動中…\n")
        isRunning = true
        Task.detached {
            do {
                let manager = WorkerProcessManager(workerDirectory: workerDir)
                let client = try await manager.startOrReuseVerified()
                let health = try await client.health()
                await MainActor.run {
                    log += String(localized: "✅ 起動: \(client.baseURL.absoluteString) (model_loaded: \(String(describing: health.modelLoaded)))\n")
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
        String(localized: "ライブラリから分極スイッチングに関する論文を探して、要点を比較して"),
        String(localized: "「Attention is All you Need」の手法の章を全文から要約して"),
        String(localized: "強誘電体について文献調査して。重要な未所持論文があれば提案して"),
        String(localized: "この論文の変換ミスをPDFと照合して修正して"),
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
                 ? String(localized: "（このビルドにはスキルが同梱されていません）")
                 : String(localized: "文献調査・変換修正・執筆引用の定型ワークフロー（\(skills.joined(separator: " / "))）をClaude Codeのスキルとしてインストールします。"))
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
        case .notInstalled: return String(localized: "インストール…")
        case .needsUpdate: return String(localized: "更新…")
        case .installed: return String(localized: "インストール済み")
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
            message = String(localized: "インストールしました（\(SkillInstaller.defaultDestDir.path)）")
        } catch {
            message = nil
        }
    }
}

/// Claudeサブエージェント定義のインストール（→ docs/07 6.2節）。SkillInstallSection と対称。
struct AgentInstallSection: View {
    @State private var installer: AgentInstaller?
    @State private var status: AgentInstaller.Status = .notInstalled
    @State private var agents: [String] = []
    @State private var showConfirm = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Claudeエージェント").font(.callout.weight(.medium))
                Spacer()
                statusBadge
                Button(buttonTitle) { showConfirm = true }
                    .controlSize(.small)
                    .disabled(installer == nil || agents.isEmpty || status == .installed)
            }
            Text(agents.isEmpty
                 ? String(localized: "（このビルドにはエージェントが同梱されていません）")
                 : String(localized: "専門サブエージェント（\(agents.joined(separator: " / "))）をClaude Codeのエージェントとしてインストールします。"))
                .font(.caption).foregroundStyle(.secondary)
            if let message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "\(agents.count) 個のエージェントをインストールしますか？",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("インストール") { install() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("~/.claude/agents/ に書き込まれます（既存の同名エージェントは上書き）。Claude Codeの次回起動から有効になります。")
        }
    }

    var buttonTitle: String {
        switch status {
        case .notInstalled: return String(localized: "インストール…")
        case .needsUpdate: return String(localized: "更新…")
        case .installed: return String(localized: "インストール済み")
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
        let source = resources.appendingPathComponent("agents")
        let inst = AgentInstaller(sourceDir: source)
        installer = inst
        agents = inst.bundledAgents()
        status = inst.overallStatus()
    }

    func install() {
        guard let installer else { return }
        do {
            try installer.installAll()
            status = installer.overallStatus()
            message = String(localized: "インストールしました（\(AgentInstaller.defaultDestDir.path)）")
        } catch {
            message = nil
        }
    }
}
