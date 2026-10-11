import Foundation

/// Wakes the engine when a journaled timer is due, so a retry after a failed step runs on its own
/// instead of waiting for the next launch or background wake. Timers the app missed while it was
/// closed still fire from `recover` and `pumpTimers`.
public actor TimerPump: TimerScheduling {
    private weak var engine: Engine?

    public init() {}

    /// Sets the engine to wake. Create the pump first, pass it as the engine's `timers`, then attach.
    public func attach(_ engine: Engine) {
        self.engine = engine
    }

    public func schedule(name: String, fireAt: Date) async {
        Task { await self.fire(at: fireAt) }
    }

    private func fire(at date: Date) async {
        let wait = date.timeIntervalSinceNow
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait + 0.05))
        }
        _ = try? await engine?.pumpTimers()
    }
}
