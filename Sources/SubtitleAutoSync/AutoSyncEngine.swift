import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 正在播放的视频：地址 + 播放时用的请求头（token、Cookie、User-Agent 等）。
public struct MediaSource: Hashable, Sendable {
    public var url: URL
    public var headers: [String: String]
    /// 稳定的缓存键，例如 "emby:<itemId>:<mediaSourceId>"。地址里带临时 token 时一定要设，否则缓存永远命中不了。
    public var cacheKey: String?
    /// 直播、IPTV 等不能另开连接读索引的源。为 true 时引擎不会发任何请求。
    public var isLive: Bool

    public init(url: URL, headers: [String: String] = [:], cacheKey: String? = nil, isLive: Bool = false) {
        self.url = url
        self.headers = headers
        self.cacheKey = cacheKey
        self.isLive = isLive
    }

    /// 能否自己读容器索引：http(s) 或本地文件可以；直播、HLS/DASH 播放列表、ISO、strm 不行。
    public var isIndexable: Bool {
        if isLive { return false }
        let low = url.absoluteString.lowercased()
        let path = low.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? low
        if [".m3u8", ".mpd", ".iso", ".strm", ".ts"].contains(where: { path.hasSuffix($0) }) || low.contains("/master.m3u8") {
            return false
        }
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" || scheme == "file" {
            return true
        }
        return false
    }

    /// 结果缓存用的键。
    public var resultKey: String { cacheKey ?? url.absoluteString }
}

/// 参照时间轴：视频里某条内嵌字幕每一行的开始时间（毫秒）。
public struct ReferenceTimeline: Sendable {
    public var starts: [Int]
    /// "mkv-cues"、"ffmpeg-index"、"custom"
    public var source: String
    public var trackDescription: String

    public init(starts: [Int], source: String = "custom", trackDescription: String = "") {
        self.starts = starts.sorted()
        self.source = source
        self.trackDescription = trackDescription
    }
}

public enum ReferenceLookup: Sendable {
    case ready(ReferenceTimeline)
    case failed(reason: String, detail: String?)
}

public struct SyncedSubtitle: Sendable {
    /// 改好时间的字幕文件（原编码、原格式）。
    public var data: Data
    public var alignment: AlignmentResult
    public var fromCache: Bool
}

public enum AutoSyncOutcome: Sendable {
    /// 已对齐：用 data 替换正在显示的字幕。
    case synced(SyncedSubtitle)
    /// 本来就同步（移动不到 250 ms），保持原样。
    case alreadyInSync(AlignmentResult)
    /// 匹配度不够或不明确（多半是别的片子或别的版本的字幕），保持原样。
    case unsure(AlignmentResult)
    /// 大部分对得上，但前中后某一段明显属于另一个偏移：字幕和视频的剪辑版本不同，保持原样。
    case differentCut(AlignmentResult, SubtitleAligner.SegmentCheck)
    /// 字幕行数太少，没法可靠对齐。
    case tooFewLines(Int)
    /// 视频里没有可用的参照（不是 MKV、没有内嵌字幕、服务器不支持 Range 等）。
    case noReference(reason: String)
    /// 播放源不支持（直播、HLS/DASH 等）。
    case notSupported
    /// 字幕文件为空或太大。
    case invalidSubtitle
}

/// 结果缓存怎么用。
public enum CachePolicy: Sendable {
    /// 默认：同一份字幕在同一视频上直接返回上次的结果。
    case use
    /// 手动按钮（DexWorld 的“同步当前字幕”）：同步过的直接用，其余结果（未同步、本来同步）重新算。
    case ignoreNegative
    /// 完全重新计算。
    case bypass
}

