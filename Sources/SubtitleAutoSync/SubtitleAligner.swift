import Foundation

/// 对齐结果：新时间 = 旧时间 × scale + offsetMs。
public struct AlignmentResult: Equatable, Sendable {
    /// 速度比例。1.0 表示只有平移；25/23.976 等表示帧率差。
    public var scale: Double = 1.0
    /// 平移（毫秒，四舍六入五成双取整）。
    public var offsetMs: Int = 0
    /// 能对上参照的字幕行比例（hits / total）。
    public var matched: Double = 0
    /// 最好的“另一种解”（在开头、中间、结尾任一处差 1.5 秒以上）的匹配比例。
    public var rival: Double = 0
    /// 能对上的行数。
    public var hits: Int = 0
    /// 字幕去重后的行数。
    public var total: Int = 0
    /// 应用这个变换后，字幕在开头、中间、结尾三点最多移动多少毫秒。
    public var maxMoveMs: Int = 0
    /// 无法对齐的原因（目前只有 "too_few_lines"）。
    public var reason: String?

    public init() {}

    /// 对单个时间点应用变换。
    public func map(_ ms: Double) -> Double { ms * scale + Double(offsetMs) }
}

public enum AlignmentDecision: String, Sendable {
    /// 匹配度高且明显好于其他解：应用。
    case sync
    /// 匹配度高，但移动不到 250 ms：本来就是同步的，不改。
    case inSync = "in_sync"
    /// 匹配度不够或不够明确：保留原字幕。
    case unsure
}

/// 只用时间（不看文字）把外挂字幕对齐到参照时间轴。
///
/// 算法与 DexWorld 插件 dexalign.py 完全相同（有 261 组逐项对比测试）：
/// 1. 对 7 个速度比例（1、25/23.976、23.976/25、25/24、24/25、24/23.976、23.976/24），
///    用“参照开始时间 − 字幕开始时间”做 100 ms 一格的直方图投票（±300 秒），取前 4 个峰作为候选。
/// 2. 每个候选：最近邻配对（容差 350 ms），用残差中位数修正两次，再做最小二乘拟合速度和平移。
/// 3. 以配上的行数打分，并找出“明显不同的第二名”（rival）。
/// 4. decide()：匹配 ≥ minMatch、比第二名高出 ≥ 20 个百分点、至少 20 行，才应用。
public enum SubtitleAligner {

    public static let scales: [Double] = [
        1.0, 25.0 / 23.976, 23.976 / 25.0, 25.0 / 24.0, 24.0 / 25.0, 24.0 / 23.976, 23.976 / 24.0,
    ]

    public static func align(reference refStarts: [Int], subtitle subStarts: [Int],
                             maxOffsetMs: Int = 300_000, toleranceMs: Double = 350,
                             sample: Int = 400) -> AlignmentResult {
        let ref = dedupe(refStarts)
        let sub = dedupe(subStarts)
        var res = AlignmentResult()
        res.total = sub.count
        if ref.count < 30 || sub.count < 30 {
            res.reason = "too_few_lines"
            return res
        }

        // 1. 直方图投票，生成候选 (scale, offset)
        let step = max(1, sub.count / sample)
        let votesFrom = stride(from: 0, to: sub.count, by: step).map { sub[$0] }
        let r = maxOffsetMs / 100
        let refD = ref.map(Double.init)
        var cands: [(scale: Double, offset: Double)] = [(1.0, 0.0)]
        var hist = [Int](repeating: 0, count: 2 * r + 3)
        var sm = [Int](repeating: 0, count: 2 * r + 1)
        for sc in scales {
            for i in hist.indices { hist[i] = 0 }
            for s in votesFrom {
                let x = Double(s) * sc
                let lo = bisectLeft(refD, x - Double(maxOffsetMs))
                let hi = bisectRight(refD, x + Double(maxOffsetMs))
                if lo < hi {
                    for k in lo..<hi {
                        hist[Int((refD[k] - x) / 100.0 + Double(r) + 1.5)] += 1
                    }
                }
            }
            for k in 1..<(hist.count - 1) { sm[k - 1] = hist[k - 1] + hist[k] + hist[k + 1] }
            // 票数从高到低；同票时下标小的在前（与 Python 稳定排序一致）
            let order = sm.indices.sorted { sm[$0] != sm[$1] ? sm[$0] > sm[$1] : $0 < $1 }
            var taken: [Int] = []
            for k in order {
                if taken.count >= 4 || sm[k] <= 0 { break }
                if taken.allSatisfy({ abs(k - $0) > 10 }) {
                    taken.append(k)
                    cands.append((sc, Double(k - r) * 100.0))
                }
            }
        }

        // 2. 精修每个候选并打分
        var scored: [(hits: Int, scale: Double, offset: Double, order: Int)] = []
        for (i, c) in cands.enumerated() {
            let (s2, o2, pairs) = refine(ref, sub, c.scale, c.offset, toleranceMs)
            scored.append((pairs.count, s2, o2, i))
        }
        scored.sort { $0.hits != $1.hits ? $0.hits > $1.hits : $0.order < $1.order }
        let best = scored[0]

        // 3. 第二名：在开头、中间、结尾任一处与第一名相差超过 1.5 秒的最好解
        let probes = [sub[0], sub[sub.count / 2], sub[sub.count - 1]].map(Double.init)
        func moved(_ sc: Double, _ o: Double, _ sc2: Double, _ o2: Double) -> Double {
            var m = -Double.infinity
            for p in probes { m = Swift.max(m, abs((p * sc + o) - (p * sc2 + o2))) }
            return m
        }
        var rival = 0
        for c in scored.dropFirst() where moved(c.scale, c.offset, best.scale, best.offset) > 1500 {
            rival = c.hits
            break
        }
        let total = Double(sub.count)
        res.scale = best.scale
        res.offsetMs = Int(best.offset.rounded(.toNearestOrEven))
        res.hits = best.hits
        res.matched = Double(best.hits) / total
        res.rival = Double(rival) / total
        res.maxMoveMs = Int(moved(best.scale, best.offset, 1.0, 0.0).rounded(.toNearestOrEven))
        return res
    }

