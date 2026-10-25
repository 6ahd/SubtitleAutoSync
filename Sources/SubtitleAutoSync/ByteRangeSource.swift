import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 读取失败的原因（字符串与 DexWorld 插件一致，方便对照日志）。
public struct CuesError: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String
    public let detail: String
    public init(_ reason: String, _ detail: String = "") {
        self.reason = reason
        self.detail = detail
    }
    public var description: String { detail.isEmpty ? reason : "\(reason): \(detail)" }

    /// 同一个文件换个位置再试也没用的错误（预算用完、服务器不支持 Range、网络错误）。
    var isFatal: Bool {
        ["budget_bytes", "budget_requests", "timeout", "no_range", "bad_range", "http_io", "io_error",
         "cancelled"].contains(reason)
            || reason.hasPrefix("http_")
    }

    /// 临时错误：过一会儿可以重试，只短时间缓存（DexWorld 60 秒）。
    /// HTTP 408/425/429/5xx 也算临时（NuvioTV 的做法）；其他 4xx 算确定失败。
    public var isTransient: Bool {
        if ["timeout", "http_io", "io_error", "budget_requests", "budget_bytes", "cancelled"].contains(reason) {
            return true
        }
        if reason.hasPrefix("http_"), let code = Int(reason.dropFirst(5)) {
            return code == 408 || code == 425 || code == 429 || code >= 500
        }
        return false
    }
}

public struct ReadStats: Equatable, Sendable {
    public var bytes: Int
    public var requests: Int
    public var milliseconds: Int
}

/// 一次读取的总预算：字节数、请求数、总时间。任何一项用完就停，绝不把整部电影下载下来。
public final class ReadBudget: @unchecked Sendable {
    public let maxBytes: Int
    public let maxRequests: Int
    public let started: Date
    public let deadline: Date
    private let lock = NSLock()
    private var _bytes = 0
    private var _requests = 0

    public init(maxBytes: Int = 24 << 20, maxRequests: Int = 16, timeout: TimeInterval = 25) {
        self.maxBytes = maxBytes
        self.maxRequests = maxRequests
        self.started = Date()
        self.deadline = started.addingTimeInterval(timeout)
    }

    public var secondsLeft: TimeInterval { deadline.timeIntervalSinceNow }

    /// 申请读取 length 字节，返回实际允许的长度。
    func take(_ length: Int, partialOK: Bool) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        if _requests + 1 > maxRequests { throw CuesError("budget_requests", String(maxRequests)) }
        let room = maxBytes - _bytes
        if room <= 0 || (!partialOK && length > room) { throw CuesError("budget_bytes", "\(maxBytes >> 20)MB") }
        if secondsLeft <= 0 { throw CuesError("timeout") }
        _requests += 1
        return min(length, room)
    }

    func add(_ n: Int) {
        lock.lock()
        _bytes += n
        lock.unlock()
    }

    public var stats: ReadStats {
        lock.lock()
        defer { lock.unlock() }
        return ReadStats(bytes: _bytes, requests: _requests,
                         milliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }
}

/// 按字节范围读取的数据源（本地文件、HTTP Range、或你自己的实现，例如播放器已有的 AVIOContext）。
public protocol ByteRangeSource: AnyObject {
    /// 文件总长度；未知时为 nil（HTTP 在第一次 206 响应后从 Content-Range 得到）。
    var size: Int64? { get }
    var budget: ReadBudget { get }
    /// 从 pos 读取最多 length 字节。partialOK 为 false 时预算不够就直接失败。
    func read(_ pos: Int64, _ length: Int, partialOK: Bool) async throws -> [UInt8]
    func close()
}

// MARK: - 本地文件

public final class FileRangeSource: ByteRangeSource {
    public let budget: ReadBudget
    public private(set) var size: Int64?
    private let handle: FileHandle

    public init(path: String, budget: ReadBudget) throws {
        self.budget = budget
        guard let h = FileHandle(forReadingAtPath: path) else { throw CuesError("io_error", "open") }
        handle = h
        do {
            size = Int64(try h.seekToEnd())
        } catch {
            throw CuesError("io_error", "\(error)")
        }
    }

    public func read(_ pos: Int64, _ length: Int, partialOK: Bool = true) async throws -> [UInt8] {
        var length = length
        if let size {
            if pos >= size { return [] }
            length = Int(min(Int64(length), size - pos))
        }
        if length <= 0 { return [] }
        length = try budget.take(length, partialOK: partialOK)
        do {
            try handle.seek(toOffset: UInt64(pos))
            let data = try handle.read(upToCount: length) ?? Data()
            budget.add(data.count)
            return [UInt8](data)
        } catch {
            throw CuesError("io_error", "\(error)")
        }
    }

    public func close() { try? handle.close() }
}

// MARK: - HTTP Range

/// 用 HTTP Range 请求读取远程文件的一小段。
///
/// - 带上播放用的请求头（Emby/Jellyfin/Plex 的 token、Cookie、User-Agent 等）。
/// - 服务器忽略 Range（返回 200）时：从 0 开始的第一次读取只取需要的字节后立即断开；之后的读取直接失败（no_range），
///   绝不下载整个文件。
/// - 跟随重定向，并记住最终地址。
/// - 检查 206 的 Content-Range 起点，防止错位的数据。
public final class HTTPRangeSource: NSObject, ByteRangeSource, URLSessionDataDelegate, @unchecked Sendable {
    public let headers: [String: String]
    public let budget: ReadBudget
    private let lock = NSLock()
    private var _url: URL
    private var _size: Int64?
    private var noRange = false
    private var session: URLSession!
    private var pending: Pending?

