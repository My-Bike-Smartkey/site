# Changelog

Định dạng [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning [SemVer](https://semver.org/).
Mỗi mục ghi **bằng chứng kèm theo** — những gì chưa nghiệm thu trên xe thật được ghi rõ là "field-test pending".

## [2.0.0] — 2026 (unreleased, dev build 4)

Bản viết lại nền tảng ổn định: concurrency, background/reconnect, proximity gating, và docs trung thực. Nguyên tắc xuyên suốt: không tuyên bố gì không đo được.

### Fixed — Concurrency & state

- `BLEStateMachine`: state được bảo vệ bằng lock; publication enqueue theo thứ tự transition trên queue riêng, gửi ngoài lock. Chặn transition `.active → .connecting` và duplicate. Unit test: state đồng bộ, thứ tự publication, concurrent 1000 iterations.
- `BLEConnectionContext`: registry characteristic bảo vệ bằng NSLock.
- `NotificationManager`: debounce bảo vệ bằng lock (loại race khi flood event).
- Callback `didUpdateValueFor`/`didReadRSSI`: từ chối peripheral/context cũ (stale-fencing); error response không cập nhật lock state; re-check `activeContext === ctx` trên main trước khi áp dụng.

### Fixed — Background & reconnect

- **Restore path**: `willRestoreState` giờ **adopt** cả peripheral `.connecting` lẫn `.connected` — không còn cancel pending connect của hệ thống (cơ chế đánh thức app khi xe vào sóng sau khi iOS jettison app). Nhánh `.disconnected` không còn ép `forceFullScan`; `connect()` đăng ký lại pending connect chuẩn. `centralManagerDidUpdateState(.poweredOn)` giữ nguyên context `.connecting`.
- Background task: main-queue-owned lease ID cho `beginBackgroundTask`; expiration handler so sánh lease trước khi dừng. **Bỏ** timer cắt 20 giây tự chế (không có căn cứ iOS cấp đúng 20–30s).
- Standby RSSI yếu: bỏ backoff timer trong app (timer không chạy khi suspend); gọi `central.connect` ngay sau cancel — reconnect nền do CoreBluetooth quản lý.
- Trùng lệnh connect (ASK duplicate UUID): giữ watchdog cũ, không reset.
- **Bỏ TTL 60 giây** sau BT power-off (không có bằng chứng về cache mã hóa iOS).

### Fixed — Proximity & auto power-ON

- `ProximitySampleWindow` (mới): EMA gắn sessionID, tối thiểu 2 mẫu, tuổi tối đa 3s, khoảng hợp lệ −127…−1; reset khi đổi phiên.
- `didReadRSSI` là nguồn EMA duy nhất — gỡ subscription publisher khởi tạo 0 của polling engine (double-smoothing).
- Auto power-ON: gated trên `.active` + không manual-only + mẫu tươi + threshold riêng (`autoTurnOnThreshold` ≠ `rssiThreshold`); reservation UUID chống chồng lệnh; **một lần thử mỗi phiên**; thông báo thành công chỉ khi dispatcher confirm `unlocked`; lỗi có log `[AUTO_TURN_ON]`, không thông báo "đã bật" khi thất bại.
- Polling telemetry: `onPeriodicTelemetryPoll` → `queryTelemetry()` mỗi 10s, không tạo chồng tác vụ.

### Docs — honesty rewrite

- `README.md` viết lại theo chuẩn opensource: trạng thái tính năng theo bằng chứng, giới hạn đã biết (force-quit, MIC, pending connect không phải proximity sensor).
- `docs/ARCHITECTURE_BLE_AND_ASK.md`: mô tả đúng code hiện tại + §7 "Hạng mục chưa nghiệm thu".
- `docs/TEST_AND_DEPLOYMENT_GUIDE.md`: ma trận nghiệm thu 10 kịch bản TN, protocol đo 20 lượt tiếp cận, nguyên tắc pass/skip/fail.
- Mới: `LICENSE` (MIT), `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, `CHANGELOG.md`, `docs/PROTOCOL.md`.

### Tests

- Suite: **40 tests, 10 skipped (backlog cần thiết bị thật), 0 failures** trên iPhone 16 Pro simulator OS 18.0.
- Ghi nhận trung thực: skip không tính là pass; simulator không kiểm chứng reconnect nền.

### Open items (chưa nghiệm thu — xem ARCHITECTURE §7)

- Single-executor ownership toàn core lifecycle; generation fencing mọi delayed callback.
- Reconnect không ping-pong; recovery không phụ thuộc timer nền.
- Command retry policy tại dispatcher; no-PIN recovery arbitration.
- Đo trên TN: 20 lượt tiếp cận theo ma trận — quyết định kết luận cuối cho triệu chứng "lại gần xe lúc được lúc không".

## [1.x] — Historical

Các bản trước (v3.x/v4.5 theo đánh số cũ của README) gồm: reverse-engineer giao thức, pairing NFC + PIN, SHA-256 reconnect, telemetry, dashboard. Đánh số version cũ trong git log không theo SemVer — xem `git log` cho chi tiết.
