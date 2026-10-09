import DurableCore
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public protocol StoreClock: Sendable {
    func now() -> Date
}

public struct SystemClock: StoreClock {
    public init() {}

    public func now() -> Date { Date() }
}

/// Test and host clock. Lease expiry reads this instead of the wall clock.
public final class ManualClock: StoreClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    public init(_ instant: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.instant = instant
    }

    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    public func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        instant.addTimeInterval(interval)
    }
}

extension ManualClock: DurableClock {}

public protocol ProcessLiveness: Sendable {
    func isAlive(pid: Int32) -> Bool
}

public struct SystemProcessLiveness: ProcessLiveness {
    public init() {}

    public func isAlive(pid: Int32) -> Bool {
        if pid <= 0 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}

/// Lets tests mark a pid dead without killing this process, so a lease can be stolen in-process.
public final class ScriptedLiveness: ProcessLiveness, @unchecked Sendable {
    private let lock = NSLock()
    private var deadPIDs: Set<Int32> = []

    public init() {}

    public func isAlive(pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !deadPIDs.contains(pid)
    }

    public func markDead(_ pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        deadPIDs.insert(pid)
    }
}

enum LeaseRuling: Equatable {
    case grant(epoch: UInt64)
    case renew
    case held(Lease)
}

func ruleLease(
    existing: Lease?,
    highWater: UInt64,
    requester: UUID,
    now: Date,
    isAlive: (Int32) -> Bool
) -> LeaseRuling {
    guard let existing else {
        return .grant(epoch: highWater + 1)
    }
    if existing.owner == requester {
        return .renew
    }
    let expired = existing.expiresAt <= now
    let dead = !isAlive(existing.pid)
    if expired || dead {
        return .grant(epoch: max(highWater, existing.epoch) + 1)
    }
    return .held(existing)
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