    /// 安全决策：只有匹配高、并且明显好于任何其他解时才应用。
    public static func decide(_ res: AlignmentResult, minMatch: Double = 0.5, minMargin: Double = 0.2,
                              minHits: Int = 20, noopMs: Int = 250) -> AlignmentDecision {
        if res.reason != nil { return .unsure }
        let strong = res.matched >= minMatch && (res.matched - res.rival) >= minMargin && res.hits >= minHits
        if !strong { return .unsure }
        if res.maxMoveMs < noopMs { return .inSync }
        return .sync
    }

    // MARK: - 三段一致性检查（DexWorld 原版没有，这是 Swift 版加的安全检查）

    /// 一段（字幕时间范围的三分之一）的检查结果。
    public struct SegmentResult: Equatable, Sendable {
        /// 这一段在全局变换下的匹配比例。
        public var global: Double
        /// 这一段换成某个离全局至少 1 秒的偏移后，能达到的最好匹配比例。
        public var bestOther: Double
        /// 这一段更像属于另一个偏移（说明字幕和视频的剪辑版本不同）。
        public var disagrees: Bool
    }

    public struct SegmentCheck: Equatable, Sendable {
        public var ok: Bool
        /// 前、中、后三段；行数太少的段为 nil。
        public var segments: [SegmentResult?]
    }

    /// 检查前、中、后三段是否都认同同一个变换。
    ///
    /// 只看总体匹配率时，片中有一段剪辑差异的字幕（例如 70% 的行偏移 A、30% 偏移 B）仍可能通过，
    /// 结果是整体按多数段平移、少数段继续错。这里对每一段单独投票：如果某个离全局至少 1 秒的偏移
    /// 能让这一段匹配得差不多好（≥ 全局 − 0.10，且 ≥ 0.30），就判定为不同剪辑，不应用。
    /// 参照里缺一段（那一段任何偏移都对不上）不会被误判。
    public static func segmentCheck(reference refStarts: [Int], subtitle subStarts: [Int], result: AlignmentResult,
                                    toleranceMs: Double = 350, maxOffsetMs: Int = 300_000,
                                    excludeMs: Double = 1000, margin: Double = 0.10, floor: Double = 0.30,
                                    minLines: Int = 10) -> SegmentCheck {
        let ref = dedupe(refStarts)
        let sub = dedupe(subStarts)
        guard let a = sub.first, let b = sub.last, !ref.isEmpty else { return SegmentCheck(ok: true, segments: []) }
        let sc = result.scale
        let off = Double(result.offsetMs)
        let span = Double(b - a)
        let refD = ref.map(Double.init)
        let r = maxOffsetMs / 100
        var hist = [Int](repeating: 0, count: 2 * r + 3)
        var sm = [Int](repeating: 0, count: 2 * r + 1)
        var segments: [SegmentResult?] = []
        for i in 0..<3 {
            let lo = Double(a) + span * Double(i) / 3.0
            let hi = Double(a) + span * Double(i + 1) / 3.0
            let part = sub.filter { lo <= Double($0) && (Double($0) < hi || (i == 2 && Double($0) <= hi)) }
            if part.count < minLines {
                segments.append(nil)
                continue
            }
            let n = Double(part.count)
            let g = Double(match(ref, part, sc, off, toleranceMs).count) / n
            for k in hist.indices { hist[k] = 0 }
            for s in part {
                let x = Double(s) * sc + off
                let l = bisectLeft(refD, x - Double(maxOffsetMs))
                let h = bisectRight(refD, x + Double(maxOffsetMs))
                if l < h {
                    for k in l..<h { hist[Int((refD[k] - x) / 100.0 + Double(r) + 1.5)] += 1 }
                }
            }
            for k in 1..<(hist.count - 1) { sm[k - 1] = hist[k - 1] + hist[k] + hist[k + 1] }
            let order = sm.indices.sorted { sm[$0] != sm[$1] ? sm[$0] > sm[$1] : $0 < $1 }
            var taken: [Int] = []
            var best = 0.0
            for k in order {
                if taken.count >= 3 || sm[k] <= 0 { break }
                let shift = Double(k - r) * 100.0
                if abs(shift) <= excludeMs { continue }
                if taken.allSatisfy({ abs(k - $0) > 10 }) {
                    taken.append(k)
                    var pairs = match(ref, part, sc, off + shift, toleranceMs)
                    if !pairs.isEmpty {
                        let shift2 = shift + median(pairs.map { $0.d })
                        pairs = abs(shift2) > excludeMs ? match(ref, part, sc, off + shift2, toleranceMs) : []
                    }
                    best = max(best, Double(pairs.count) / n)
                }
            }
            segments.append(SegmentResult(global: g, bestOther: best, disagrees: best >= max(floor, g - margin)))
        }
        return SegmentCheck(ok: !segments.contains { $0?.disagrees == true }, segments: segments)
    }