    private final class Pending: @unchecked Sendable {
        let task: URLSessionDataTask
        let pos: Int64
        let want: Int
        var cont: CheckedContinuation<[UInt8], Error>?
        var buf: [UInt8] = []
        init(task: URLSessionDataTask, pos: Int64, want: Int, cont: CheckedContinuation<[UInt8], Error>) {
            self.task = task
            self.pos = pos
            self.want = want
            self.cont = cont
        }
    }

    public init(url: URL, headers: [String: String] = [:], budget: ReadBudget,
                configuration: URLSessionConfiguration = .ephemeral) {
        _url = url
        self.headers = headers
        self.budget = budget
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    public var url: URL { lock.lock(); defer { lock.unlock() }; return _url }
    public var size: Int64? { lock.lock(); defer { lock.unlock() }; return _size }
    /// 服务器已经表明不支持 Range（返回过 200）。
    public var rangeUnsupported: Bool { lock.lock(); defer { lock.unlock() }; return noRange }

    public func read(_ pos: Int64, _ length: Int, partialOK: Bool = true) async throws -> [UInt8] {
        var length = length
        if let size {
            if pos >= size { return [] }
            length = Int(min(Int64(length), size - pos))
        }
        if length <= 0 { return [] }
        if rangeUnsupported { throw CuesError("no_range") }
        length = try budget.take(length, partialOK: partialOK)
        let left = budget.secondsLeft
        if left <= 0 { throw CuesError("timeout", "http") }

        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=\(pos)-\(pos + Int64(length) - 1)", forHTTPHeaderField: "Range")
        if !headers.keys.contains(where: { $0.lowercased() == "accept-encoding" }) {
            req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        req.timeoutInterval = 12   // 空闲超时；总时间由下面自己的计时器控制
        let want = length
        let data: [UInt8] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
                lock.lock()
                let task = session.dataTask(with: req)
                let p = Pending(task: task, pos: pos, want: want, cont: cont)
                pending = p
                lock.unlock()
                // 整体预算到期：不管连接处于什么状态都立即结束这次读取
                DispatchQueue.global().asyncAfter(deadline: .now() + min(12, left)) { [weak self, weak p] in
                    guard let self, let p else { return }
                    if self.finish(p, .failure(CuesError("timeout", "http"))) { p.task.cancel() }
                }
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.cancelPending()
        }
        budget.add(data.count)
        return data
    }

    public func close() { session.invalidateAndCancel() }

    // MARK: 内部

    private func current(_ task: URLSessionTask) -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = pending, p.task.taskIdentifier == task.taskIdentifier, p.cont != nil else { return nil }
        return p
    }

    /// 结束一次读取（只会生效一次）。返回 true 表示这次调用真正结束了它。
    @discardableResult
    private func finish(_ p: Pending, _ result: Result<[UInt8], Error>) -> Bool {
        lock.lock()
        let cont = p.cont
        p.cont = nil
        if pending === p { pending = nil }
        lock.unlock()
        cont?.resume(with: result)
        return cont != nil
    }

    private func cancelPending() {
        lock.lock()
        let p = pending
        lock.unlock()
        guard let p else { return }
        finish(p, .failure(CancellationError()))
        p.task.cancel()
    }

    #if canImport(FoundationNetworking)
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        handleResponse(dataTask, response, completionHandler)
    }
    #else
    // Apple SDK 把这个回调标成了 @Sendable
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        handleResponse(dataTask, response, completionHandler)
    }
    #endif

    private func handleResponse(_ dataTask: URLSessionDataTask, _ response: URLResponse,
                                _ completionHandler: (URLSession.ResponseDisposition) -> Void) {
        guard let p = current(dataTask) else { completionHandler(.cancel); return }
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        switch code {
        case 200:
            lock.lock()
            noRange = true
            lock.unlock()
            if p.pos != 0 {
                finish(p, .failure(CuesError("no_range")))
                completionHandler(.cancel)
                return
            }
        case 206:
            let cr = http?.value(forHTTPHeaderField: "Content-Range") ?? ""
            // bytes 1000-1999/123456
            let afterUnit = cr.split(separator: " ").last.map(String.init) ?? ""
            let parts = afterUnit.split(separator: "/")
            if let range = parts.first, let startText = range.split(separator: "-").first,
               let start = Int64(startText), start != p.pos {
                finish(p, .failure(CuesError("bad_range", cr)))
                completionHandler(.cancel)
                return
            }
            if parts.count == 2, let total = Int64(parts[1].trimmingCharacters(in: .whitespaces)) {
                lock.lock()
                _size = total
                lock.unlock()
            }
        case 416:
            finish(p, .success([]))
            completionHandler(.cancel)
            return
        default:
            finish(p, .failure(CuesError("http_\(code)")))
            completionHandler(.cancel)
            return
        }
        if let final = response.url {
            lock.lock()
            if final != _url { _url = final }   // 记住重定向后的地址
            lock.unlock()
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let p = current(dataTask) else { return }
        p.buf.append(contentsOf: data)
        if p.buf.count >= p.want {
            finish(p, .success(Array(p.buf.prefix(p.want))))
            dataTask.cancel()
        } else if budget.secondsLeft <= 0 {
            finish(p, .failure(CuesError("timeout", "http")))
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let p = current(task) else { return }
        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut {
                finish(p, .failure(CuesError("timeout", "http")))
            } else {
                finish(p, .failure(CuesError("http_io", "\(ns.domain) \(ns.code)")))
            }
        } else {
            finish(p, .success(Array(p.buf.prefix(p.want))))
        }
    }
}
