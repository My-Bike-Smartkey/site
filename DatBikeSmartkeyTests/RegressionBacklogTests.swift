import XCTest
@testable import D_SmartKey

/// Regression backlog của đợt audit BLE (docs/PLAN_BLE_REMEDIATION_VI.md §3).
/// Mỗi mục ghi rõ trạng thái: đã fix ở đâu / được phủ bởi unit test nào /
/// còn gì chờ kịch bản thiết bị thật.
final class RegressionBacklogTests: XCTestCase {

    // §3.1 [P0] — didConnect cùng context kẹt .scanning
    func test_didConnect_samePeripheralSession_mustEnterDiscoveringPhase() throws {
        // ✅ Hotfix đã áp trong DatBikeCore.didConnect (nhánh cùng context ép .connecting).
        // Log 13894 didConnect: 26% không được xử lý trong 120s → đã hạ bằng nhánh ép phase.
        throw XCTSkip("Còn kịch bản thiết bị thật §6.2 (1)-(2): xác minh didConnect luôn vào discovering")
    }

    // §3.2 [P2] — discovery error im lặng, watchdog bị hủy sớm
    func test_discoveryError_mustRetryThenAbortWithin30s() throws {
        // ✅ Đã áp P2: startDiscoveryWatchdog 10s + retryDiscoveryOrAbort(≤2 lần),
        //    didDiscoverServices error/empty → retry (không còn return im lặng),
        //    gate đủ 3 characteristic → cancelDiscoveryWatchdog.
        throw XCTSkip("Cần CBPeripheral mock để dựng GATT discovery — kịch bản thiết bị thật §6.2 (3)")
    }

    // §3.3 [P1] — auth bị cancel vẫn publish .active
    func test_cancelledAuthTask_mustNotPublishActiveOrNotify() throws {
        // ✅ Đã áp P1: BLEAuthenticator rethrow CancellationError + performNonCritical,
        //    executeAuthProtocol sessionGate sau mọi await.
        throw XCTSkip("Còn kịch bản thiết bị thật §6.2-7: pairing (2.5s) → forceReconnect giây 1 → không notification")
    }

    // §3.4 [P4] — Active → Nearby → Connect mất dispatcher
    func test_nearbyRoundTrip_mustKeepDispatcherAndPollingAlive() throws {
        // ✅ Đã áp P4: activateNearbyMode KHÔNG còn nil commandDispatcher/pollingEngine —
        //    services sống theo session (connection), chỉ stopPolling khi hạ mode.
        throw XCTSkip("Cần CBPeripheral mock dựng vòng nearby↔standby — xác minh thủ công §6.2 (8)")
    }

    // §3.5 [P1] — callback cũ hoàn tất operation phiên mới
    func test_stalePeripheralCallback_mustNotResumeCurrentSessionIO() throws {
        // ✅ Đã phủ bởi BLECharacteristicIOTests (cooldown + drop late response)
        //    và guard STALE_CALLBACK trong DatBikeCore delegate.
        throw XCTSkip("Chuyển sang: đã phủ unit — BLECharacteristicIOTests.test_lateResponse_dropped_doesNotCorruptNextRequest")
    }

    // §3.6 [P1] — cancelAll phá FIFO mutex khi owner đang chạy
    func test_cancelAllDuringOwnerExecution_mustNotStartNewTaskConcurrently() throws {
        // ✅ Đã phủ bởi BLETaskQueueTests.test_cancelAll_generationIsolation
        throw XCTSkip("Chuyển sang: đã phủ unit — BLETaskQueueTests.test_cancelAll_generationIsolation")
    }

    // §3.7 [P2] — retry bypass manualOnly + retry chồng chéo MIC/PhantomGuard
    func test_scheduledRetry_mustRespectManualOnlyIntent() throws {
        // ✅ Đã áp P2: RetryScheduler (actor) — 5 call site asyncAfter đã migrate,
        //    nhóm cancel chéo, session-bound token, pause/disconnect cancelAll.
        //    Đã phủ unit bởi RetrySchedulerTests (bind-đổi-session giết token, thay thế nhóm).
        throw XCTSkip("Chuyển sang: đã phủ unit — RetrySchedulerTests")
    }

    // §3.8 [P2] — stale disconnect hủy polling/auth phiên mới
    func test_staleDisconnectEvent_mustNotTearDownNewSession() throws {
        // ✅ Đã áp P2: guard ctx.peripheral !== peripheral → log STALE_DISCONNECT + return.
        throw XCTSkip("Cần 2 CBPeripheral mock — kịch bản thiết bị thật §6.2 (9)")
    }

    // §3.9 [P4] — nearby tự auth theo 1 mẫu RSSI, bỏ qua intent
    func test_nearbyMode_mustNotAutoAuthOnSingleRssiSpike() throws {
        // ✅ Đã áp P4: strongRssiConsecutiveCount ≥ 2 mới auth (standby + nearby),
        //    dải hysteresis ±5dB không đếm drain, manualOnly chặn cả 2 nhánh.
        throw XCTSkip("Cần CBPeripheral mock bơm RSSI — xác minh thủ công §6.2 (10)")
    }

    // §3.10 [P4] — relaunch/storm-restore bỏ qua ý định user
    func test_coldInitWithManualOnly_mustNotAdoptRestoredSession() throws {
        // ✅ Đã áp P4: willRestoreState guard manualOnly → cancel + .idle;
        //    connect() guard intent chặn mọi auto-connect sau cold-init.
        throw XCTSkip("Cần simulator kill/relaunch — kịch bản thiết bị thật §6.2 (11)")
    }
}
