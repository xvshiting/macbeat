import XCTest
@testable import MacBeatAgent

final class RecoveryStoreTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("MacBeat-recovery-test-" + UUID().uuidString) }
    func testLockDetectsOnlyTheLiveOwner() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let owner = RecoveryStore(directory: dir), other = RecoveryStore(directory: dir)
        XCTAssertFalse(other.agentActive)
        try owner.lock()
        XCTAssertTrue(other.agentActive)
        XCTAssertThrowsError(try other.lock())
        owner.unlock()
        XCTAssertFalse(other.agentActive)
        try other.lock()
    }
    func testStaleStopRequestCannotStopANewSession() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let owner = RecoveryStore(directory: dir)
        try owner.lock(); try owner.registerAgent()
        let old = try Data(contentsOf: dir.appendingPathComponent("agent-session.json"))
        try old.write(to: dir.appendingPathComponent("stop-request.json"))
        XCTAssertTrue(owner.stopRequested)
        try owner.registerAgent()
        XCTAssertFalse(owner.stopRequested)
    }
    func testCooperativeRequestWaitsForOwnerToReleaseItsLock() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let owner = RecoveryStore(directory: dir), client = RecoveryStore(directory: dir)
        try owner.lock(); try owner.registerAgent()
        let done = expectation(description: "owner observes its token")
        DispatchQueue.global().async {
            for _ in 0..<100 {
                if owner.stopRequested { owner.unlock(); done.fulfill(); return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        try client.requestStop()
        wait(for: [done], timeout: 2)
        XCTAssertFalse(client.agentActive)
    }
    func testLegacyOwnerWithoutIdentityIsNotSignalled() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let owner = RecoveryStore(directory: dir), client = RecoveryStore(directory: dir)
        try owner.lock()
        XCTAssertThrowsError(try client.requestStop())
        XCTAssertTrue(client.agentActive)
    }
}
