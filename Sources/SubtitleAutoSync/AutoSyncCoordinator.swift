// AutoSyncCoordinator.swift
//
// 把 SubtitleAutoSyncEngine 接到播放器上。播放器相关的部分用 AutoSyncPlayer 协议表示。
//
// 流程（与 DexWorld 插件相同）：
//   1. 打开视频时调用 mediaDidOpen，说明参照从哪里来（FFmpeg 索引 / HTTP Range / 不做）。
//   2. 外挂字幕开始显示后调用 subtitleDidLoad（播放不等待）。
//   3. 后台同步；只有结果为 .synced 并且用户在此期间没有换字幕，才替换。
//   4. 用户自己选的字幕：任何结果都提示；自动选的字幕：只在真正同步了时提示。
import Foundation

/// 播放器需要提供的能力（在主线程调用）。
@MainActor
public protocol AutoSyncPlayer: AnyObject {
    /// 当前显示的外挂字幕 ID（slot 0 主字幕，1 副字幕），没有则为 nil。
    func currentExternalSubtitleID(slot: Int) -> String?
    /// 用改好时间的字幕替换当前字幕（不要重新从网络下载）。
    func replaceExternalSubtitle(slot: Int, id: String, data: Data, fileName: String)
    /// 清掉用户手动调过的字幕延迟（自动同步后从 0 开始）。
    func resetManualSubtitleDelay(slot: Int)
    func showToast(_ text: String)
}

@MainActor
public final class AutoSyncCoordinator {

    /// 参照从哪里来。
    public enum ReferenceMode: Sendable {
        /// 播放器自己的 FFmpeg 索引（推荐）：等 setFFmpegReference，不另开连接。
        case ffmpegIndex
        /// 引擎自己用 HTTP Range 读 MKV 的 Cues（拿不到 AVFormatContext 的引擎用）。
        case httpRange
        /// 不做自动同步（直播、IPTV、HLS 等）。
        case disabled
    }

    public let engine: SubtitleAutoSyncEngine
    public weak var player: AutoSyncPlayer?
    /// 字幕比索引先到时，最多等多久（秒）。
    public var referenceWaitTimeout: TimeInterval = 20

    private var media: MediaSource?
    private var mode: ReferenceMode = .disabled
    private var ffmpegReference: ReferenceLookup?
    private var waiters: [UUID: CheckedContinuation<ReferenceLookup?, Never>] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var generation: [Int: Int] = [:]

    /// Language of the toast messages (en / ar / zh).
    public var language: AutoSyncLanguage

    public init(engine: SubtitleAutoSyncEngine = SubtitleAutoSyncEngine(), player: AutoSyncPlayer?,
                language: AutoSyncLanguage = .en) {
        self.engine = engine
        self.player = player
        self.language = language
    }

    // MARK: 播放器调用

    /// 打开新视频时调用。media.cacheKey 建议用服务器上的稳定 ID（地址里常带临时 token）。
    public func mediaDidOpen(_ media: MediaSource, mode: ReferenceMode) {
        mediaDidClose()
        self.media = media
        self.mode = media.isLive ? .disabled : mode
    }

    /// 关闭视频或换视频时调用。
    public func mediaDidClose() {
        for t in tasks.values { t.cancel() }
        tasks.removeAll()
        resumeWaiters(with: nil)
        media = nil
        mode = .disabled
        ffmpegReference = nil
    }

    /// 解复用线程读完索引后（回到主线程）调用。starts 为 nil 表示视频里没有可用的参照。
    public func setFFmpegReference(_ starts: [Int]?, description: String = "") {
        let value: ReferenceLookup = starts.map {
            .ready(ReferenceTimeline(starts: $0, source: "ffmpeg-index", trackDescription: description))
        } ?? .failed(reason: "no_usable_text_track", detail: nil)
        ffmpegReference = value
        resumeWaiters(with: value)
    }

    /// 外挂字幕已经开始显示后调用。userInitiated：用户自己在列表里选的。
    public func subtitleDidLoad(slot: Int, id: String, data: Data, fileName: String, userInitiated: Bool) {
        start(slot: slot, id: id, data: data, fileName: fileName, userInitiated: userInitiated, policy: .use)
    }

    /// 字幕菜单里的“同步当前字幕”按钮：同步过的直接用，未同步的结果重新算，任何结果都提示。
    public func syncNow(slot: Int, id: String, data: Data, fileName: String) {
        if mode == .disabled {
            player?.showToast(AutoSyncMessages.text(.notSupported, language: language, userInitiated: true) ?? "")
            return
        }
        start(slot: slot, id: id, data: data, fileName: fileName, userInitiated: true, policy: .ignoreNegative)
    }

    // MARK: 内部