    // MARK: - 内部步骤

    struct Pair {
        let s: Int
        let r: Int
        let d: Double
    }

    static func dedupe(_ xs: [Int], gap: Int = 40) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(xs.count)
        for x in xs.sorted() where out.isEmpty || x - out[out.count - 1] > gap {
            out.append(x)
        }
        return out
    }

    /// 两个指针：每个变换后的字幕开始时间找最近的参照开始时间，误差在 tol 以内算配上。
    static func match(_ ref: [Int], _ sub: [Int], _ scale: Double, _ off: Double, _ tol: Double) -> [Pair] {
        var pairs: [Pair] = []
        pairs.reserveCapacity(sub.count)
        var j = 0
        let n = ref.count
        for s in sub {
            let x = Double(s) * scale + off
            while j + 1 < n && Double(ref[j + 1]) <= x { j += 1 }
            var bestR = 0
            var bestD = 0.0
            var found = false
            for k in [j, j + 1] where k >= 0 && k < n {
                let d = Double(ref[k]) - x
                if !found || abs(d) < abs(bestD) {
                    bestR = ref[k]
                    bestD = d
                    found = true
                }
            }
            if found && abs(bestD) <= tol { pairs.append(Pair(s: s, r: bestR, d: bestD)) }
        }
        return pairs
    }

    static func median(_ v: [Double]) -> Double {
        if v.isEmpty { return 0 }
        let s = v.sorted()
        return s[s.count / 2]
    }

    /// 最小二乘：参照 = a × 字幕 + b
    static func fit(_ pairs: [Pair]) -> (a: Double, b: Double)? {
        let n = Double(pairs.count)
        if n < 20 { return nil }
        var sx = 0
        var sy = 0
        for p in pairs {
            sx += p.s
            sy += p.r
        }
        let mx = Double(sx) / n
        let my = Double(sy) / n
        var vxx = 0.0
        for p in pairs {
            let dx = Double(p.s) - mx
            vxx += dx * dx
        }
        if vxx <= 0 { return nil }
        var cov = 0.0
        for p in pairs { cov += (Double(p.s) - mx) * (Double(p.r) - my) }
        let a = cov / vxx
        return (a, my - a * mx)
    }

    static func refine(_ ref: [Int], _ sub: [Int], _ scale0: Double, _ off0: Double,
                       _ tol: Double) -> (Double, Double, [Pair]) {
        var scale = scale0
        var off = off0
        var pairs = match(ref, sub, scale, off, tol)
        for _ in 0..<2 {
            if pairs.isEmpty { break }
            off += median(pairs.map { $0.d })
            pairs = match(ref, sub, scale, off, tol)
        }
        if let f = fit(pairs), f.a >= 0.94 && f.a <= 1.07 {
            let p2 = match(ref, sub, f.a, f.b, tol)
            if p2.count >= pairs.count {
                scale = f.a
                off = f.b
                pairs = p2
                if !pairs.isEmpty {
                    off += median(pairs.map { $0.d })
                    pairs = match(ref, sub, scale, off, tol)
                }
            }
        }
        return (scale, off, pairs)
    }

    static func bisectLeft(_ a: [Double], _ x: Double) -> Int {
        var lo = 0
        var hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static func bisectRight(_ a: [Double], _ x: Double) -> Int {
        var lo = 0
        var hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if x < a[mid] { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}
