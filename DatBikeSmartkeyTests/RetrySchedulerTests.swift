import XCTest
@testable import D_SmartKey

/// Cờ test an toàn main-thread: body retry chạy trên MainActor (qua MainActor.run),
/// test chỉ ĐỌC sau khi chờ — không cần đồng bộ hoá nặng.
final class RetryFlag {
    private(set) var isSet = false
    func set() { isSet = true }
}

/// §3.7 (P2) — RetryScheduler: chủ duy nhất của retry;
/// token chết khi đổi session; nhóm đảm bảo 1 chủ retry; cancelAll khi pause.
final class RetrySchedulerTests: XCTestCase {

    func test_scheduledRetry_firesAfterDelay() async throws {
        let scheduler = RetryScheduler()
        let fired = RetryFlag()
        await scheduler.schedule(label: "test", group: "g1", delay: 0.1) { fired.set() }
        try await assertEventually { fired.isSet }
    }

    func test_bindNewSession_killsPendingRetries() async throws {
        let scheduler = RetryScheduler()
        await scheduler.bind(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, reason: "test-a")
        let fired = RetryFlag()
        await scheduler.schedule(label: "mic-retry", group: "mic-retry", delay: 0.15) { fired.set() }
        // Đổi session TRƯỚC khi retry fire
        await scheduler.bind(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, reason: "test-b")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(fired.isSet, "Token của session cũ phải chết — body không được chạy")
        let pending = await scheduler.pendingCount()
        XCTAssertEqual(pending, 0, "Entry cũ phải bị dọn")
    }

    func test_sameGroup_newSchedule_replacesOld() async throws {
        let scheduler = RetryScheduler()
        let first = RetryFlag()
        let second = RetryFlag()
        await scheduler.schedule(label: "retry-1", group: "mic", delay: 0.2) { first.set() }
        await scheduler.schedule(label: "retry-2", group: "mic", delay: 0.05) { second.set() }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(first.isSet, "Entry cũ cùng nhóm phải bị thay thế (1 chủ retry/nhóm)")
        XCTAssertTrue(second.isSet)
    }

    func test_cancelAll_preventsFire() async throws {
        let scheduler = RetryScheduler()
        let fired = RetryFlag()
        await scheduler.schedule(label: "r", group: "g", delay: 0.15) { fired.set() }
        await scheduler.cancelAll(reason: "pause test")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(fired.isSet, "cancelAll (pause) phải ngăn body chạy")
    }

    // MARK: - Helpers

    private func assertEventually(_ condition: @escaping () -> Bool,
                                  timeout: TimeInterval = 2,
                                  message: String = "Điều kiện không đạt trong timeout") async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail(message)
    }
}
