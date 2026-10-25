// FFmpegSubtitleIndex.swift
//
// 给基于 FFmpeg 的播放器（EplayerX 播放引擎）用：直接从播放器自己的 AVFormatContext
// 读出内嵌字幕每一行的开始时间，作为 AutoSync 的参照。不用另开连接，也不用自己解析 EBML。
//
// 这个文件不在 Swift Package 的 target 里（它依赖 FFmpeg）：请拷进 App 工程，
// 并把下面的 import CFFmpeg 换成你项目里 FFmpeg 的模块名（例如 Libavformat、FFmpegKit 等）。
//
// 已用 FFmpeg 6.1 实测，当前 FFmpeg 主干源码（libavformat/matroskadec.c）里是同样的逻辑：
//   MKV：Cues 在第一次 seek 时才被解析（matroska_read_seek → matroska_parse_cues），
//        解析后每个字幕轨都会得到完整的索引条目（每行一条）。所以要先 seek 一次。
//        网络源上这次 seek 会让 FFmpeg 多发 2 到 3 个 Range 请求（跳到文件末尾读 Cues 再跳回来）。
//   MP4/MOV：打开文件后 mov 解复用器就为 tx3g/wvtt 字幕轨建好了全部样本索引，
//        其中包含“空样本”（tx3g 为 2 字节，表示两行字幕之间的空白），要按大小过滤掉。
//
// 注意：
//   1. AVFormatContext 不是线程安全的。这些函数必须在你的解复用线程上调用，不能和 av_read_frame 并发。
//   2. loadIndex 会把解复用位置移到 0 点：只能在开始播放之前调用（或者直接用你恢复进度时的那次 seek）。
//   3. 读一次、保存结果，不要在播放中途再读：解复用器会把读到的字幕块也加进索引，
//      没有字幕 Cues 的 MKV 在播放中途读到的只是已播放的一段。pickReference 会检查覆盖范围。
//   4. 自定义 AVIOContext 必须可 seek（seekable = AVIO_SEEKABLE_NORMAL），否则 FFmpeg 不会读 Cues。
//   5. 索引里只有开始时间（没有时长），这正是对齐算法需要的。
//   6. 你的 FFmpeg 版本和 6.1 不同时，请先用 subtitleStreams 打印条目数，确认 seek 前后的变化。
import CFFmpeg

public enum FFmpegSubtitleIndex {

    public struct StreamInfo {
        public let index: Int32
        public let codecName: String
        public let language: String
        public let forced: Bool
        public let hearingImpaired: Bool
        public let commentary: Bool
        public let isImage: Bool
        public let startsMs: [Int]
    }

    /// 在 avformat_find_stream_info 之后、开始播放之前调用一次（解复用线程）。
    /// 如果你本来就会 seek 到上次的播放进度，那次 seek 已经让 MKV 的 Cues 被解析，可以不调用。
    @discardableResult
    public static func loadIndex(_ fmt: UnsafeMutablePointer<AVFormatContext>) -> Bool {
        avformat_seek_file(fmt, -1, Int64.min, 0, Int64.max, 0) >= 0
    }

    /// 一个字幕流的全部开始时间（毫秒，以播放时间 0 点为准）。
    public static func cueStartsMs(_ fmt: UnsafeMutablePointer<AVFormatContext>, streamIndex: Int32,
                                   subtractStartTime: Bool = true) -> [Int] {
        guard streamIndex >= 0, UInt32(streamIndex) < fmt.pointee.nb_streams,
              let st = fmt.pointee.streams[Int(streamIndex)] else { return [] }
        let tb = st.pointee.time_base
        guard tb.den != 0 else { return [] }
        let isMov = String(cString: fmt.pointee.iformat.pointee.name).contains("mov")
        let codec = st.pointee.codecpar.pointee.codec_id
        // MP4 里表示“这段时间没有字幕”的空样本
        let emptyLimit: Int32 = !isMov ? -1 : (codec == AV_CODEC_ID_MOV_TEXT ? 2 : (codec == AV_CODEC_ID_WEBVTT ? 8 : -1))
        var startOffsetMs = 0.0
        if subtractStartTime, fmt.pointee.start_time != Int64.min {   // Int64.min 就是 AV_NOPTS_VALUE
            startOffsetMs = Double(fmt.pointee.start_time) / 1000.0   // AV_TIME_BASE 是微秒
        }
        let n = avformat_index_get_entries_count(st)
        var out: [Int] = []
        out.reserveCapacity(Int(n))
        for i in 0..<n {
            guard let e = avformat_index_get_entry(st, i) else { continue }
            if emptyLimit >= 0 && e.pointee.size <= emptyLimit { continue }
            let ms = Double(e.pointee.timestamp) * Double(tb.num) * 1000.0 / Double(tb.den) - startOffsetMs
            out.append(Int(ms.rounded()))
        }
        return out.sorted()
    }

