import Foundation

/// 外挂字幕的时间解析与改写。
///
/// 只读取和改写时间戳，字幕正文、样式、换行和原始编码（UTF-8、Windows-1256、GBK 等）逐字节保持不变。
/// 做法：把非 UTF-16 的文件按 ISO-8859-1 一字节对应一个字符来看，正则只匹配 ASCII 的时间戳，
/// 所以替换时间戳不会碰到任何多字节字符。UTF-16 文件（带 BOM）先解码，改完再按原字节序和 BOM 编码回去。
///
/// 与 DexWorld 插件 dexalign.py 的 parse_starts / apply_transform 行为一致（有逐字节对比测试）。
public enum SubtitleTiming {

    public enum Kind: String, Sendable {
        /// SRT、WebVTT 一类：`起 --> 止`
        case pair
        /// ASS/SSA：`Dialogue: 层,起,止,`
        case ass
    }

    // 与 dexalign.py 相同的两个正则（改用编号分组）。
    // pair: 1=起始 2=箭头及空白 3=结束
    private static let pairRegex = try! NSRegularExpression(
        pattern: #"((?:\d{1,3}:)?\d{1,2}:\d{2}[,.]\d{1,3})([ \t]*-->[ \t]*)((?:\d{1,3}:)?\d{1,2}:\d{2}[,.]\d{1,3})"#)
    // ass: 1=Dialogue|Comment 2=冒号 3=层 4=起始 5=结束
    private static let assRegex = try! NSRegularExpression(
        pattern: #"^(Dialogue|Comment)(:[ \t]*)([^,\r\n]*),(\d{1,2}:\d{2}:\d{2}[.:]\d{1,3}),(\d{1,2}:\d{2}:\d{2}[.:]\d{1,3}),"#,
        options: [.anchorsMatchLines, .useUnixLineSeparators])

    /// 打开后的文本视图。
    private struct View {
        enum Mode { case bytes, utf16LE, utf16BE }
        let mode: Mode
        let text: NSString
    }

    private static func open(_ raw: [UInt8]) -> View {
        if raw.count >= 2, raw[0] == 0xFF, raw[1] == 0xFE {
            return View(mode: .utf16LE, text: decodeUTF16(raw, littleEndian: true) as NSString)
        }
        if raw.count >= 2, raw[0] == 0xFE, raw[1] == 0xFF {
            return View(mode: .utf16BE, text: decodeUTF16(raw, littleEndian: false) as NSString)
        }
        // ISO-8859-1：每个字节对应 U+0000...U+00FF 的一个字符，NSString 的 UTF-16 下标就等于字节下标。
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: raw.map { Unicode.Scalar($0) })
        return View(mode: .bytes, text: String(scalars) as NSString)
    }

    private static func decodeUTF16(_ raw: [UInt8], littleEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(raw.count / 2)
        var i = 2
        while i + 1 < raw.count {
            let a = UInt16(raw[i]), b = UInt16(raw[i + 1])
            units.append(littleEndian ? (a | (b << 8)) : ((a << 8) | b))
            i += 2
        }
        var s = String(decoding: units, as: UTF16.self)
        if (raw.count - 2) % 2 == 1 { s.append("\u{FFFD}") }   // 与 Python 'replace' 一致
        return s
    }