    private func start(slot: Int, id: String, data: Data, fileName: String, userInitiated: Bool, policy: CachePolicy) {
        guard let media, mode != .disabled else { return }
        let gen = (generation[slot] ?? 0) + 1
        generation[slot] = gen
        tasks[slot]?.cancel()   // 最后一次选择为准
        let mode = self.mode
        let engine = self.engine
        let language = self.language
        tasks[slot] = Task { [weak self] in
            let outcome: AutoSyncOutcome
            switch mode {
            case .ffmpegIndex:
                guard let lookup = await self?.waitForReference() else { return }
                switch lookup {
                case .ready(let ref):
                    outcome = await engine.synchronize(subtitle: data, fileName: fileName, reference: ref,
                                                       cacheKey: media.resultKey, cachePolicy: policy)
                case .failed(let reason, _):
                    outcome = .noReference(reason: reason)
                }
            case .httpRange:
                outcome = await engine.synchronize(subtitle: data, fileName: fileName, media: media, cachePolicy: policy)
            case .disabled:
                return
            }
            guard !Task.isCancelled, let self, self.generation[slot] == gen,
                  let player = self.player, player.currentExternalSubtitleID(slot: slot) == id else { return }
            if case .synced(let s) = outcome {
                player.replaceExternalSubtitle(slot: slot, id: id, data: s.data, fileName: fileName)
                player.resetManualSubtitleDelay(slot: slot)
            }
            if let text = AutoSyncMessages.text(outcome, language: language, userInitiated: userInitiated,
                                                  minMatch: engine.configuration.minMatch) {
                player.showToast(text)
            }
        }
    }

    /// 等 FFmpeg 索引的结果；超时或视频已关闭返回“读不到”。
    private func waitForReference() async -> ReferenceLookup? {
        if let ffmpegReference { return ffmpegReference }
        let timeout = referenceWaitTimeout
        let id = UUID()
        let value: ReferenceLookup? = await withCheckedContinuation { cont in
            waiters[id] = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.resumeWaiter(id, with: .failed(reason: "timeout", detail: "ffmpeg index"))
            }
        }
        return value
    }

    private func resumeWaiter(_ id: UUID, with value: ReferenceLookup?) {
        waiters.removeValue(forKey: id)?.resume(returning: value)
    }

    private func resumeWaiters(with value: ReferenceLookup?) {
        let all = waiters
        waiters.removeAll()
        for cont in all.values { cont.resume(returning: value) }
    }
}

/// 提示文字（简体中文）。其他语言照此翻译即可。
public enum AutoSyncMessages {
    public static func zh(_ outcome: AutoSyncOutcome, userInitiated: Bool, minMatch: Double = 0.45) -> String? {
        switch outcome {
        case .synced(let s):
            return s.fromCache ? "已应用这份字幕之前同步好的版本" : "字幕已自动同步：" + s.alignment.summaryZh
        case _ where !userInitiated:
            return nil   // 自动选的字幕：只有同步成功才提示
        case .alreadyInSync(let r):
            return "字幕本来就是同步的（匹配 \(pct(r.matched))%）"
        case .unsure(let r):
            if r.hits == 0 { return "字幕和视频对不上，保留原字幕" }
            if r.matched < minMatch {
                return "匹配只有 \(pct(r.matched))%，低于要求的 \(pct(minMatch))%，可能是其他版本的字幕，保留原字幕"
            }
            return "匹配 \(pct(r.matched))%，但不够明确，保留原字幕"
        case .differentCut:
            return "字幕和这个视频的剪辑版本不同（片中有一段对不上），保留原字幕"
        case .tooFewLines(let n):
            return "字幕只有 \(n) 行，不足以自动同步"
        case .noReference(let reason):
            return reasonText(reason) + "，保留原字幕"
        case .notSupported:
            return "直播流或无法读取索引的播放地址，不做自动同步"
        case .invalidSubtitle:
            return "无法读取字幕文件"
        }
    }

    public static func reasonText(_ reason: String) -> String {
        switch reason {
        case "not_mkv": return "视频不是 MKV，没有可读的字幕索引"
        case "no_subtitle_tracks": return "视频里没有内嵌字幕可作参照"
        case "no_usable_subtitles", "no_usable_text_track": return "视频里的内嵌字幕太少或不能作参照"
        case "no_range": return "服务器不支持分段读取（Range）"
        case "cues_too_large", "element_too_large": return "视频索引太大"
        case "no_cues", "no_segment", "unknown_size", "truncated", "short_file", "no_tracks": return "视频索引不完整"
        default: return "暂时读不到视频索引"
        }
    }

    static func pct(_ x: Double) -> Int { Int((x * 100).rounded()) }
}
