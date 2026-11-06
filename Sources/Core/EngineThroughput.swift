import Foundation

// EngineModels.swift is pinned byte-for-byte by Scripts/verify-version.py
// because the Windows release was verified against it. Its original
// EngineProgressWindow is kept there unchanged but no longer used; the engine
// measures progress with EngineThroughput instead.

/// Estimates transfer throughput from the JSON counters rclone already emits.
///
/// The displayed speed is the amount of data processed during roughly the last
/// ten seconds. rclone adds bytes as they stream through it, but a server-side
/// or native copy adds a whole file only when that file finishes. While such a
/// file is still running, the counters stay flat even though data is moving, so
/// a plain moving average would sink to zero and then spike. Those intervals are
/// reported as `speedState = "hidden"` with no speed or ETA instead of a fake
/// slowdown. No file reads, scans, subprocesses or timers are added.
struct EngineThroughput {
    private struct Sample { let time: Double; let bytes: Double; let files: Double }
    /// The speed users read: data processed over about the last ten seconds.
    static let speedWindow: Double = 10
    /// The remaining-time estimate uses a calmer half-minute view.
    static let etaWindow: Double = 30
    /// History needed to measure progress that arrives in large steps.
    static let historyWindow: Double = 60
    /// A window should contain at least this many counter increases.
    static let minimumSteps = 3
    /// A running file that reports no bytes for this long hides its progress.
    static let hiddenAfter: Double = 5

    private var samples: [Sample] = []
    private var startedAt: TimeInterval = 0
    private var lastObservedAt: TimeInterval = 0
    private var lastElapsed: Double = 0
    private var lastRawElapsed: Double?
    private var lastBytes: Double = 0
    private var lastFiles: Double = 0
    private var lastByteIncreaseAt: Double = 0
    private var silentSince: [String: Double] = [:]
    var sampleCount: Int { samples.count }

    mutating func start(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        startedAt = uptime; lastObservedAt = uptime; lastElapsed = 0; lastRawElapsed = nil; lastBytes = 0; lastFiles = 0
        lastByteIncreaseAt = 0; silentSince = [:]
        samples = [Sample(time: 0, bytes: 0, files: 0)]
    }

