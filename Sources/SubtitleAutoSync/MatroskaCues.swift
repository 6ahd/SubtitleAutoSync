import Foundation

/// MKV 内嵌字幕的时间轴：只读 Cues 索引，不读任何视频数据。
///
/// mkvmerge 和 FFmpeg 封装 MKV 时，会给文字字幕的每一行写一个 CuePoint（含 CueDuration）。
/// 所以只要读：文件头 → SeekHead → Info（TimestampScale）→ Tracks → Cues，
/// 就能拿到整部片每一行内嵌字幕的开始和结束时间。通常 2～3 个 Range 请求、不到 2 MB，
/// 文件本身有几十 GB 也一样。
///
/// 与 DexWorld 插件 dexcues.py 行为一致（有对比测试）。
public enum MatroskaCues {

    // EBML / Matroska 元素 ID
    static let idEBML = 0x1A45DFA3, idDocType = 0x4282, idSegment = 0x18538067
    static let idSeekHead = 0x114D9B74, idSeek = 0x4DBB, idSeekID = 0x53AB, idSeekPos = 0x53AC
    static let idInfo = 0x1549A966, idTimestampScale = 0x2AD7B1
    static let idTracks = 0x1654AE6B, idTrackEntry = 0xAE, idTrackNumber = 0xD7, idTrackType = 0x83
    static let idCodecID = 0x86, idName = 0x536E, idLanguage = 0x22B59C, idLanguageBCP47 = 0x22B59D
    static let idFlagDefault = 0x88, idFlagForced = 0x55AA, idFlagHI = 0x55AB, idFlagCommentary = 0x55AF
    static let idCues = 0x1C53BB6B, idCuePoint = 0xBB, idCueTime = 0xB3, idCueTrackPositions = 0xB7
    static let idCueTrack = 0xF7, idCueDuration = 0xB2, idCluster = 0x1F43B675
    static let trackTypeSubtitle = 17
    static let mb = 1 << 20

    public struct Options: Sendable {
        public var maxBytes = 24 << 20
        public var maxRequests = 16
        public var timeout: TimeInterval = 25
        public var headBytes = 512 << 10
        public var elementChunk = 1 << 20
        public var maxCuesBytes = 16 << 20
        public var maxTracksBytes = 4 << 20
        public var maxSeekHeadBytes = 2 << 20
        public var maxInfoBytes = 512 << 10
        public var tailBytes = 4 << 20
        public var maxSeekHops = 4
        /// 没有 CueDuration 时，用到下一行的间隔估计结束时间，最多 4 秒。
        public var estimatedMaxGapMs = 4000
        public var estimatedLastMs = 2000
        public var maxCueMs = 30000
        public init() {}
        public func makeBudget() -> ReadBudget {
            ReadBudget(maxBytes: maxBytes, maxRequests: maxRequests, timeout: timeout)
        }
    }

    public struct Cue: Equatable, Sendable {
        public var start: Int
        public var end: Int
    }

    public struct Track: Sendable {
        public var number: Int
        public var codec: String
        public var name: String
        public var language: String
        public var bcp47: String
        public var isDefault: Bool
        public var forced: Bool
        public var hearingImpaired: Bool
        public var commentary: Bool
        /// 规范化后的语言（ISO 639-2/T，例如 eng、ara、zho），未知为空。
        public var lang: String
        /// text：SRT/ASS/WebVTT；image：PGS/VobSub/DVB（只用时间，不读图片）。
        public var isImage: Bool
        public var cues: [Cue]
        /// 没有 CueDuration、结束时间是估计的行数。
        public var estimated: Int
        public var starts: [Int] { cues.map(\.start) }
    }

    public struct LoadResult: Sendable {
        public var ok: Bool
        public var reason: String?
        public var detail: String?
        /// "seekhead" 或 "tail"（SeekHead 里没有 Cues 时从文件末尾找到的）
        public var via: String?
        public var size: Int64?
        public var tracks: [Track]
        public var stats: ReadStats
    }

    // MARK: - 入口

