import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SubtitleAutoSync

/// HTTP Range 读取 + 引擎端到端测试。
/// 需要先运行 Tests/Support/range_server.py（见 README），并设置环境变量 RANGE_SERVER_URL。
final class HTTPAndEngineTests: XCTestCase {

    var server: URL!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["RANGE_SERVER_URL"], let u = URL(string: s) else {
            throw XCTSkip("RANGE_SERVER_URL not set")
        }
        server = u
    }

    func url(_ path: String) -> URL { server.appendingPathComponent(path) }

    func load(_ path: String, headers: [String: String] = [:], timeout: TimeInterval = 25) async -> MatroskaCues.LoadResult {
        var o = MatroskaCues.Options()
        o.timeout = timeout
        let src = HTTPRangeSource(url: url(path), headers: headers, budget: o.makeBudget())
        return await MatroskaCues.load(src, options: o)
    }

    // MARK: HTTP

    func testRangeReadMatchesLocalFile() async throws {
        let http = await load("media/multi.mkv")
        let file = await MatroskaCues.load(try FileRangeSource(
            path: ParityTests.fixture("media/multi.mkv").path, budget: MatroskaCues.Options().makeBudget()))
        XCTAssertTrue(http.ok, "\(http.reason ?? "")")
        XCTAssertEqual(http.via, "seekhead")
        XCTAssertEqual(http.tracks.map(\.cues), file.tracks.map(\.cues))
        XCTAssertEqual(http.stats.requests, 2)
        XCTAssertEqual(http.size, file.size)
        let log = try JSONSerialization.jsonObject(with: Data(contentsOf: url("log"))) as! [[String: Any]]
        let last = log.suffix(2)
        XCTAssertTrue(last.allSatisfy { ($0["range"] as? String)?.hasPrefix("bytes=") == true })
        XCTAssertTrue(last.allSatisfy { ($0["ae"] as? String) == "identity" })
    }

    func testTailScanOverHTTP() async {
        let r = await load("media/tailcues.mkv")
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.via, "tail")
        XCTAssertEqual(r.tracks.first?.cues.count, 349)
    }

    func testRedirectIsFollowed() async {
        let src = HTTPRangeSource(url: url("redirect/mkvmerge.mkv"), budget: MatroskaCues.Options().makeBudget())
        let r = await MatroskaCues.load(src)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.tracks.first?.cues.count, 349)
        XCTAssertTrue(src.url.path.hasPrefix("/media/"), src.url.absoluteString)
    }

    func testPlaybackHeadersAreSent() async {
        let ok = await load("auth/mkvmerge.mkv", headers: ["X-Emby-Token": "secret"])
        XCTAssertTrue(ok.ok)
        let denied = await load("auth/mkvmerge.mkv")
        XCTAssertFalse(denied.ok)
        XCTAssertEqual(denied.reason, "http_401")
    }

    func testServerWithoutRangeNeverDownloadsWholeFile() async {
        let r = await load("norange/mkvmerge.mkv")
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.reason, "no_range")
        XCTAssertLessThanOrEqual(r.stats.bytes, 512 << 10)
    }

    func testTimeoutBudget() async {
        let t0 = Date()
        let r = await load("slow/mkvmerge.mkv", timeout: 1)
        XCTAssertFalse(r.ok)
        print("timeout test:", r.reason ?? "-", r.detail ?? "-", r.stats, Date().timeIntervalSince(t0))
        XCTAssertTrue(["timeout", "http_io"].contains(r.reason ?? ""), r.reason ?? "")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.8)
    }

    func testCancellationStopsQuickly() async {
        let t0 = Date()
        let task = Task { await self.load("slow/mkvmerge.mkv") }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let r = await task.value
        XCTAssertEqual(r.reason, "cancelled")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.5)
    }

    // MARK: 引擎

    /// 参照字幕的开始和结束（来自 ref_en.srt，与 MKV 里内嵌的英文字幕相同）。
    func referenceCues() throws -> [(Int, Int)] {
        let raw = try String(contentsOf: ParityTests.fixture("media/ref_en.srt"), encoding: .utf8)
        return raw.components(separatedBy: "\n").filter { $0.contains("-->") }.map { line in
            let p = line.components(separatedBy: " --> ").map { SubtitleTiming.timestampMs($0.trimmingCharacters(in: .whitespaces)) }
            return (p[0], p[1])
        }
    }

    func srt(_ cues: [(Int, Int)], text: (Int) -> String) -> String {
        cues.enumerated().map { i, c in
            "\(i + 1)\r\n\(SubtitleTiming.format(c.0, like: "00:00:00,000", kind: .pair)) --> \(SubtitleTiming.format(c.1, like: "00:00:00,000", kind: .pair))\r\n\(text(i))\r\n"
        }.joined(separator: "\r\n")
    }

    /// 25 fps（PAL）版本的阿拉伯语字幕，Windows-1256 编码，外加 2.5 秒偏移、少了一些行。
    func palArabicSubtitle() throws -> (Data, [(Int, Int)]) {
        var rng = SystemRandomNumberGenerator()
        let cues = try referenceCues().enumerated().filter { $0.offset % 9 != 4 }.map { $0.element }
        let pal = cues.map { c -> (Int, Int) in
            let j = Int.random(in: -60...60, using: &rng)
            return (Int((Double(c.0) * 23.976 / 25.0).rounded()) + 2500 + j, Int((Double(c.1) * 23.976 / 25.0).rounded()) + 2500 + j)
        }
        let text = srt(pal) { "سطر عربي رقم \($0)… مع نص" }
        // Windows-1256：阿拉伯字母在 0xC1...0xFE，省略号 0x85
        var bytes: [UInt8] = []
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0621...0x063A: bytes.append(UInt8(0xC1 + Int(scalar.value) - 0x0621))
            case 0x0641...0x064A: bytes.append(UInt8(0xDD + Int(scalar.value) - 0x0641))   // 近似映射即可，测试只要求字节不变
            case 0x2026: bytes.append(0x85)
            default: bytes.append(UInt8(truncatingIfNeeded: scalar.value))
            }
        }
        return (Data(bytes), cues)
    }

    /// 去掉所有时间戳后的字节（用来确认除了时间以外什么都没变）。
    func strippedOfTimes(_ d: Data) -> [UInt8] {
        let s = String(String.UnicodeScalarView([UInt8](d).map { Unicode.Scalar($0) }))
        let re = try! NSRegularExpression(pattern: #"\d{2}:\d{2}:\d{2},\d{3}"#)
        let out = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "T")
        return out.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
    }

    func testEngineSyncsPalSubtitleOverHTTP() async throws {
        let engine = SubtitleAutoSyncEngine()
        let media = MediaSource(url: url("media/mkvmerge.mkv"))
        let (data, truth) = try palArabicSubtitle()
        let outcome = await engine.synchronize(subtitle: data, fileName: "movie.ar.srt", media: media)
        guard case .synced(let s) = outcome else { return XCTFail("expected synced, got \(outcome)") }
        XCTAssertEqual(s.alignment.scale, 25.0 / 23.976, accuracy: 2e-4)
        XCTAssertFalse(s.fromCache)
        XCTAssertGreaterThan(s.alignment.matched, 0.85)
        print("PAL case:", s.alignment.summaryZh, s.alignment)
        // 时间对上参照（±150 ms），其他字节完全不变
        let newStarts = SubtitleTiming.parseStarts([UInt8](s.data), name: "movie.ar.srt")
        XCTAssertEqual(newStarts.count, truth.count)
        let good = zip(newStarts, truth.map(\.0)).filter { abs($0 - $1) <= 150 }.count
        XCTAssertGreaterThan(Double(good) / Double(truth.count), 0.97)
        XCTAssertEqual(strippedOfTimes(s.data), strippedOfTimes(data))
        // 第二次：缓存命中
        let again = await engine.synchronize(subtitle: data, fileName: "movie.ar.srt", media: media)
        guard case .synced(let s2) = again else { return XCTFail("expected cached synced") }
        XCTAssertTrue(s2.fromCache)
        XCTAssertEqual(s2.data, s.data)
    }

    func testEngineOutcomes() async throws {
        let engine = SubtitleAutoSyncEngine()
        let media = MediaSource(url: url("media/multi.mkv"))
        let cues = try referenceCues()

        // 本来就同步
        let same = Data(srt(cues.map { ($0.0 + 80, $0.1 + 80) }) { "line \($0)" }.utf8)
        let r1 = await engine.synchronize(subtitle: same, fileName: "a.srt", media: media)
        guard case .alreadyInSync = r1 else { return XCTFail("expected alreadyInSync, got \(r1)") }

        // 别的片子的字幕
        var rng = SystemRandomNumberGenerator()
        var t = 5000
        var other: [(Int, Int)] = []
        for _ in 0..<400 { let d = Int.random(in: 800...4000, using: &rng); other.append((t, t + d)); t += d + Int.random(in: 300...9000, using: &rng) }
        let r2 = await engine.synchronize(subtitle: Data(srt(other) { "x\($0)" }.utf8), fileName: "b.srt", media: media)
        guard case .unsure(let res) = r2 else { return XCTFail("expected unsure, got \(r2)") }
        print("unrelated:", res)

        // 行数太少
        let r3 = await engine.synchronize(subtitle: Data(srt(Array(cues.prefix(10))) { "y\($0)" }.utf8), fileName: "c.srt", media: media)
        guard case .tooFewLines(10) = r3 else { return XCTFail("expected tooFewLines, got \(r3)") }

        // HLS 不支持
        let r4 = await engine.synchronize(subtitle: same, fileName: "a.srt", media: MediaSource(url: url("live/master.m3u8")))
        guard case .notSupported = r4 else { return XCTFail("expected notSupported") }

        // MP4 / 没有字幕 Cue 的 MKV
        let r5 = await engine.synchronize(subtitle: same, fileName: "a.srt", media: MediaSource(url: url("media/movtext.mp4")))
        guard case .noReference("not_mkv") = r5 else { return XCTFail("expected not_mkv, got \(r5)") }
        let r6 = await engine.synchronize(subtitle: same, fileName: "a.srt", media: MediaSource(url: url("media/nocues.mkv")))
        guard case .noReference("no_usable_text_track") = r6 else { return XCTFail("expected no_usable_text_track, got \(r6)") }
    }

    func testEngineWithExternalReference() async throws {
        // 例如从播放器自己的 FFmpeg 索引拿到的开始时间
        let starts = try referenceCues().map(\.0)
        let engine = SubtitleAutoSyncEngine()
        let shifted = Data(srt(try referenceCues().map { ($0.0 - 4321, $0.1 - 4321) }) { "z\($0)" }.utf8)
        let r = await engine.synchronize(subtitle: shifted, fileName: "d.srt",
                                         reference: ReferenceTimeline(starts: starts, source: "ffmpeg-index"),
                                         cacheKey: "movie-1")
        guard case .synced(let s) = r else { return XCTFail("expected synced, got \(r)") }
        XCTAssertLessThanOrEqual(abs(s.alignment.offsetMs - 4321), 2)
        XCTAssertEqual(s.alignment.scale, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.alignment.changeZh, "已延后 4.3 秒")
    }
}