    mutating func update(_ raw: [String: Any], previous: [String: Any], at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [String: Any] {
        if samples.isEmpty { start(at: uptime) }
        var result = EngineStatistics.parse(raw, previous: previous)
        let bytes = EngineJSON.number(result["bytes"]), files = EngineJSON.number(result["transfers"])
        let rawElapsed = EngineJSON.seconds(raw["elapsedTime"]) as? Double
        let clockReset = rawElapsed != nil && lastRawElapsed != nil && rawElapsed! < lastRawElapsed!
        let elapsed = rawElapsed.map { clockReset ? $0 : max(lastElapsed, $0) } ?? (lastElapsed + max(0, uptime - lastObservedAt))
        result["elapsedTime"] = elapsed
        let reset = bytes < lastBytes || files < lastFiles || clockReset
        let current = Sample(time: elapsed, bytes: bytes, files: files)
        if reset {
            // A retry can reset counters. Do not turn the discontinuity into a
            // negative rate or assume the replacement counter arrived instantly.
            samples = [current]; lastByteIncreaseAt = elapsed; silentSince = [:]
        } else if elapsed >= (samples.last?.time ?? 0) {
            if bytes > lastBytes { lastByteIncreaseAt = elapsed }
            // Keep one sample per second; rclone may log more often near the end.
            if samples.count > 1, floor(samples.last!.time) == floor(elapsed) { samples[samples.count - 1] = current }
            else if elapsed > (samples.last?.time ?? 0) { samples.append(current) }
            else if samples.count > 1 { samples[samples.count - 1] = current }
            // Retain one sample older than the history window as its left edge.
            let cutoff = max(0, elapsed - Self.historyWindow)
            while samples.count > 2 && samples[1].time <= cutoff { samples.removeFirst() }
            if samples.count > 64 { samples.removeFirst(samples.count - 64) }
        }
        lastElapsed = elapsed; lastRawElapsed = rawElapsed ?? lastRawElapsed; lastBytes = bytes; lastFiles = files; lastObservedAt = uptime

        // Files that are running but have reported no bytes at all.
        var silent: [String: Double] = [:]
        for file in result["transferring"] as? [[String: Any]] ?? [] where EngineJSON.number(file["size"]) > 0 && EngineJSON.number(file["bytes"]) == 0 {
            let name = file["name"] as? String ?? ""
            silent[name] = silentSince[name] ?? elapsed
        }
        silentSince = silent
        let hidden = elapsed - lastByteIncreaseAt >= Self.hiddenAfter && silent.values.contains { elapsed - $0 >= Self.hiddenAfter }

        let display = rate(\.bytes, window: Self.speedWindow, now: current)
        let calm = rate(\.bytes, window: Self.etaWindow, now: current)
        let fileRate = rate(\.files, window: Self.etaWindow, now: current).value
        let speed = hidden ? 0 : display.value
        result["speed"] = speed; result["filesPerSecond"] = fileRate
        result["speedKind"] = "rolling"; result["speedWindowSeconds"] = display.span
        result["speedState"] = hidden ? "hidden" : display.span > 0 ? "live" : "measuring"
        let average = elapsed > 0 ? bytes / elapsed : 0
        result["averageSpeed"] = average.isFinite ? average : 0
        result["eta"] = NSNull(); result["etaSource"] = NSNull()
        let remainingBytes = max(0, EngineJSON.number(result["totalBytes"]) - bytes)
        let remainingFiles = max(0, EngineJSON.number(result["totalTransfers"]) - files)
        if hidden {
            // Unknown progress cannot produce a trustworthy countdown.
        } else if remainingBytes > 0 && speed > 0 && calm.value > 0 {
            let eta = remainingBytes / calm.value
            if eta.isFinite { result["eta"] = eta; result["etaSource"] = "bytes" }
        } else if remainingBytes == 0 && remainingFiles > 0 && fileRate > 0 {
            let eta = remainingFiles / fileRate
            if eta.isFinite { result["eta"] = eta; result["etaSource"] = "files" }
        }
        return result
    }

    /// Rate of one counter over a trailing window. Chunked uploads and
    /// server-side completions raise the counter in bursts several seconds
    /// apart; a fixed ten-second window would then swing between zero and
    /// double the true rate. When the window holds fewer than three increases
    /// and the counter is still rising at its usual pace, the window instead
    /// starts at an earlier increase so that it spans three whole bursts. Once
    /// the counter has been flat for more than twice its usual interval the
    /// fixed window applies again, so a real stall still falls to zero.
    private func rate(_ value: KeyPath<Sample, Double>, window: Double, now: Sample) -> (value: Double, span: Double) {
        guard let first = samples.first, now.time > first.time else { return (0, 0) }
        var increases: [Int] = []
        for index in samples.indices.dropFirst() where samples[index][keyPath: value] > samples[index - 1][keyPath: value] { increases.append(index) }
        var startTime = max(first.time, now.time - window)
        var startValue = valueAt(startTime, value)
        let inWindow = increases.reduce(0) { $0 + (samples[$1].time > startTime ? 1 : 0) }
        if inWindow < Self.minimumSteps {
            let times = increases.suffix(Self.minimumSteps + 1).map { samples[$0].time }
            let gaps = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
            let usual = gaps.isEmpty ? nil : gaps[gaps.count / 2]
            let quiet = now.time - (times.last ?? first.time)
            if usual == nil || quiet <= 2 * usual! {
                if increases.count > Self.minimumSteps {
                    let anchor = samples[increases[increases.count - Self.minimumSteps - 1]]
                    if anchor.time < startTime { startTime = anchor.time; startValue = anchor[keyPath: value] }
                } else { startTime = first.time; startValue = first[keyPath: value] }
            }
        }
        let span = now.time - startTime
        guard span > 0 else { return (0, 0) }
        let quotient = max(0, now[keyPath: value] - startValue) / span
        return (quotient.isFinite ? quotient : 0, span)
    }

    private func valueAt(_ time: Double, _ value: KeyPath<Sample, Double>) -> Double {
        guard let after = samples.firstIndex(where: { $0.time >= time }) else { return samples.last?[keyPath: value] ?? 0 }
        guard after > 0 else { return samples[after][keyPath: value] }
        let a = samples[after - 1], b = samples[after]
        guard b.time > a.time else { return b[keyPath: value] }
        return a[keyPath: value] + (b[keyPath: value] - a[keyPath: value]) * (time - a.time) / (b.time - a.time)
    }

    func finish(_ value: [String: Any], completed: Bool, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [String: Any] {
        var result = value
        if EngineJSON.number(result["elapsedTime"]) == 0, !samples.isEmpty {
            result["elapsedTime"] = max(0, uptime - startedAt)
        }
        var finished = EngineStatistics.finished(result, completed: completed)
        finished["speedState"] = "live"
        return finished
    }
}
