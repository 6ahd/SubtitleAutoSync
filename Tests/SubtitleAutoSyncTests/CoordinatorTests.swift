import XCTest
@testable import SubtitleAutoSync

/// 协调器与引擎的离线测试（不需要 HTTP 服务器）。
@MainActor
final class CoordinatorTests: XCTestCase {

    final class MockPlayer: AutoSyncPlayer {
        var current: [Int: String] = [:]
        var replaced: [(slot: Int, id: String, data: Data)] = []
        var toasts: [String] = []
        var resets = 0
        func currentExternalSubtitleID(slot: Int) -> String? { current[slot] }
        func replaceExternalSubtitle(slot: Int, id: String, data: Data, fileName: String) { replaced.append((slot, id, data)) }
        func resetManualSubtitleDelay(slot: Int) { resets += 1 }
        func showToast(_ text: String) { toasts.append(text) }
    }

    static let starts: [Int] = {
        let raw = try! String(contentsOf: ParityTests.fixture("media/ref_en.srt"), encoding: .utf8)
        return raw.components(separatedBy: "\n").filter { $0.contains("-->") }
            .map { SubtitleTiming.timestampMs($0.components(separatedBy: " --> ")[0]) }
    }()

    /// shift 毫秒偏移、scale 速度、cutAt（0 到 1）之后再多偏移 cutShift。
    static func srt(shift: Int = 0, scale: Double = 1, cutAt: Double? = nil, cutShift: Int = 0) -> Data {
        let a0 = starts.first!, a1 = starts.last!
        return Data(starts.enumerated().map { i, s in
            var t = Int(Double(s) * scale) + shift
            if let c = cutAt, Double(s - a0) > Double(a1 - a0) * c { t += cutShift }
            return "\(i + 1)\n\(SubtitleTiming.format(t, like: "00:00:00,000", kind: .pair)) --> \(SubtitleTiming.format(t + 1500, like: "00:00:00,000", kind: .pair))\nline \(i)\n"
        }.joined(separator: "\n").utf8)
    }

    func settle(_ seconds: Double = 1.0) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    func testFFmpegModeWaitsForReference() async {
        let player = MockPlayer()
        let coord = AutoSyncCoordinator(player: player, language: .zh)
        coord.mediaDidOpen(MediaSource(url: URL(string: "https://example.invalid/movie.mkv?api_key=x")!, cacheKey: "emby:1"), mode: .ffmpegIndex)
        player.current[0] = "A"
        coord.subtitleDidLoad(slot: 0, id: "A", data: Self.srt(shift: 6500), fileName: "a.srt", userInitiated: true)
        await settle(0.3)
        XCTAssertTrue(player.replaced.isEmpty, "must wait for the FFmpeg index, never fall back to HTTP")
        coord.setFFmpegReference(Self.starts)
        await settle()
        XCTAssertEqual(player.replaced.map(\.id), ["A"])
        XCTAssertEqual(player.toasts.last, "字幕已自动同步：已提前 6.5 秒（匹配 100%）")
        XCTAssertEqual(player.resets, 1)
    }

    func testNoReferenceAndDisabled() async {
        let player = MockPlayer()
        let coord = AutoSyncCoordinator(player: player, language: .zh)
        coord.mediaDidOpen(MediaSource(url: URL(string: "https://example.invalid/a.mp4")!), mode: .ffmpegIndex)
        coord.setFFmpegReference(nil)
        player.current[0] = "A"
        coord.subtitleDidLoad(slot: 0, id: "A", data: Self.srt(shift: 3000), fileName: "a.srt", userInitiated: true)
        await settle(0.5)
        XCTAssertTrue(player.replaced.isEmpty)
        XCTAssertEqual(player.toasts.last, "视频里的内嵌字幕太少或不能作参照，保留原字幕")
        // 直播：什么都不做
        coord.mediaDidOpen(MediaSource(url: URL(string: "http://iptv.invalid/live/1.ts")!, isLive: true), mode: .httpRange)
        let n = player.toasts.count
        coord.subtitleDidLoad(slot: 0, id: "A", data: Self.srt(shift: 3000), fileName: "a.srt", userInitiated: false)
        await settle(0.3)
        XCTAssertEqual(player.toasts.count, n)
        coord.syncNow(slot: 0, id: "A", data: Self.srt(shift: 3000), fileName: "a.srt")
        XCTAssertEqual(player.toasts.last, "直播流或无法读取索引的播放地址，不做自动同步")
    }

