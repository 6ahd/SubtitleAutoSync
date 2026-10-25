import Foundation

/// Language of the toast / status messages.
public enum AutoSyncLanguage: String, Sendable, CaseIterable {
    case en, ar, zh
}

public extension AlignmentResult {
    /// What changed, in the given language. e.g. "moved 6.5 s earlier" / "تم تقديم الترجمة 6.5 ثانية".
    func change(_ lang: AutoSyncLanguage) -> String {
        if lang == .zh { return changeZh }
        let ar = lang == .ar
        if abs(scale - 1.0) > 0.0005 {
            let names: [(Double, String)] = [(25.0 / 23.976, "23.976 ↔ 25"), (25.0 / 24.0, "24 ↔ 25"),
                                             (24.0 / 23.976, "23.976 ↔ 24")]
            let best = names.map { (min(abs(scale - $0.0), abs(scale - 1.0 / $0.0)), $0.1) }.min { $0.0 < $1.0 }!
            if best.0 < 0.002 {
                return ar ? "تم تصحيح فرق معدل الإطارات \(best.1)" : "fixed frame-rate mismatch \(best.1) fps"
            }
            let pct = String(format: "%.2f", (scale - 1.0) * 100)
            return ar ? "تم تصحيح فرق السرعة (\(pct)%)" : "fixed speed difference (\(pct)%)"
        }
        let seconds = String(format: "%.1f", Double(abs(offsetMs)) / 1000.0)
        if ar { return offsetMs < 0 ? "تم تقديم الترجمة \(seconds) ثانية" : "تم تأخير الترجمة \(seconds) ثانية" }
        return offsetMs < 0 ? "moved \(seconds) s earlier" : "moved \(seconds) s later"
    }

    /// Change + match percentage. e.g. "moved 6.5 s earlier (100% matched)".
    func summary(_ lang: AutoSyncLanguage) -> String {
        let pct = Int((matched * 100).rounded())
        switch lang {
        case .zh: return summaryZh
        case .ar: return "\(change(.ar)) (تطابق \(pct)%)"
        case .en: return "\(change(.en)) (\(pct)% matched)"
        }
    }
}

public extension AutoSyncMessages {
    /// Message for an outcome in any supported language. Returns nil when nothing should be shown
    /// (automatically chosen subtitles only get a message when they were actually synced).
    static func text(_ outcome: AutoSyncOutcome, language: AutoSyncLanguage, userInitiated: Bool,
                     minMatch: Double = 0.45) -> String? {
        switch language {
        case .zh: return zh(outcome, userInitiated: userInitiated, minMatch: minMatch)
        case .ar: return ar(outcome, userInitiated: userInitiated, minMatch: minMatch)
        case .en: return en(outcome, userInitiated: userInitiated, minMatch: minMatch)
        }
    }

    static func en(_ outcome: AutoSyncOutcome, userInitiated: Bool, minMatch: Double = 0.45) -> String? {
        switch outcome {
        case .synced(let s):
            return s.fromCache ? "Applied the previously synced version of this subtitle"
                : "Subtitle synced automatically: " + s.alignment.summary(.en)
        case _ where !userInitiated:
            return nil
        case .alreadyInSync(let r):
            return "Subtitle is already in sync (\(pct(r.matched))% matched)"
        case .unsure(let r):
            if r.hits == 0 { return "Subtitle does not match this video, kept the original" }
            if r.matched < minMatch {
                return "Only \(pct(r.matched))% matched (need \(pct(minMatch))%), probably for another release. Kept the original"
            }
            return "\(pct(r.matched))% matched but the result is ambiguous, kept the original"
        case .differentCut:
            return "Subtitle is for a different cut of this video (one part does not match), kept the original"
        case .tooFewLines(let n):
            return "Subtitle has only \(n) lines, not enough for auto-sync"
        case .noReference(let reason):
            return reasonTextEN(reason) + ", kept the original"
        case .notSupported:
            return "Live stream or a source whose index cannot be read: auto-sync is off"
        case .invalidSubtitle:
            return "Could not read the subtitle file"
        }
    }

    static func ar(_ outcome: AutoSyncOutcome, userInitiated: Bool, minMatch: Double = 0.45) -> String? {
        switch outcome {
        case .synced(let s):
            return s.fromCache ? "تم تطبيق النسخة المتزامنة سابقاً من هذه الترجمة"
                : "تمت مزامنة الترجمة تلقائياً: " + s.alignment.summary(.ar)
        case _ where !userInitiated:
            return nil
        case .alreadyInSync(let r):
            return "الترجمة متزامنة أصلاً (تطابق \(pct(r.matched))%)"
        case .unsure(let r):
            if r.hits == 0 { return "الترجمة لا تطابق هذا الفيديو، تم الإبقاء على الأصل" }
            if r.matched < minMatch {
                return "التطابق \(pct(r.matched))% فقط (المطلوب \(pct(minMatch))%)، غالباً ترجمة لنسخة أخرى. تم الإبقاء على الأصل"
            }
            return "التطابق \(pct(r.matched))% لكن النتيجة غير حاسمة، تم الإبقاء على الأصل"
        case .differentCut:
            return "الترجمة لنسخة مونتاج مختلفة (جزء من الفيديو لا يطابق)، تم الإبقاء على الأصل"
        case .tooFewLines(let n):
            return "الترجمة فيها \(n) سطر فقط، غير كافية للمزامنة التلقائية"
        case .noReference(let reason):
            return reasonTextAR(reason) + "، تم الإبقاء على الأصل"
        case .notSupported:
            return "بث مباشر أو مصدر لا يمكن قراءة فهرسه: المزامنة التلقائية متوقفة"
        case .invalidSubtitle:
            return "تعذّرت قراءة ملف الترجمة"
        }
    }

    static func reasonTextEN(_ reason: String) -> String {
        switch reason {
        case "not_mkv": return "Video is not MKV, no readable subtitle index"
        case "no_subtitle_tracks": return "The video has no embedded subtitle to use as reference"
        case "no_usable_subtitles", "no_usable_text_track": return "The embedded subtitles are too short or unusable as reference"
        case "no_range": return "The server does not support Range requests"
        case "cues_too_large", "element_too_large": return "The video index is too large"
        case "no_cues", "no_segment", "unknown_size", "truncated", "short_file", "no_tracks": return "The video index is incomplete"
        default: return "Could not read the video index right now"
        }
    }

    static func reasonTextAR(_ reason: String) -> String {
        switch reason {
        case "not_mkv": return "الفيديو ليس MKV، لا يوجد فهرس ترجمة قابل للقراءة"
        case "no_subtitle_tracks": return "لا توجد ترجمة مدمجة في الفيديو لتكون مرجعاً"
        case "no_usable_subtitles", "no_usable_text_track": return "الترجمة المدمجة قليلة جداً أو لا تصلح مرجعاً"
        case "no_range": return "الخادم لا يدعم القراءة الجزئية (Range)"
        case "cues_too_large", "element_too_large": return "فهرس الفيديو كبير جداً"
        case "no_cues", "no_segment", "unknown_size", "truncated", "short_file", "no_tracks": return "فهرس الفيديو ناقص"
        default: return "تعذّرت قراءة فهرس الفيديو حالياً"
        }
    }
}