    /// 读取所有文字字幕和图片字幕轨的时间轴。永远不抛错：失败放在 reason 里。
    public static func load(_ src: ByteRangeSource, options o: Options = Options()) async -> LoadResult {
        defer { src.close() }
        do {
            let meta = try await readMeta(src, o)
            let subs = meta.tracks.filter { $0.type == trackTypeSubtitle }
            let usable = subs.filter { isTextCodec($0.codec) || isImageCodec($0.codec) }
            if subs.isEmpty { throw CuesError("no_subtitle_tracks") }
            if usable.isEmpty {
                throw CuesError("no_usable_subtitles", Set(subs.map(\.codec)).sorted().joined(separator: ","))
            }
            let (cmap, via) = try await readCues(src, meta, o, want: Set(usable.map(\.number)))
            var out: [Track] = []
            for t in usable {
                let (cues, est) = buildTimeline(cmap[t.number] ?? [], scaleNs: meta.scale, o)
                out.append(Track(number: t.number, codec: t.codec, name: t.name, language: t.language,
                                 bcp47: t.bcp47, isDefault: t.isDefault, forced: t.forced,
                                 hearingImpaired: t.hi, commentary: t.commentary,
                                 lang: trackLang(language: t.language, bcp47: t.bcp47),
                                 isImage: !isTextCodec(t.codec), cues: cues, estimated: est))
            }
            return LoadResult(ok: true, reason: nil, detail: nil, via: via, size: src.size, tracks: out,
                              stats: src.budget.stats)
        } catch let e as CuesError {
            return LoadResult(ok: false, reason: e.reason, detail: e.detail, via: nil, size: src.size, tracks: [],
                              stats: src.budget.stats)
        } catch is CancellationError {
            return LoadResult(ok: false, reason: "cancelled", detail: nil, via: nil, size: src.size, tracks: [],
                              stats: src.budget.stats)
        } catch {
            return LoadResult(ok: false, reason: "error", detail: "\(error)", via: nil, size: src.size, tracks: [],
                              stats: src.budget.stats)
        }
    }

    /// 选参照轨：先文字后图片；英语优先；排除 forced（只有招牌/外语对白）和评论音轨字幕；
    /// SRT 优先于 ASS；SDH 稍降权；行数多的优先。图片字幕需要两倍行数（PGS 每行有“显示”和“清除”两个事件）。
    public static func pickReference(_ tracks: [Track], minCues: Int = 30, minSpanMs: Int = 120_000) -> Track? {
        func usable(_ t: Track) -> Bool {
            let need = minCues * (t.isImage ? 2 : 1)
            guard t.cues.count >= need, let first = t.cues.first, let last = t.cues.last else { return false }
            return last.start - first.start >= minSpanMs
        }
        func score(_ t: Track) -> Double {
            var s = t.lang == "eng" ? 0.0 : 5.0
            s += t.forced ? 50 : 0
            s += t.commentary ? 50 : 0
            let c = t.codec.uppercased()
            s += (c.contains("ASS") || c.contains("SSA")) ? 2 : 0
            s += t.hearingImpaired ? 1 : 0
            return s - Double(min(t.cues.count, 3000)) / 1000.0
        }
        for image in [false, true] {
            let pool = tracks.enumerated().filter { $0.element.isImage == image && usable($0.element) }
            if !pool.isEmpty {
                // 稳定排序：分数相同保持原顺序
                return pool.min { a, b in
                    let sa = score(a.element), sb = score(b.element)
                    return sa != sb ? sa < sb : a.offset < b.offset
                }?.element
            }
        }
        return nil
    }

    public static func isTextCodec(_ codec: String) -> Bool {
        let c = codec.uppercased()
        return c.hasPrefix("S_TEXT/") || c == "S_ASS" || c == "S_SSA" || c.hasPrefix("D_WEBVTT")
    }

    public static func isImageCodec(_ codec: String) -> Bool {
        let c = codec.uppercased()
        return c.hasPrefix("S_HDMV/PGS") || c.hasPrefix("S_VOBSUB") || c.hasPrefix("S_DVBSUB")
    }

    // MARK: - EBML

    struct Header {
        let id: Int
        let dataStart: Int
        /// nil 表示大小未知
        let dataEnd: Int?
        let pos: Int
    }

    static func vintLength(_ first: UInt8) -> Int {
        if first == 0 { return 0 }
        var n = 1
        var mask: UInt8 = 0x80
        while first & mask == 0 {
            mask >>= 1
            n += 1
        }
        return n
    }

    static func readHeader(_ buf: [UInt8], _ pos: Int, _ end: Int) -> Header? {
        if pos >= end { return nil }
        let il = vintLength(buf[pos])
        if il == 0 || il > 4 || pos + il > end { return nil }
        var eid = 0
        for i in 0..<il { eid = (eid << 8) | Int(buf[pos + i]) }
        let p = pos + il
        if p >= end { return nil }
        let sl = vintLength(buf[p])
        if sl == 0 || sl > 8 || p + sl > end { return nil }
        let firstMask = sl >= 8 ? 0 : (0xFF >> sl)
        var size = Int(buf[p]) & firstMask
        var unknown = size == firstMask
        for i in 1..<max(1, sl) where i < sl {
            let b = Int(buf[p + i])
            size = (size << 8) | b
            if b != 0xFF { unknown = false }
        }
        let ds = p + sl
        return Header(id: eid, dataStart: ds, dataEnd: unknown ? nil : ds + size, pos: pos)
    }