/// 自动同步引擎（流程与 DexWorld 插件 autosync.py 一致，另加三段一致性检查）：
///
/// 1. 解析外挂字幕的开始时间，少于 30 行直接放弃（发网络请求前先做这个检查）。
/// 2. 取参照时间轴（MKV Cues；同一视频缓存 30 分钟，换字幕不重复读）。
/// 3. 对齐 + 安全决策；决策为 sync 时再做三段一致性检查，通过才改写时间戳。
/// 4. 结果按“字幕内容 + 视频”缓存（只在内存里，App 可以自己持久化）。
///
/// 引擎本身不碰播放器：调用方先立即显示原字幕，拿到 `.synced` 后再替换（并确认用户没有换字幕）。
public actor SubtitleAutoSyncEngine {

    public struct Configuration: Sendable {
        /// 最低匹配比例（DexWorld 默认 45%）。
        public var minMatch = 0.45
        /// 三段一致性检查（默认开）。关掉后与 DexWorld 原版行为完全一致。
        public var segmentCheck = true
        public var minSubtitleLines = 30
        public var maxSubtitleBytes = 8 << 20
        public var referenceOKTTL: TimeInterval = 30 * 60
        public var referenceFailTTL: TimeInterval = 10 * 60
        public var referenceTransientTTL: TimeInterval = 60
        public var maxCachedReferences = 6
        public var maxCachedResults = 64
        public var cuesOptions = MatroskaCues.Options()
        public init() {}
    }

    public nonisolated let configuration: Configuration
    private var references: [MediaSource: (expires: Date, value: ReferenceLookup)] = [:]
    private var inflight: [MediaSource: Task<ReferenceLookup, Never>] = [:]
    private var results: [String: (stamp: Date, value: AutoSyncOutcome)] = [:]

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: 主入口

    /// 对一份外挂字幕做自动同步。参照由引擎自己用 HTTP Range 读 MKV 的 Cues。
    public func synchronize(subtitle: Data, fileName: String, media: MediaSource,
                            cachePolicy: CachePolicy = .use) async -> AutoSyncOutcome {
        guard media.isIndexable else { return .notSupported }
        return await run(subtitle: subtitle, fileName: fileName, cacheKey: media.resultKey, policy: cachePolicy) {
            await self.reference(for: media)
        }
    }

    /// 已经拿到参照时间轴时（例如从播放器自己的 FFmpeg 索引读出），直接对齐。
    /// cacheKey 用视频的稳定标识（见 MediaSource.cacheKey）；为 nil 时不缓存结果。
    public func synchronize(subtitle: Data, fileName: String, reference: ReferenceTimeline,
                            cacheKey: String?, cachePolicy: CachePolicy = .use) async -> AutoSyncOutcome {
        await run(subtitle: subtitle, fileName: fileName, cacheKey: cacheKey, policy: cachePolicy) {
            .ready(reference)
        }
    }

    /// 取参照时间轴（带缓存；同一视频的并发请求只读一次）。
    public func reference(for media: MediaSource) async -> ReferenceLookup {
        if let hit = references[media], hit.expires > Date() { return hit.value }
        if let task = inflight[media] { return await task.value }
        let options = configuration.cuesOptions
        let task = Task<ReferenceLookup, Never> {
            await Self.loadReference(media: media, options: options)
        }
        inflight[media] = task
        let value = await task.value
        inflight[media] = nil
        let ttl: TimeInterval
        switch value {
        case .ready:
            ttl = configuration.referenceOKTTL
        case .failed(let reason, _):
            if reason == "cancelled" { return value }   // 取消的不缓存
            ttl = CuesError(reason).isTransient ? configuration.referenceTransientTTL : configuration.referenceFailTTL
        }
        references[media] = (Date().addingTimeInterval(ttl), value)
        while references.count > configuration.maxCachedReferences,
              let oldest = references.min(by: { $0.value.expires < $1.value.expires })?.key {
            references[oldest] = nil
        }
        return value
    }

    /// 清空缓存（例如切换服务器账号时）。
    public func clearCaches() {
        references.removeAll()
        results.removeAll()
    }

    // MARK: 内部

    private func run(subtitle: Data, fileName: String, cacheKey: String?, policy: CachePolicy,
                     reference: () async -> ReferenceLookup) async -> AutoSyncOutcome {
        if subtitle.isEmpty || subtitle.count > configuration.maxSubtitleBytes { return .invalidSubtitle }
        let raw = [UInt8](subtitle)
        let key = cacheKey.map { "\(Self.fnv1a(raw)):\($0)" }
        if let key, let hit = results[key] {
            switch (policy, hit.value) {
            case (.bypass, _):
                break
            case (_, .synced(var s)):
                s.fromCache = true
                return .synced(s)
            case (.use, let cached):
                return cached
            default:
                break
            }
        }
        let minLines = configuration.minSubtitleLines
        let starts = await Task.detached(priority: .utility) {
            SubtitleTiming.parseStarts(raw, name: fileName)
        }.value
        if starts.count < minLines { return .tooFewLines(starts.count) }

        let ref: ReferenceTimeline
        switch await reference() {
        case .ready(let r): ref = r
        case .failed(let reason, _): return .noReference(reason: reason)
        }
        let minMatch = configuration.minMatch
        let segmentCheck = configuration.segmentCheck
        let outcome = await Task.detached(priority: .utility) {
            Self.analyze(raw: raw, starts: starts, fileName: fileName, reference: ref.starts,
                         minMatch: minMatch, segmentCheck: segmentCheck)
        }.value
        if let key {
            switch outcome {
            case .synced, .alreadyInSync, .unsure, .differentCut:
                results[key] = (Date(), outcome)
                while results.count > configuration.maxCachedResults,
                      let oldest = results.min(by: { $0.value.stamp < $1.value.stamp })?.key {
                    results[oldest] = nil
                }
            default:
                break
            }
        }
        return outcome
    }

    /// 纯计算部分（无状态，可在任何线程调用）。
    public static func analyze(raw: [UInt8], starts: [Int], fileName: String, reference: [Int],
                               minMatch: Double = 0.45, segmentCheck: Bool = true) -> AutoSyncOutcome {
        let res = SubtitleAligner.align(reference: reference, subtitle: starts)
        switch SubtitleAligner.decide(res, minMatch: minMatch) {
        case .inSync:
            return .alreadyInSync(res)
        case .unsure:
            return .unsure(res)
        case .sync:
            if segmentCheck {
                let check = SubtitleAligner.segmentCheck(reference: reference, subtitle: starts, result: res)
                if !check.ok { return .differentCut(res, check) }
            }
            let out = SubtitleTiming.applyTransform(raw, scale: res.scale, offsetMs: res.offsetMs, name: fileName)
            return .synced(SyncedSubtitle(data: Data(out), alignment: res, fromCache: false))
        }
    }

    static func loadReference(media: MediaSource, options: MatroskaCues.Options) async -> ReferenceLookup {
        let budget = options.makeBudget()
        let src: ByteRangeSource
        if media.url.isFileURL {
            do {
                src = try FileRangeSource(path: media.url.path, budget: budget)
            } catch let e as CuesError {
                return .failed(reason: e.reason, detail: e.detail)
            } catch {
                return .failed(reason: "io_error", detail: "\(error)")
            }
        } else {
            src = HTTPRangeSource(url: media.url, headers: media.headers, budget: budget)
        }
        let r = await MatroskaCues.load(src, options: options)
        guard r.ok else { return .failed(reason: r.reason ?? "error", detail: r.detail) }
        guard let t = MatroskaCues.pickReference(r.tracks) else {
            let detail = r.tracks.map { "\($0.lang.isEmpty ? "?" : $0.lang):\($0.cues.count)" }.joined(separator: " ")
            return .failed(reason: "no_usable_text_track", detail: detail)
        }
        let desc = "#\(t.number) \(t.lang.isEmpty ? "?" : t.lang) \(t.codec) \(t.cues.count) cues"
        return .ready(ReferenceTimeline(starts: t.starts, source: "mkv-cues", trackDescription: desc))
    }

    /// 64 位 FNV-1a，只用作缓存键。
    static func fnv1a(_ bytes: [UInt8]) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16) + ":" + String(bytes.count)
    }
}

public extension AlignmentResult {
    /// 简体中文说明：有帧率差时说帧率，否则说提前或延后多少秒。
    var summaryZh: String {
        let pct = Int((matched * 100).rounded())
        return "\(changeZh)（匹配 \(pct)%）"
    }

    var changeZh: String {
        if abs(scale - 1.0) > 0.0005 {
            let names: [(Double, String)] = [(25.0 / 23.976, "23.976 与 25"), (25.0 / 24.0, "24 与 25"),
                                             (24.0 / 23.976, "23.976 与 24")]
            // 取最接近的那一对帧率（25/24 与 25/23.976 只差 0.1%，不能只看第一个落在容差里的）
            let best = names.map { (min(abs(scale - $0.0), abs(scale - 1.0 / $0.0)), $0.1) }.min { $0.0 < $1.0 }!
            if best.0 < 0.002 { return "已校正 \(best.1) 帧率差" }
            return String(format: "已校正速度差（%.2f%%）", (scale - 1.0) * 100)
        }
        let seconds = String(format: "%.1f", Double(abs(offsetMs)) / 1000.0)
        return offsetMs < 0 ? "已提前 \(seconds) 秒" : "已延后 \(seconds) 秒"
    }
}
