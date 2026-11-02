import Foundation

public enum TranscodeError: Error, Equatable {
    case ffmpegMissing
    case failed(String)
}

extension TranscodeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .ffmpegMissing:
            return "未找到 FFmpeg"
        case .failed(let message):
            return message
        }
    }
}

/// Serial background transcoder. One ffmpeg process at a time; a playback
/// request jumps queued background work, and identical tracks share a job so
/// a source is never decoded twice.
public final class TranscodeQueue {
    private final class Job {
        let track: Track
        var waiters: [CheckedContinuation<URL, Error>] = []
        var isPriority = false

        init(track: Track) {
            self.track = track
        }
    }

    private let cacheRoot: URL
    private let worker = DispatchQueue(label: "com.local.soundisle.transcode", qos: .utility)
    private let lock = NSLock()
    private var ffmpeg: URL?
    private var jobs: [String: Job] = [:]
    private var priorityKeys: [String] = []
    private var backgroundKeys: [String] = []
    private var activeKey: String?

    public init(cacheRoot: URL, ffmpeg: URL?) {
        self.cacheRoot = cacheRoot
        self.ffmpeg = ffmpeg
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    public var isProcessing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeKey != nil
    }

    /// The configured binary can change from the settings screen; the queue
    /// keeps its pending work.
    public func updateFFmpeg(_ url: URL?) {
        lock.lock()
        ffmpeg = url
        lock.unlock()
    }

    public func cachedURL(for track: Track) -> URL? {
        let url = TranscodeCache.cacheURL(for: track, root: cacheRoot)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Fire-and-forget work: scanned tracks use `priority: false`, while a
    /// play request uses the high-priority queue.
    public func enqueue(_ track: Track, priority: Bool) {
        guard cachedURL(for: track) == nil, currentFFmpeg() != nil else { return }
        let key = cacheKey(track)

        lock.lock()
        if let job = jobs[key] {
            if priority {
                promoteLocked(key, job: job)
            }
        } else {
            let job = Job(track: track)
            job.isPriority = priority
            jobs[key] = job
            if priority {
                priorityKeys.append(key)
            } else {
                backgroundKeys.append(key)
            }
        }
        lock.unlock()

        startNextIfIdle()
    }

    /// Returns the cached file, waiting for a running/queued transcode. This is
    /// the playback path, so the request is promoted ahead of background work.
    public func ensureCached(_ track: Track) async throws -> URL {
        if let cached = cachedURL(for: track) {
            return cached
        }
        guard currentFFmpeg() != nil else {
            throw TranscodeError.ffmpegMissing
        }

        let key = cacheKey(track)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let job = jobs[key] {
                job.waiters.append(continuation)
                promoteLocked(key, job: job)
            } else {
                let job = Job(track: track)
                job.isPriority = true
                job.waiters.append(continuation)
                jobs[key] = job
                priorityKeys.append(key)
            }
            lock.unlock()

            startNextIfIdle()
        }
    }

    /// Refused while any job (running or queued) exists; holds the same lock
    /// the worker uses so a job cannot become active between the check and the
    /// deletion.
    public func clearCache() throws {
        lock.lock()
        defer { lock.unlock() }
        guard activeKey == nil, jobs.isEmpty else {
            throw TranscodeError.failed("正在准备歌曲，请稍后再清理缓存。")
        }

        let manager = FileManager.default
        if manager.fileExists(atPath: cacheRoot.path) {
            try manager.removeItem(at: cacheRoot)
        }
        try manager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    // MARK: - Scheduling

    private func promoteLocked(_ key: String, job: Job) {
        guard !job.isPriority else { return }
        job.isPriority = true
        backgroundKeys.removeAll { $0 == key }
        // The active job was already removed from both key lists; appending it
        // again would leave a key with no `jobs` entry and wedge the worker.
        guard activeKey != key else { return }
        priorityKeys.append(key)
    }

    private func startNextIfIdle() {
        lock.lock()
        guard activeKey == nil else {
            lock.unlock()
            return
        }
        // Defensive: never let a stale key hide a real queued job.
        while let first = priorityKeys.first, jobs[first] == nil {
            priorityKeys.removeFirst()
        }
        while let first = backgroundKeys.first, jobs[first] == nil {
            backgroundKeys.removeFirst()
        }
        let key = priorityKeys.first ?? backgroundKeys.first
        guard let key, let job = jobs[key] else {
            lock.unlock()
            return
        }
        priorityKeys.removeAll { $0 == key }
        backgroundKeys.removeAll { $0 == key }
        activeKey = key
        let track = job.track
        lock.unlock()

        // The worker is serial and `activeKey` ensures only one block is ever
        // scheduled, so at most one ffmpeg process exists at a time.
        worker.async { [weak self] in
            self?.run(key: key, track: track)
        }
    }

    private func run(key: String, track: Track) {
        let result: Result<URL, Error>
        if let cached = cachedURL(for: track) {
            result = .success(cached)
        } else if let ffmpeg = currentFFmpeg() {
            result = transcode(track, using: ffmpeg)
        } else {
            result = .failure(TranscodeError.ffmpegMissing)
        }

        lock.lock()
        activeKey = nil
        let job = jobs.removeValue(forKey: key)
        lock.unlock()

        if let job {
            for waiter in job.waiters {
                switch result {
                case .success(let url):
                    waiter.resume(returning: url)
                case .failure(let error):
                    waiter.resume(throwing: error)
                }
            }
        }
        startNextIfIdle()
    }

    // MARK: - Process

    private func transcode(_ track: Track, using ffmpeg: URL) -> Result<URL, Error> {
        let manager = FileManager.default
        let destination = TranscodeCache.cacheURL(for: track, root: cacheRoot)
        let temporary = destination.appendingPathExtension("tmp.m4a")

        do {
            try manager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        } catch {
            return .failure(TranscodeError.failed("无法创建转码缓存目录：\(error.localizedDescription)"))
        }
        try? manager.removeItem(at: temporary)

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-y",
            "-i", track.url.path,
            "-vn",
            "-c:a", "alac",
            temporary.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return .failure(TranscodeError.failed("无法启动 FFmpeg：\(error.localizedDescription)"))
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              manager.fileExists(atPath: temporary.path) else {
            try? manager.removeItem(at: temporary)
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let suffix = detail.isEmpty ? "" : "：\(String(detail.suffix(300)))"
            return .failure(TranscodeError.failed("FFmpeg 转码失败（\(process.terminationStatus)）\(suffix)"))
        }

        do {
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: temporary, to: destination)
            return .success(destination)
        } catch {
            try? manager.removeItem(at: temporary)
            return .failure(TranscodeError.failed("无法写入转码缓存：\(error.localizedDescription)"))
        }
    }

    // MARK: - Helpers

    private func currentFFmpeg() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return ffmpeg
    }

    private func cacheKey(_ track: Track) -> String {
        TranscodeCache.key(
            url: track.url,
            fileSize: track.fileSize,
            modifiedAt: track.modifiedAt
        )
    }
}
