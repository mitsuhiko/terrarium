import UIKit
import os

// What users feel as "it locked up" or "the editor is gone", noticed as it
// happens: main-thread hangs and web views that are not where their place on
// screen is. Logged under the "Diagnostics" category (`log stream --predicate
// 'subsystem == "eu.ronacher.Terrarium"'`); the self-test and the UI stress
// runs (app/uitests) read them.

enum Diagnostics {
    static let log = Logger(subsystem: "eu.ronacher.Terrarium", category: "Diagnostics")

    @MainActor static func start() {
        HangWatchdog.shared.start()
        // Cheap (a few web views); repairs what a missed layout pass left behind.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { WebViewSlot.audit() }
        }
    }
}

/// Measures how long the main thread takes to answer while the app is active.
/// Answers later than `threshold` are hangs: logged, and kept for the self-test.
final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()
    let threshold: TimeInterval = 0.25

    private let lock = NSLock()
    private var started = false
    /// Bumped when the app goes inactive or comes back: a wait across it is not a hang.
    private var generation = 0
    private var active = true
    private var hangs: [(at: Date, ms: Int)] = []

    @MainActor func start() {
        let first = lock.withLock { () -> Bool in
            defer { started = true }
            return !started
        }
        guard first else { return }
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [self] _ in
            lock.withLock { generation += 1; active = false }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [self] _ in
            lock.withLock { generation += 1; active = true }
        }
        let thread = Thread { [self] in run() }
        thread.name = "HangWatchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Hangs so far (milliseconds), and forgets them.
    func take() -> [Int] {
        lock.withLock {
            defer { hangs.removeAll() }
            return hangs.map(\.ms)
        }
    }

    private func run() {
        while true {
            Thread.sleep(forTimeInterval: 0.1)
            let (gen, isActive) = lock.withLock { (generation, active) }
            guard isActive else { continue }
            let sent = Date()
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { answered.signal() }
            guard answered.wait(timeout: .now() + threshold) == .timedOut else { continue }
            answered.wait()
            let ms = Int(Date().timeIntervalSince(sent) * 1000)
            let counted = lock.withLock { () -> Bool in
                guard generation == gen else { return false }
                hangs.append((sent, ms))
                if hangs.count > 200 { hangs.removeFirst() }
                return true
            }
            if counted { Diagnostics.log.error("main thread hang: \(ms, privacy: .public) ms") }
        }
    }
}
