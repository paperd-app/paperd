import SwiftUI
import PaperdCore

/// 処理中リストの未選択画面: ジョブモニタ（→ docs/09 4.2節）。
/// ステータスバーのポップオーバーと違い、一括取り込みの進捗を常設で眺める場所。
struct JobMonitorView: View {
    @EnvironmentObject var model: AppModel

    static let ingestStages = ["resolve", "fetch", "convert", "chunk", "embed", "index"]

    var running: [Job] { model.activeJobs.filter { $0.jobStatus == .running } }
    var queued: [Job] { model.activeJobs.filter { $0.jobStatus == .queued } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("処理中のジョブ")
                    .font(.largeTitle.bold())
                    .padding(.top, 8)

                if model.activeJobs.isEmpty && model.failedJobs.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("処理中のジョブはありません").foregroundStyle(.secondary)
                    }
                    .font(.title3)
                    .padding(.top, 12)
                }

                if !running.isEmpty {
                    sectionHeader(String(localized: "実行中"), count: running.count)
                    ForEach(running, id: \.id) { job in
                        runningCard(job)
                    }
                }

                if !queued.isEmpty {
                    sectionHeader(String(localized: "待機中"), count: queued.count)
                    ForEach(queued, id: \.id) { job in
                        HStack {
                            Image(systemName: "clock").foregroundStyle(.tertiary).font(.caption)
                            Text(title(of: job)).lineLimit(1)
                            Spacer()
                            Text(kindLabel(job.kind)).font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                if !model.failedJobs.isEmpty {
                    HStack {
                        sectionHeader(String(localized: "失敗"), count: model.failedJobs.count)
                        Spacer()
                        Button("すべて無視") { model.dismissAllFailedJobs() }
                            .controlSize(.small)
                    }
                    ForEach(model.failedJobs, id: \.id) { job in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title(of: job)).lineLimit(1)
                            if let error = job.lastError {
                                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                            }
                            HStack {
                                Button("再試行") { model.retryJob(job.id) }.controlSize(.small)
                                Button("無視") { model.dismissFailedJob(job.id) }.controlSize(.small)
                            }
                        }
                        .padding(10)
                        .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                Divider()
                WorkerIndicator()
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    func sectionHeader(_ title: String, count: Int) -> some View {
        Text("\(title)（\(count)件）").font(.headline)
    }

    func runningCard(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView().controlSize(.small)
                Text(title(of: job)).fontWeight(.medium).lineLimit(1)
                Spacer()
                Text(elapsed(of: job)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if job.kind == "ingest" {
                stageProgress(completed: job.stage)
            } else {
                Text(kindLabel(job.kind)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    /// ステージのプログレス表示（→ docs/09 4.2節）
    func stageProgress(completed: String?) -> some View {
        let completedIndex = completed.flatMap { Self.ingestStages.firstIndex(of: $0) } ?? -1
        return HStack(spacing: 4) {
            ForEach(Array(Self.ingestStages.enumerated()), id: \.offset) { index, stage in
                HStack(spacing: 4) {
                    Text(stage)
                        .font(.caption2)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(
                            index <= completedIndex ? Color.green.opacity(0.25)
                                : index == completedIndex + 1 ? Color.accentColor.opacity(0.25)
                                : Color.gray.opacity(0.12),
                            in: Capsule())
                        .foregroundStyle(
                            index <= completedIndex ? .primary
                                : index == completedIndex + 1 ? .primary : .secondary)
                    if index < Self.ingestStages.count - 1 {
                        Image(systemName: "chevron.right").font(.system(size: 7)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    func title(of job: Job) -> String {
        if let paperId = job.paperId,
           let paper = model.papers.first(where: { $0.id == paperId }) {
            return paper.title
        }
        if let data = job.payload.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            if let input = dict["input"] { return input }
            if let path = dict["pdf_path"] { return URL(fileURLWithPath: path).lastPathComponent }
        }
        return kindLabel(job.kind)
    }

    func kindLabel(_ kind: String) -> String {
        switch kind {
        case "ingest": return String(localized: "取り込み")
        case "reindex": return String(localized: "検索インデックス更新")
        case "reconvert": return String(localized: "高精度再変換")
        case "refetch_citations": return String(localized: "引用情報の取得")
        default: return kind
        }
    }

    func elapsed(of job: Job) -> String {
        guard let created = PaperdDates.date(from: job.createdAt) else { return "" }
        let seconds = Int(Date().timeIntervalSince(created))
        if seconds < 60 { return String(localized: "\(seconds)秒") }
        return String(localized: "\(seconds / 60)分\(seconds % 60)秒")
    }
}
