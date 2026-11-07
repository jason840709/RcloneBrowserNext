import Foundation

// EngineModels.swift is pinned byte-for-byte by Scripts/verify-version.py
// because the Windows release was verified against it. Its original
// EngineProgressWindow is kept there unchanged but no longer used; the engine
// measures progress with EngineThroughput instead.

/// Estimates transfer throughput from the JSON counters rclone already emits.
///
/// The displayed speed is the amount of data processed during roughly the last
/// ten seconds of transfer time. Only time with at least one file transferring
/// counts: rclone reports that clock as `transferTime` (the union of all
/// transfer intervals), so listing, comparing and creating folders neither add
/// bytes nor dilute the rate. Files that need no update never add bytes; rclone
/// counts only data it actually reads for a transfer. While nothing transfers
/// the state is `checking` (rclone is comparing) or `idle`; the transfer clock
/// stands still then, so the speed keeps the last measured transfer rate.
/// Older rclone versions without `transferTime` fall back to elapsed time.
///
/// rclone adds bytes as they stream through it, but a server-side
/// or native copy adds a whole file only when that file finishes. While such a
/// file is still running, the counters stay flat even though data is moving.
/// Cloud uploads of many small files look the same: each file waits for the
/// service to accept it, often for half a minute. Those intervals are reported
/// as `speedState = "hidden"`, and the speed and remaining time use the calmer
/// one-minute rate so the reading neither vanishes nor drops at once to zero.
/// No file reads, scans, subprocesses or timers are added.
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
    /// Seconds during which at least one file was transferring.
    private var activeTime: Double = 0
    private var lastRawActive: Double?
    private var sawTransferClock = false
    var sampleCount: Int { samples.count }

    mutating func start(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        startedAt = uptime; lastObservedAt = uptime; lastElapsed = 0; lastRawElapsed = nil; lastBytes = 0; lastFiles = 0
        lastByteIncreaseAt = 0; silentSince = [:]
        activeTime = 0; lastRawActive = nil; sawTransferClock = false
        samples = [Sample(time: 0, bytes: 0, files: 0)]
    }

    mutating func update(_ raw: [String: Any], previous: [String: Any], at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [String: Any] {
        if samples.isEmpty { start(at: uptime) }
        var result = EngineStatistics.parse(raw, previous: previous)
        // rclone marks errors it will retry (the whole run is repeated up to
        // --retries times). The interface shows those as temporary.
        if let retry = raw["retryError"] as? Bool { result["retryError"] = retry }
        if let fatal = raw["fatalError"] as? Bool { result["fatalError"] = fatal }
        let bytes = EngineJSON.number(result["bytes"]), files = EngineJSON.number(result["transfers"])
        let rawElapsed = EngineJSON.seconds(raw["elapsedTime"]) as? Double
        let clockReset = rawElapsed != nil && lastRawElapsed != nil && rawElapsed! < lastRawElapsed!
        let elapsed = rawElapsed.map { clockReset ? $0 : max(lastElapsed, $0) } ?? (lastElapsed + max(0, uptime - lastObservedAt))
        result["elapsedTime"] = elapsed
        // Advance the transfer clock. rclone's own clock is preferred; it
        // stands still while rclone only lists, compares or makes folders.
        let rawActive = EngineJSON.seconds(raw["transferTime"]) as? Double
        let activeReset = rawActive != nil && lastRawActive != nil && rawActive! < lastRawActive!
        let activeStep: Double
        if let active = rawActive {
            sawTransferClock = true
            activeStep = activeReset ? active : max(0, active - (lastRawActive ?? 0))
        } else {
            activeStep = clockReset ? 0 : max(0, elapsed - lastElapsed)
        }
        activeTime += activeStep
        let transferring = bytes > lastBytes || activeStep > 0
        let reset = bytes < lastBytes || files < lastFiles || clockReset || activeReset
        let current = Sample(time: activeTime, bytes: bytes, files: files)
        if reset {
            // A retry can reset counters. Do not turn the discontinuity into a
            // negative rate or assume the replacement counter arrived instantly.
            samples = [current]; lastByteIncreaseAt = elapsed; silentSince = [:]
        } else {
            if bytes > lastBytes { lastByteIncreaseAt = elapsed }
            // Keep one sample per second; rclone may log more often near the end.
            if samples.count > 1, floor(samples.last!.time) == floor(activeTime) { samples[samples.count - 1] = current }
            else if activeTime > (samples.last?.time ?? 0) { samples.append(current) }
            else if samples.count > 1 { samples[samples.count - 1] = current }
            // Retain one sample older than the history window as its left edge.
            let cutoff = max(0, activeTime - Self.historyWindow)
            while samples.count > 2 && samples[1].time <= cutoff { samples.removeFirst() }
            if samples.count > 64 { samples.removeFirst(samples.count - 64) }
        }
        lastElapsed = elapsed; lastRawElapsed = rawElapsed ?? lastRawElapsed; lastRawActive = rawActive ?? lastRawActive; lastBytes = bytes; lastFiles = files; lastObservedAt = uptime

        // Files that are running but have reported no bytes at all.
        var silent: [String: Double] = [:]
        for file in result["transferring"] as? [[String: Any]] ?? [] where EngineJSON.number(file["size"]) > 0 && EngineJSON.number(file["bytes"]) == 0 {
            let name = file["name"] as? String ?? ""
            silent[name] = silentSince[name] ?? elapsed
        }
        silentSince = silent
        let hidden = elapsed - lastByteIncreaseAt >= Self.hiddenAfter && silent.values.contains { elapsed - $0 >= Self.hiddenAfter }

        // While counters are flat, the one-minute rate describes the job better
        // than ten seconds that may hold no update at all.
        let display = rate(\.bytes, window: hidden ? Self.historyWindow : Self.speedWindow, now: current)
        let calm = rate(\.bytes, window: hidden ? Self.historyWindow : Self.etaWindow, now: current)
        let fileRate = rate(\.files, window: Self.etaWindow, now: current).value
        // No file is moving: rclone is comparing or idle. The transfer clock
        // stands still, so `display` still holds the last transfer rate.
        let waiting = sawTransferClock && !transferring && !hidden
        let checking = !((raw["checking"] as? [Any]) ?? []).isEmpty
        let speed = display.value
        result["speed"] = speed; result["filesPerSecond"] = fileRate
        result["speedKind"] = "rolling"; result["speedWindowSeconds"] = display.span
        result["speedState"] = hidden ? "hidden" : waiting ? (checking ? "checking" : "idle") : display.span > 0 ? "live" : "measuring"
        result["transferTime"] = activeTime
        let average = activeTime > 0 ? bytes / activeTime : 0
        result["averageSpeed"] = average.isFinite ? average : 0
        result["eta"] = NSNull(); result["etaSource"] = NSNull()
        let remainingBytes = max(0, EngineJSON.number(result["totalBytes"]) - bytes)
        let remainingFiles = max(0, EngineJSON.number(result["totalTransfers"]) - files)
        if remainingBytes > 0 && calm.value > 0 {
            // While rclone compares between transfers the last transfer rate
            // still describes the remaining data best.
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
        // The overall average covers transfer time only, so a long comparison
        // phase does not make a finished job look slow.
        if sawTransferClock && activeTime > 0 {
            let average = EngineJSON.number(finished["bytes"]) / activeTime
            if average.isFinite {
                finished["speed"] = average; finished["averageSpeed"] = average
                finished["speedWindowSeconds"] = activeTime
                finished["filesPerSecond"] = EngineJSON.number(finished["transfers"]) / activeTime
            }
            finished["transferTime"] = activeTime
        }
        finished["speedState"] = "live"
        return finished
    }
}
