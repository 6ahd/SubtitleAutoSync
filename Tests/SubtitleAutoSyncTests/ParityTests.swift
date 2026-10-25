import XCTest
@testable import SubtitleAutoSync

/// 与 DexWorld 插件 Python 原版（dexalign.py / dexcues.py）逐项对比。
/// Fixtures 里的 JSON 由 Python 原版生成。
final class ParityTests: XCTestCase {

    static func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent(name)
    }

    static func json(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: fixture(name)))
    }

    func testAlignmentMatchesPython() throws {
        let cases = try Self.json("align_cases.json") as! [[String: Any]]
        XCTAssertGreaterThan(cases.count, 200)
        var mismatches: [String] = []
        for c in cases {
            let id = c["id"] as! Int
            let ref = (c["ref"] as! [NSNumber]).map(\.intValue)
            let sub = (c["sub"] as! [NSNumber]).map(\.intValue)
            let exp = c["res"] as! [String: Any]
            let expDecision = c["decision"] as! String
            let got = SubtitleAligner.align(reference: ref, subtitle: sub)
            let decision = SubtitleAligner.decide(got, minMatch: 0.45)
            var diffs: [String] = []
            if let reason = exp["reason"] as? String {
                if got.reason != reason { diffs.append("reason \(String(describing: got.reason)) vs \(reason)") }
            } else {
                let scale = (exp["scale"] as! NSNumber).doubleValue
                if abs(got.scale - scale) > 1e-12 * max(1, abs(scale)) { diffs.append("scale \(got.scale) vs \(scale)") }
                if got.offsetMs != (exp["offset_ms"] as! NSNumber).intValue { diffs.append("offset \(got.offsetMs) vs \(exp["offset_ms"]!)") }
                if got.hits != (exp["hits"] as! NSNumber).intValue { diffs.append("hits \(got.hits) vs \(exp["hits"]!)") }
                if got.total != (exp["total"] as! NSNumber).intValue { diffs.append("total") }
                if abs(got.rival - (exp["rival"] as! NSNumber).doubleValue) > 1e-12 { diffs.append("rival \(got.rival) vs \(exp["rival"]!)") }
                if got.maxMoveMs != (exp["max_move_ms"] as! NSNumber).intValue { diffs.append("maxMove \(got.maxMoveMs) vs \(exp["max_move_ms"]!)") }
            }
            if decision.rawValue != expDecision { diffs.append("decision \(decision.rawValue) vs \(expDecision)") }
            if !diffs.isEmpty { mismatches.append("case \(id) [\(c["kind"]!)]: " + diffs.joined(separator: ", ")) }
        }
        XCTAssertTrue(mismatches.isEmpty, mismatches.prefix(20).joined(separator: "\n"))
        print("alignment parity: \(cases.count) cases, \(mismatches.count) mismatches")
    }

    func testSubtitleParseAndRewriteMatchPython() throws {
        let cases = try Self.json("subs_cases.json") as! [[String: Any]]
        for c in cases {
            let name = c["name"] as! String
            let raw = [UInt8](try Data(contentsOf: Self.fixture("subs/" + name)))
            XCTAssertEqual(SubtitleTiming.detectKind(raw, name: name).rawValue, c["kind"] as! String, name)
            let starts = (c["starts"] as! [NSNumber]).map(\.intValue)
            XCTAssertEqual(SubtitleTiming.parseStarts(raw, name: name), starts, name)
            for o in c["outputs"] as! [[String: Any]] {
                let scale = (o["scale"] as! NSNumber).doubleValue
                let off = (o["offset_ms"] as! NSNumber).intValue
                let expected = [UInt8](Data(base64Encoded: o["b64"] as! String)!)
                let got = SubtitleTiming.applyTransform(raw, scale: scale, offsetMs: off, name: name)
                XCTAssertEqual(got, expected, "\(name) scale \(scale) offset \(off)")
            }
        }
    }

    func testCuesReaderMatchesPython() async throws {
        let cases = try Self.json("cues_cases.json") as! [String: [String: Any]]
        for (file, exp) in cases.sorted(by: { $0.key < $1.key }) {
            let path = Self.fixture("media/" + file).path
            let src = try FileRangeSource(path: path, budget: MatroskaCues.Options().makeBudget())
            let r = await MatroskaCues.load(src)
            XCTAssertEqual(r.ok, exp["ok"] as! Bool, file)
            XCTAssertEqual(r.reason, exp["reason"] as? String, file)
            XCTAssertEqual(r.via, exp["via"] as? String, file)
            let st = exp["stats"] as! [String: Any]
            XCTAssertEqual(r.stats.bytes, (st["bytes"] as! NSNumber).intValue, "\(file) bytes read")
            XCTAssertEqual(r.stats.requests, (st["requests"] as! NSNumber).intValue, "\(file) requests")
            guard r.ok else { continue }
            let tracks = exp["tracks"] as! [[String: Any]]
            XCTAssertEqual(r.tracks.count, tracks.count, file)
            for (t, e) in zip(r.tracks, tracks) {
                XCTAssertEqual(t.number, (e["number"] as! NSNumber).intValue)
                XCTAssertEqual(t.codec, e["codec"] as! String)
                XCTAssertEqual(t.lang, e["lang"] as! String)
                XCTAssertEqual(t.isImage, (e["kind"] as! String) == "image")
                XCTAssertEqual(t.estimated, (e["estimated"] as! NSNumber).intValue)
                XCTAssertEqual(t.forced, e["forced"] as! Bool)
                XCTAssertEqual(t.hearingImpaired, e["hi"] as! Bool)
                XCTAssertEqual(t.commentary, e["commentary"] as! Bool)
                XCTAssertEqual(t.name, e["name"] as! String)
                XCTAssertEqual(t.isDefault, e["default"] as! Bool)
                let cues = (e["cues"] as! [[NSNumber]]).map { MatroskaCues.Cue(start: $0[0].intValue, end: $0[1].intValue) }
                XCTAssertEqual(t.cues, cues, "\(file) track \(t.number)")
            }
            let picked = MatroskaCues.pickReference(r.tracks)?.number
            XCTAssertEqual(picked, (exp["picked"] as? NSNumber)?.intValue, file)
        }
    }

    func testSegmentCheckMatchesPython() throws {
        let cases = try Self.json("segment_cases.json") as! [[String: Any]]
        var mismatches: [String] = []
        var rejected = 0
        for c in cases {
            let ref = (c["ref"] as! [NSNumber]).map(\.intValue)
            let sub = (c["sub"] as! [NSNumber]).map(\.intValue)
            let e = c["res"] as! [String: Any]
            var res = AlignmentResult()
            res.scale = (e["scale"] as! NSNumber).doubleValue
            res.offsetMs = (e["offset_ms"] as! NSNumber).intValue
            let got = SubtitleAligner.segmentCheck(reference: ref, subtitle: sub, result: res)
            let expOK = c["ok"] as! Bool
            if !expOK { rejected += 1 }
            var diffs: [String] = []
            if got.ok != expOK { diffs.append("ok \(got.ok) vs \(expOK)") }
            let det = c["details"] as! [Any]
            for (i, d) in det.enumerated() {
                let g = got.segments.count > i ? got.segments[i] : nil
                if let arr = d as? [Any] {
                    guard let g else { diffs.append("segment \(i) missing"); continue }
                    // Python 结果保留两位小数
                    if abs((g.global * 100).rounded() / 100 - (arr[0] as! NSNumber).doubleValue) > 1e-9 { diffs.append("seg \(i) global \(g.global)") }
                    if abs((g.bestOther * 100).rounded() / 100 - (arr[1] as! NSNumber).doubleValue) > 1e-9 { diffs.append("seg \(i) other \(g.bestOther)") }
                    if g.disagrees != (arr[2] as! Bool) { diffs.append("seg \(i) disagrees") }
                } else if g != nil {
                    diffs.append("segment \(i) should be nil")
                }
            }
            if !diffs.isEmpty { mismatches.append("case \(c["id"]!) [\(c["kind"]!)]: " + diffs.joined(separator: ", ")) }
        }
        XCTAssertGreaterThan(rejected, 5)
        XCTAssertTrue(mismatches.isEmpty, mismatches.prefix(20).joined(separator: "\n"))
        print("segment parity: \(cases.count) cases, \(rejected) rejected, \(mismatches.count) mismatches")
    }

    func testTimestampHelpers() {
        XCTAssertEqual(SubtitleTiming.timestampMs("01:02:03,456"), 3_723_456)
        XCTAssertEqual(SubtitleTiming.timestampMs("02:03.4"), 123_400)
        XCTAssertEqual(SubtitleTiming.timestampMs("0:00:01:50"), 1500)       // 旧式 ASS
        XCTAssertEqual(SubtitleTiming.format(1995, like: "0:00:00.00", kind: .ass), "0:00:02.00")
        XCTAssertEqual(SubtitleTiming.format(61_005, like: "01:00.000", kind: .pair), "01:01.005")
        XCTAssertEqual(SubtitleTiming.format(3_600_000, like: "59:59.999", kind: .pair), "01:00:00.000")
        var r = AlignmentResult()
        r.scale = 25.0 / 24.0
        XCTAssertEqual(r.changeZh, "已校正 24 与 25 帧率差")
        r.scale = 23.976 / 25.0
        XCTAssertEqual(r.changeZh, "已校正 23.976 与 25 帧率差")
        r.scale = 1.0
        r.offsetMs = -1250
        XCTAssertEqual(r.changeZh, "已提前 1.2 秒")
    }
}