    /// 所有字幕流及其开始时间。
    public static func subtitleStreams(_ fmt: UnsafeMutablePointer<AVFormatContext>) -> [StreamInfo] {
        var out: [StreamInfo] = []
        for i in 0..<Int32(fmt.pointee.nb_streams) {
            guard let st = fmt.pointee.streams[Int(i)],
                  st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            let codec = st.pointee.codecpar.pointee.codec_id
            let lang = av_dict_get(st.pointee.metadata, "language", nil, 0).map { String(cString: $0.pointee.value) } ?? ""
            let disp = st.pointee.disposition
            let image = codec == AV_CODEC_ID_HDMV_PGS_SUBTITLE || codec == AV_CODEC_ID_DVD_SUBTITLE
                || codec == AV_CODEC_ID_DVB_SUBTITLE
            out.append(StreamInfo(index: i, codecName: String(cString: avcodec_get_name(codec)),
                                  language: lang.lowercased(),
                                  forced: disp & AV_DISPOSITION_FORCED != 0,
                                  hearingImpaired: disp & AV_DISPOSITION_HEARING_IMPAIRED != 0,
                                  commentary: disp & AV_DISPOSITION_COMMENT != 0,
                                  isImage: image,
                                  startsMs: cueStartsMs(fmt, streamIndex: i)))
        }
        return out
    }

    /// 读参照：所有字幕流 + 选择 + 覆盖范围检查。返回 nil 表示没有可用的参照
    /// （此时调用 coordinator.setFFmpegReference(nil)，不要再走 HTTP Range）。
    public static func reference(_ fmt: UnsafeMutablePointer<AVFormatContext>, minCoverage: Double = 0.5) -> StreamInfo? {
        let durationMs = fmt.pointee.duration > 0 ? Int(fmt.pointee.duration / 1000) : nil   // AV_TIME_BASE 是微秒
        return pickReference(subtitleStreams(fmt), durationMs: durationMs, minCoverage: minCoverage)
    }

    /// 选参照流，规则与 MatroskaCues.pickReference 相同：
    /// 先文字后图片；英语优先；forced、评论降到最后；ASS 稍降权；听障稍降权；行数多的优先。
    /// 另外要求第一行到最后一行至少覆盖片长的 minCoverage（防止只拿到已播放的一段）。
    public static func pickReference(_ streams: [StreamInfo], durationMs: Int? = nil, minCoverage: Double = 0.5,
                                     minCues: Int = 30, minSpanMs: Int = 120_000) -> StreamInfo? {
        func usable(_ s: StreamInfo) -> Bool {
            let need = minCues * (s.isImage ? 2 : 1)
            guard s.startsMs.count >= need, let a = s.startsMs.first, let b = s.startsMs.last else { return false }
            if let d = durationMs, d > 0, Double(b - a) < Double(d) * minCoverage { return false }
            return b - a >= minSpanMs
        }
        func score(_ s: StreamInfo) -> Double {
            var v = ["eng", "en"].contains(s.language) ? 0.0 : 5.0
            v += s.forced ? 50 : 0
            v += s.commentary ? 50 : 0
            v += s.codecName == "ass" || s.codecName == "ssa" ? 2 : 0
            v += s.hearingImpaired ? 1 : 0
            return v - Double(min(s.startsMs.count, 3000)) / 1000.0
        }
        for image in [false, true] {
            let pool = streams.enumerated().filter { $0.element.isImage == image && usable($0.element) }
            if let best = pool.min(by: { a, b in
                let sa = score(a.element), sb = score(b.element)
                return sa != sb ? sa < sb : a.offset < b.offset
            }) {
                return best.element
            }
        }
        return nil
    }
}
