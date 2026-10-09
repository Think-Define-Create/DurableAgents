import DurableCore
import DurableStore
import Foundation
import Testing

@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func renewalKeepsALongRunPastTheOriginalTTL(_ kind: StoreKind) async throws {
    let harness = try makeHarness(kind)
    let engine = try await harness.engine(leaseTTL: .seconds(30))
    harness.clock.advance(by: 20)
    await engine.renewNow()
    harness.clock.advance(by: 20)
    do {
        _ = try await harness.engine(leaseTTL: .seconds(30))
        Issue.record("a renewed lease should still be held")
    } catch let error as DurableError {
        guard case .leaseHeld = error else {
            Issue.record("unexpected \(error)")
            return
        }
    }
    #expect(await engine.fencedOut == false)
    await engine.close()
}

@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func stolenLeaseStopsTheEngine(_ kind: StoreKind) async throws {
    let harness = try makeHarness(kind)
    let engine = try await harness.engine(leaseTTL: .seconds(30))
    harness.clock.advance(by: 31)
    let thief = try await harness.engine(leaseTTL: .seconds(30))
    await engine.renewNow()
    #expect(await engine.fencedOut)
    do {
        _ = try await engine.submitTurn("hi", requestID: "req-after-loss")
        Issue.record("a fenced engine should not accept work")
    } catch let error as DurableError {
        guard case .poisoned = error else {
            Issue.record("unexpected \(error)")
            return
        }
    }
    await thief.close()
}

@Test(arguments: [StoreKind.memory, StoreKind.sqlite])
func deadProcessLosesTheLeaseWithoutARenewal(_ kind: StoreKind) async throws {
    let harness = try makeHarness(kind)
    let engine = try await harness.engine(leaseTTL: .seconds(3600))
    harness.liveness.markDead(ProcessInfo.processInfo.processIdentifier)
    let replacement = try await harness.engine(leaseTTL: .seconds(30))
    await engine.renewNow()
    #expect(await engine.fencedOut)
    await replacement.close()
}

@Test func closeReleasesTheLeaseAndStopsRenewal() async throws {
    let harness = try makeHarness(.memory)
    let engine = try await harness.engine(leaseTTL: .seconds(30))
    await engine.close()
    await engine.renewNow()
    #expect(await engine.fencedOut == false)
    let next = try await harness.engine(leaseTTL: .seconds(30))
    #expect(await next.fencedOut == false)
    await next.close()
}