    private static func encodeUTF16(_ s: String, littleEndian: Bool) -> [UInt8] {
        var out: [UInt8] = littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]
        out.reserveCapacity(2 + s.utf16.count * 2)
        for u in s.utf16 {
            if littleEndian { out.append(UInt8(u & 0xFF)); out.append(UInt8(u >> 8)) }
            else { out.append(UInt8(u >> 8)); out.append(UInt8(u & 0xFF)) }
        }
        return out
    }

    /// 判断字幕类型：文件名是 .ass/.ssa，或前 6000 个字符里有 `[Events]`，就是 ASS。
    public static func detectKind(_ raw: [UInt8], name: String = "") -> Kind {
        let v = open(raw)
        let head = v.text.substring(to: min(6000, v.text.length)) as NSString
        let n = name.lowercased()
        if n.hasSuffix(".ass") || n.hasSuffix(".ssa")
            || head.range(of: "[Events]", options: .literal).location != NSNotFound { return .ass }
        return .pair
    }

    /// 所有字幕行的开始时间（毫秒，升序）。ASS 只取 Dialogue，跳过 Comment；结束早于开始的行忽略。
    public static func parseStarts(_ raw: [UInt8], name: String = "") -> [Int] {
        let kind = detectKind(raw, name: name)
        let v = open(raw)
        let regex = kind == .ass ? assRegex : pairRegex
        let (ga, gb) = kind == .ass ? (4, 5) : (1, 3)
        var out: [Int] = []
        for m in regex.matches(in: v.text as String, range: NSRange(location: 0, length: v.text.length)) {
            if kind == .ass, v.text.substring(with: m.range(at: 1)) != "Dialogue" { continue }
            let a = timestampMs(v.text.substring(with: m.range(at: ga)))
            let b = timestampMs(v.text.substring(with: m.range(at: gb)))
            if b >= a { out.append(a) }
        }
        return out.sorted()
    }

    /// 改写所有时间戳：新时间 = 旧时间 × scale + offsetMs。其他内容逐字节不变。
    /// 结束时间至少比开始晚 1 ms；负数时间夹到 0。
    public static func applyTransform(_ raw: [UInt8], scale: Double, offsetMs: Int, name: String = "") -> [UInt8] {
        let kind = detectKind(raw, name: name)
        let v = open(raw)
        let regex = kind == .ass ? assRegex : pairRegex
        let (ga, gb) = kind == .ass ? (4, 5) : (1, 3)

        func conv(_ t: String) -> Int {
            let x = (Double(timestampMs(t)) * scale + Double(offsetMs)).rounded(.toNearestOrEven)
            return max(0, Int(x))
        }

        let matches = regex.matches(in: v.text as String, range: NSRange(location: 0, length: v.text.length))
        switch v.mode {
        case .bytes:
            var out: [UInt8] = []
            out.reserveCapacity(raw.count + 64)
            var last = 0
            for m in matches {
                let ra = m.range(at: ga), rb = m.range(at: gb)
                let a0 = v.text.substring(with: ra), b0 = v.text.substring(with: rb)
                let na = conv(a0)
                let nb = max(na + 1, conv(b0))
                out.append(contentsOf: raw[last..<ra.location])
                out.append(contentsOf: Array(format(na, like: a0, kind: kind).utf8))
                out.append(contentsOf: raw[(ra.location + ra.length)..<rb.location])
                out.append(contentsOf: Array(format(nb, like: b0, kind: kind).utf8))
                last = rb.location + rb.length
            }
            out.append(contentsOf: raw[last...])
            return out
        case .utf16LE, .utf16BE:
            var s = ""
            var last = 0
            for m in matches {
                let ra = m.range(at: ga), rb = m.range(at: gb)
                let a0 = v.text.substring(with: ra), b0 = v.text.substring(with: rb)
                let na = conv(a0)
                let nb = max(na + 1, conv(b0))
                s += v.text.substring(with: NSRange(location: last, length: ra.location - last))
                s += format(na, like: a0, kind: kind)
                s += v.text.substring(with: NSRange(location: ra.location + ra.length,
                                                    length: rb.location - ra.location - ra.length))
                s += format(nb, like: b0, kind: kind)
                last = rb.location + rb.length
            }
            s += v.text.substring(from: last)
            return encodeUTF16(s, littleEndian: v.mode == .utf16LE)
        }
    }

    /// `HH:MM:SS,mmm`、`MM:SS.mmm`、ASS 的 `H:MM:SS.cc` 和旧式 `H:MM:SS:cc` 转毫秒。
    public static func timestampMs(_ raw: String) -> Int {
        let t = raw.replacingOccurrences(of: ",", with: ".")
        var main: String
        var frac: String
        if let dot = t.lastIndex(of: ".") {
            main = String(t[..<dot])
            frac = String(t[t.index(after: dot)...])
        } else {
            main = ""
            frac = t
        }
        if main.isEmpty {   // 旧式 ASS：H:MM:SS:cc
            let parts = t.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            main = parts.prefix(3).joined(separator: ":")
            frac = parts.count > 3 ? parts[3] : "0"
        }
        var parts = main.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        while parts.count < 3 { parts.insert(0, at: 0) }
        let h = parts[parts.count - 3], m = parts[parts.count - 2], s = parts[parts.count - 1]
        let ms = frac.isEmpty ? 0 : (Int(String((frac + "000").prefix(3))) ?? 0)
        return ((h * 60 + m) * 60 + s) * 1000 + ms
    }

    /// 按原时间戳的样子输出：保留逗号或点、是否带小时；ASS 输出百分之一秒。
    public static func format(_ msIn: Int, like orig: String, kind: Kind) -> String {
        let ms = max(0, msIn)
        let h = ms / 3_600_000
        var rem = ms % 3_600_000
        let m = rem / 60_000
        rem %= 60_000
        let s = rem / 1000
        let x = rem % 1000
        if kind == .ass {
            let cs = Int((Double(x) / 10.0).rounded(.toNearestOrEven))
            if cs == 100 { return format(ms + 5, like: orig, kind: kind) }   // 995 毫秒以上进位
            return "\(h):\(pad(m, 2)):\(pad(s, 2)).\(pad(cs, 2))"
        }
        let sep = orig.contains(",") ? "," : "."
        if orig.filter({ $0 == ":" }).count >= 2 || h > 0 {
            return "\(pad(h, 2)):\(pad(m, 2)):\(pad(s, 2))\(sep)\(pad(x, 3))"
        }
        return "\(pad(m, 2)):\(pad(s, 2))\(sep)\(pad(x, 3))"
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }
}