    func testHTTPRangeModeWithLocalFileAndLastSelectionWins() async {
        let player = MockPlayer()
        let coord = AutoSyncCoordinator(player: player, language: .zh)
        coord.mediaDidOpen(MediaSource(url: ParityTests.fixture("media/multi.mkv")), mode: .httpRange)
        player.current[0] = "B"
        coord.subtitleDidLoad(slot: 0, id: "B", data: Self.srt(shift: -3000), fileName: "b.srt", userInitiated: true)
        player.current[0] = "C"
        coord.subtitleDidLoad(slot: 0, id: "C", data: Self.srt(scale: 24.0 / 25.0), fileName: "c.srt", userInitiated: true)
        await settle(1.5)
        XCTAssertEqual(player.replaced.map(\.id), ["C"])
        XCTAssertEqual(player.toasts.last, "字幕已自动同步：已校正 24 与 25 帧率差（匹配 100%）")
    }

    func testDifferentCutIsNotApplied() async {
        let player = MockPlayer()
        let coord = AutoSyncCoordinator(player: player, language: .zh)
        coord.mediaDidOpen(MediaSource(url: URL(string: "https://example.invalid/movie.mkv")!), mode: .ffmpegIndex)
        coord.setFFmpegReference(Self.starts)
        player.current[0] = "D"
        // 70% 处多了一段 5 秒：DexWorld 原版会按多数段整体平移
        let data = Self.srt(shift: -2000, cutAt: 0.7, cutShift: -5000)
        let res = SubtitleAligner.align(reference: Self.starts, subtitle: SubtitleTiming.parseStarts([UInt8](data), name: "d.srt"))
        XCTAssertEqual(SubtitleAligner.decide(res, minMatch: 0.45), .sync, "precondition: the plain DexWorld decision says sync")
        coord.subtitleDidLoad(slot: 0, id: "D", data: data, fileName: "d.srt", userInitiated: true)
        await settle()
        XCTAssertTrue(player.replaced.isEmpty)
        XCTAssertEqual(player.toasts.last, "字幕和这个视频的剪辑版本不同（片中有一段对不上），保留原字幕")
    }

    func testManualButtonReusesSyncedButRecomputesNegative() async {
        let engine = SubtitleAutoSyncEngine()
        let ref = ReferenceTimeline(starts: Self.starts)
        let good = Self.srt(shift: 4000)
        let first = await engine.synchronize(subtitle: good, fileName: "g.srt", reference: ref, cacheKey: "m")
        guard case .synced(let s1) = first, !s1.fromCache else { return XCTFail("\(first)") }
        let again = await engine.synchronize(subtitle: good, fileName: "g.srt", reference: ref, cacheKey: "m", cachePolicy: .ignoreNegative)
        guard case .synced(let s2) = again, s2.fromCache else { return XCTFail("\(again)") }
        let fresh = await engine.synchronize(subtitle: good, fileName: "g.srt", reference: ref, cacheKey: "m", cachePolicy: .bypass)
        guard case .synced(let s3) = fresh, !s3.fromCache else { return XCTFail("\(fresh)") }
        // 本来同步的结果：.use 返回缓存，.ignoreNegative 重新算（结果相同但不是缓存）
        let same = Self.srt(shift: 50)
        _ = await engine.synchronize(subtitle: same, fileName: "s.srt", reference: ref, cacheKey: "m")
        let cached = await engine.synchronize(subtitle: same, fileName: "s.srt", reference: ref, cacheKey: "m")
        guard case .alreadyInSync = cached else { return XCTFail("\(cached)") }
        let manual = await engine.synchronize(subtitle: same, fileName: "s.srt", reference: ref, cacheKey: "m", cachePolicy: .ignoreNegative)
        guard case .alreadyInSync = manual else { return XCTFail("\(manual)") }
    }

    func testArabicAndEnglishMessages() async {
        let player = MockPlayer()
        let coord = AutoSyncCoordinator(player: player, language: .ar)
        coord.mediaDidOpen(MediaSource(url: URL(string: "https://example.invalid/movie.mkv")!), mode: .ffmpegIndex)
        coord.setFFmpegReference(Self.starts)
        player.current[0] = "A"
        coord.subtitleDidLoad(slot: 0, id: "A", data: Self.srt(shift: 6500), fileName: "a.srt", userInitiated: true)
        await settle()
        XCTAssertEqual(player.toasts.last, "تمت مزامنة الترجمة تلقائياً: تم تقديم الترجمة 6.5 ثانية (تطابق 100%)")
        var r = AlignmentResult()
        r.scale = 25.0 / 24.0
        r.matched = 0.97
        XCTAssertEqual(r.summary(.en), "fixed frame-rate mismatch 24 ↔ 25 fps (97% matched)")
        r.scale = 1.0
        r.offsetMs = 4300
        XCTAssertEqual(r.change(.ar), "تم تأخير الترجمة 4.3 ثانية")
        XCTAssertEqual(r.change(.en), "moved 4.3 s later")
    }
}
