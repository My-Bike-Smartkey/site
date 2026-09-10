# Changelog

Định dạng [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning [SemVer](https://semver.org/).
Mỗi mục ghi **bằng chứng kèm theo** — những gì chưa nghiệm thu trên xe thật được ghi rõ là "field-test pending".

## [2.1.0] — 2026-09-10 (unreleased, build 6)

### Added — FG-OPEN GUARANTEE: "mở app đang gần xe → kết nối ngay"

Yêu cầu bắt buộc từ chủ dự án. Ba lỗ hổng đã bịt:

- **Không cancel link đang thương lượng**: cả 2 nhánh foreground (scanning-aggressive + connecting-timeout) trước đây cancel peripheral `.connecting` — tự tay giết link hệ thống đang hoàn tất (pending connect sau force-quit/suspend) → nguyên nhân "mở app lúc được lúc không". Giờ chỉ cancel peripheral thực sự stale (`.disconnected`/`.disconnecting`); link `.connecting` được giữ, phantom watchdog tiếp tục canh.
- **`[FG_OPEN_AUTH]` — foreground bỏ qua chờ ngưỡng RSSI**: trước đây mở app khi `connectOnlyWhenNear` bật → standby chờ RSSI ≥ ngưỡng (2 mẫu + hysteresis) → nếu sóng dao động quanh ngưỡng thì đứng cạnh xe vẫn không auth. Giờ foreground = ý định dùng xe → auth ngay sau GATT; gate RSSI chỉ còn cho background. Chế độ manualOnly không bị ảnh hưởng.
- **`[FG_HEAL]` — watchdog tự chữa 10s**: mở app (cold + warm) mà sau 10s chưa đến trạng thái ổn → tự `forceReconnect` sạch (đường user vẫn phải bấm tay trước đây). Tối đa 2 lượt/phiên foreground, hết quota dừng để tránh loop.

Ranh giới vật lý (không thể app sửa được): xe tắt/ngủ sâu không quảng bá BLE thì không kết nối được — khi đó app fail-fast với thông báo "Không tìm thấy xe, kiểm tra xe đã bật chưa".

### Changed — UI màn hình kết nối

- **Timeline dọc thay pill ngang**: 4 node (Tìm xe → Kết nối → Xác thực → Sẵn sàng) với connector; node xong = check xanh, node đang chạy = pulse màu trạng thái + icon, node chờ = mờ.
- **Giảm text**: bỏ dòng hint dưới pipeline, bỏ đồng hồ "đã chờ Xs", bỏ caption "Bấm nếu chờ quá lâu", "App sẽ không tự kết nối...", rút gọn caption chế độ gần xe. Hint bây giờ chỉ tồn tại 1 dòng duy nhất trên node active.
- Giữ nguyên mọi hành vi/nút: forceReconnect, "Ở gần xe, chưa dùng", pending-connect label "Chờ xe".

### Added — Log debug giá trị cao ([CYCLE]/[CKPT])

- **[CYCLE] tổng kết mỗi chu kỳ tiếp cận xe**: outcome (success/fail/disconnected), via (auth/session-restore), breakdown millisecond `req→dc / dc→gatt / gatt→now / total`, stage + code lỗi khi fail, `linkDur` khi mất link.
- **[CKPT] checkpoint grep-được**: `request` (kèm source/intent/bg), `did-connect`, `gatt-ready`, `rssi-cross` (chỉ khi EMA đổi band so với ngưỡng auto-bật — không flood), `auto-cmd` (toàn bộ input của gate auto-bật).
- `BLEConnectionContext.createdAt` — mốc t=0 cho trace elapsed `sid=xxx t=+…ms`.
- Định dạng + cách phân tích ghi vào `docs/TEST_AND_DEPLOYMENT_GUIDE.md`.

### Version

- `MARKETING_VERSION` 2.0.0 → 2.1.0, `CURRENT_PROJECT_VERSION` 4 → 5. Bản 2.0.0 được công nhận đã ổn định theo đánh giá của chủ dự án sau đợt remediation (nghiệm thu trên xe vẫn theo ma trận trong `docs/TEST_AND_DEPLOYMENT_GUIDE.md`).

## [2.0.0] — 2026-09-10 (released, build 3–4)

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