    static func children(_ buf: [UInt8], _ start: Int, _ end: Int) -> [Header] {
        var out: [Header] = []
        var p = start
        while p < end {
            guard let h = readHeader(buf, p, end), let he = h.dataEnd, he <= end else { break }
            out.append(h)
            p = he
        }
        return out
    }

    static func uint(_ buf: [UInt8], _ s: Int, _ e: Int) -> Int {
        var v = 0
        for i in s..<e { v = (v << 8) | Int(buf[i]) }
        return v
    }

    static func str(_ buf: [UInt8], _ s: Int, _ e: Int) -> String {
        var t = String(decoding: buf[s..<e], as: UTF8.self)
        while t.hasSuffix("\u{0}") { t.removeLast() }
        return t
    }

    // MARK: - 解析各元素

    struct RawTrack {
        var number: Int
        var type: Int?
        var codec = ""
        var name = ""
        var language = "eng"   // Matroska 默认语言
        var bcp47 = ""
        var isDefault = true
        var forced = false
        var hi = false
        var commentary = false
    }

    struct Meta {
        let head: [UInt8]
        let pos: [Int: Int]
        let scale: Int
        let tracks: [RawTrack]
    }

    static func parseSeekHead(_ buf: [UInt8], _ h: Header) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for e in children(buf, h.dataStart, h.dataEnd!) where e.id == idSeek {
            var sid: Int?
            var spos: Int?
            for c in children(buf, e.dataStart, e.dataEnd!) {
                if c.id == idSeekID { sid = uint(buf, c.dataStart, c.dataEnd!) }
                else if c.id == idSeekPos { spos = uint(buf, c.dataStart, c.dataEnd!) }
            }
            if let sid, let spos { out.append((sid, spos)) }
        }
        return out
    }

    static func parseInfo(_ buf: [UInt8], _ h: Header) -> Int {
        var scale = 1_000_000
        for c in children(buf, h.dataStart, h.dataEnd!) where c.id == idTimestampScale {
            let v = uint(buf, c.dataStart, c.dataEnd!)
            scale = v == 0 ? 1_000_000 : v
        }
        return scale
    }

    static func parseTracks(_ buf: [UInt8], _ h: Header) -> [RawTrack] {
        var tracks: [RawTrack] = []
        for e in children(buf, h.dataStart, h.dataEnd!) where e.id == idTrackEntry {
            var t = RawTrack(number: -1)
            var hasNumber = false
            for c in children(buf, e.dataStart, e.dataEnd!) {
                let s = c.dataStart, en = c.dataEnd!
                switch c.id {
                case idTrackNumber: t.number = uint(buf, s, en); hasNumber = true
                case idTrackType: t.type = uint(buf, s, en)
                case idCodecID: t.codec = str(buf, s, en)
                case idName: t.name = str(buf, s, en)
                case idLanguage:
                    let l = str(buf, s, en)
                    t.language = l.isEmpty ? "eng" : l
                case idLanguageBCP47: t.bcp47 = str(buf, s, en)
                case idFlagDefault: t.isDefault = uint(buf, s, en) != 0
                case idFlagForced: t.forced = uint(buf, s, en) == 1
                case idFlagHI: t.hi = uint(buf, s, en) == 1
                case idFlagCommentary: t.commentary = uint(buf, s, en) == 1
                default: break
                }
            }
            if hasNumber { tracks.append(t) }
        }
        return tracks
    }

    /// 每个字幕轨的 (CueTime, CueDuration?) 列表（单位：TimestampScale 的 tick）。
    static func parseCues(_ buf: [UInt8], _ h: Header, want: Set<Int>) -> [Int: [(Int, Int?)]] {
        var out: [Int: [(Int, Int?)]] = [:]
        for n in want { out[n] = [] }
        for cp in children(buf, h.dataStart, h.dataEnd!) where cp.id == idCuePoint {
            var t: Int?
            var pos: [(Int, Int?)] = []
            for c in children(buf, cp.dataStart, cp.dataEnd!) {
                if c.id == idCueTime {
                    t = uint(buf, c.dataStart, c.dataEnd!)
                } else if c.id == idCueTrackPositions {
                    var tn: Int?
                    var d: Int?
                    for x in children(buf, c.dataStart, c.dataEnd!) {
                        if x.id == idCueTrack { tn = uint(buf, x.dataStart, x.dataEnd!) }
                        else if x.id == idCueDuration { d = uint(buf, x.dataStart, x.dataEnd!) }
                    }
                    if let tn, want.contains(tn) { pos.append((tn, d)) }
                }
            }
            guard let t else { continue }
            for (tn, d) in pos { out[tn, default: []].append((t, d)) }
        }
        return out
    }

    static func normLang(_ x: String) -> String {
        let s = x.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if ["", "und", "unknown", "mis", "zxx"].contains(s) { return "" }
        let two = ["en": "eng", "ar": "ara", "fr": "fra", "de": "deu", "es": "spa", "it": "ita", "pt": "por",
                   "tr": "tur", "ru": "rus", "ja": "jpn", "ko": "kor", "zh": "zho", "nl": "nld"]
        let b2t = ["fre": "fra", "ger": "deu", "dut": "nld", "chi": "zho", "per": "fas", "gre": "ell",
                   "cze": "ces", "rum": "ron"]
        if s.count == 2 { return two[s] ?? s }
        return b2t[s] ?? s
    }

    static func trackLang(language: String, bcp47: String) -> String {
        let a = normLang(bcp47)
        return a.isEmpty ? normLang(language) : a
    }

    // MARK: - 读取结构

    static func getElement(_ src: ByteRangeSource, _ head: [UInt8], at: Int, expect: Int, cap: Int,
                           _ o: Options) async throws -> ([UInt8], Header)? {
        if at + 12 <= head.count, let h = readHeader(head, at, head.count), h.id == expect,
           let he = h.dataEnd, he <= head.count {
            return (head, h)
        }
        if let size = src.size, Int64(at) >= size { return nil }
        let first = try await src.read(Int64(at), min(o.elementChunk, cap + 16), partialOK: true)
        guard let h = readHeader(first, 0, first.count), h.id == expect else { return nil }
        guard let he = h.dataEnd else { throw CuesError("unknown_size", String(expect, radix: 16)) }
        if he > cap + 16 {
            throw CuesError(expect == idCues ? "cues_too_large" : "element_too_large",
                            String(format: "%.1fMB", Double(he) / Double(mb)))
        }
        if he <= first.count { return (first, h) }
        let rest = try await src.read(Int64(at + first.count), he - first.count, partialOK: false)
        let buf = first + rest
        if he > buf.count { throw CuesError("truncated", String(expect, radix: 16)) }
        return (buf, h)
    }

    static func readMeta(_ src: ByteRangeSource, _ o: Options) async throws -> Meta {
        let head = try await src.read(0, o.headBytes, partialOK: true)
        if head.count < 32 { throw CuesError("short_file") }
        guard let ebml = readHeader(head, 0, head.count), ebml.id == idEBML, let ebmlEnd = ebml.dataEnd,
              ebmlEnd <= head.count else { throw CuesError("not_mkv") }
        var doctype = "matroska"
        for c in children(head, ebml.dataStart, ebmlEnd) where c.id == idDocType {
            doctype = str(head, c.dataStart, c.dataEnd!)
        }
        if !["matroska", "webm"].contains(doctype.lowercased()) { throw CuesError("not_mkv", doctype) }

        var p = ebmlEnd
        var seg: Header?
        while p < head.count {
            guard let h = readHeader(head, p, head.count) else { break }
            if h.id == idSegment { seg = h; break }
            guard let he = h.dataEnd else { break }
            p = he
        }
        guard let seg else { throw CuesError("no_segment") }
        let segStart = seg.dataStart

        // 文件头里能直接看到的一级元素
        var pos: [Int: Int] = [:]
        p = segStart
        while p < head.count {
            guard let h = readHeader(head, p, head.count) else { break }
            if [idSeekHead, idInfo, idTracks, idCues].contains(h.id) && pos[h.id] == nil { pos[h.id] = h.pos }
            if h.id == idCluster { break }
            guard let he = h.dataEnd else { break }
            p = he
        }

        // 跟着 SeekHead 找其余位置（最多 4 跳）
        var queue: [Int] = pos[idSeekHead].map { [$0] } ?? []
        var seen = Set<Int>()
        var hops = 0
        while !queue.isEmpty && hops < o.maxSeekHops {
            let at = queue.removeFirst()
            if seen.contains(at) { continue }
            seen.insert(at)
            hops += 1
            var el: ([UInt8], Header)?
            do {
                el = try await getElement(src, head, at: at, expect: idSeekHead, cap: o.maxSeekHeadBytes, o)
            } catch let e as CuesError {
                if e.isFatal { throw e }
                el = nil
            }
            guard let el else { continue }
            for (sid, rel) in parseSeekHead(el.0, el.1) {
                let ab = segStart + rel
                if sid == idSeekHead {
                    if !seen.contains(ab) { queue.append(ab) }
                    continue
                }
                if pos[sid] == nil { pos[sid] = ab }
            }
        }

        var scale = 1_000_000
        if let at = pos[idInfo],
           let el = try await getElement(src, head, at: at, expect: idInfo, cap: o.maxInfoBytes, o) {
            scale = parseInfo(el.0, el.1)
        }
        guard let tracksAt = pos[idTracks] else { throw CuesError("no_tracks") }
        guard let el = try await getElement(src, head, at: tracksAt, expect: idTracks, cap: o.maxTracksBytes, o)
        else { throw CuesError("no_tracks") }
        return Meta(head: head, pos: pos, scale: scale, tracks: parseTracks(el.0, el.1))
    }

    static func readCues(_ src: ByteRangeSource, _ meta: Meta, _ o: Options,
                         want: Set<Int>) async throws -> ([Int: [(Int, Int?)]], String) {
        if let at = meta.pos[idCues] {
            var el: ([UInt8], Header)?
            do {
                el = try await getElement(src, meta.head, at: at, expect: idCues, cap: o.maxCuesBytes, o)
            } catch let e as CuesError {
                if e.isFatal || e.reason == "cues_too_large" { throw e }
                el = nil
            }
            if let el { return (parseCues(el.0, el.1, want: want), "seekhead") }
        }
        // 备用：SeekHead 没写 Cues 的位置，就在文件最后 4 MB 里找
        guard let size = src.size, size > Int64(meta.head.count) else { throw CuesError("no_cues") }
        let start = max(0, size - Int64(o.tailBytes))
        let tail = try await src.read(start, Int(size - start), partialOK: true)
        let magic: [UInt8] = [0x1C, 0x53, 0xBB, 0x6B]
        var end = tail.count
        while let i = lastIndex(of: magic, in: tail, before: end) {
            if let h = readHeader(tail, i, tail.count), let he = h.dataEnd, he <= tail.count,
               let c = readHeader(tail, h.dataStart, he), c.id == idCuePoint {
                let m = parseCues(tail, h, want: want)
                if m.values.reduce(0, { $0 + $1.count }) > 0 { return (m, "tail") }
            }
            end = i   // 下一次只找完全落在 i 之前的位置（与 Python rfind(magic, 0, i) 一致）
        }
        throw CuesError("no_cues")
    }

    /// 在 buf[0..<end] 中找最后一次出现 pattern 的位置（pattern 必须完整落在 end 之前）。
    static func lastIndex(of pattern: [UInt8], in buf: [UInt8], before end: Int) -> Int? {
        var i = min(end, buf.count) - pattern.count
        while i >= 0 {
            if buf[i] == pattern[0] && buf[i + 1] == pattern[1] && buf[i + 2] == pattern[2] && buf[i + 3] == pattern[3] {
                return i
            }
            i -= 1
        }
        return nil
    }

    static func buildTimeline(_ entries: [(Int, Int?)], scaleNs: Int, _ o: Options) -> ([Cue], Int) {
        func toMs(_ ticks: Int) -> Int {
            Int((Double(ticks * scaleNs) / 1e6).rounded(.toNearestOrEven))
        }
        // 按时间稳定排序；同一时间保留时长最长的那条
        let sorted = entries.enumerated().sorted { $0.element.0 != $1.element.0 ? $0.element.0 < $1.element.0 : $0.offset < $1.offset }
        var uniq: [(Int, Int?)] = []
        for (_, e) in sorted {
            if let last = uniq.last, last.0 == e.0 {
                if (e.1 ?? 0) > (last.1 ?? 0) { uniq[uniq.count - 1] = e }
                continue
            }
            uniq.append(e)
        }
        var cues: [Cue] = []
        var estimated = 0
        for (i, (t, d)) in uniq.enumerated() {
            let start = toMs(t)
            var dur = (d ?? 0) != 0 ? toMs(d!) : 0
            if dur <= 0 {
                estimated += 1
                if i + 1 < uniq.count {
                    dur = max(1, min(o.estimatedMaxGapMs, toMs(uniq[i + 1].0) - start))
                } else {
                    dur = o.estimatedLastMs
                }
            }
            cues.append(Cue(start: start, end: start + min(dur, o.maxCueMs)))
        }
        return (cues, estimated)
    }
}
