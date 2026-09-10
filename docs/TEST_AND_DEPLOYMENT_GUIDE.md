# D-SmartKey — Kiểm thử và triển khai TN

## Trạng thái bằng chứng

Không gọi toàn bộ test được phát hiện là PASS. `RegressionBacklogTests` có 10 test skip; chúng không chứng minh kịch bản BLE đã được kiểm thử. Lấy số pass/skip/fail từ kết quả mỗi lần chạy, không dùng số đếm trong tài liệu cũ.

Test state machine hiện có kiểm tra state đồng bộ, thứ tự publication, duplicate và concurrency. Test proximity kiểm tra hai mẫu, session identity, expiry và RSSI không hợp lệ. Chưa có đầy đủ fake coordinator/transport để kiểm tra toàn bộ reconnect/auth/actuation.

## Chạy tự động

Chạy từ thư mục ios-app:

```bash
xcodebuild -project DatBikeSmartkey.xcodeproj -scheme DatBikeSmartkey \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.0' \
  -configuration Debug test
```

Ghi exit code thực, đường dẫn xcresult, số pass/skip/fail và warnings. Không dùng pipeline khiến exit code của tail/grep che lỗi xcodebuild.

## Điều kiện cài bản mới

- Hoàn tất các mục sửa đã cam kết hoặc ghi rõ phần chưa đạt, không quảng cáo là đã ổn định toàn diện.
- Tests và generic build thành công trên cùng phiên bản nguồn.
- Không ghi đè dữ liệu/UUID/PIN hoặc xóa bonding để thử nếu chưa có chủ ý người dùng.
- Không tự thử lệnh bật/tắt/arm trên xe thật chỉ để kiểm tra phần mềm.

```bash
set -e
xcodebuild -project DatBikeSmartkey.xcodeproj -scheme DatBikeSmartkey \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/tn CODE_SIGN_STYLE=Automatic build
xcrun devicectl device install app \
  --device E64F1911-723A-5428-8C71-BC19218C174E \
  'build/tn/Build/Products/Debug-iphoneos/D-SmartKey.app'
xcrun devicectl device process launch \
  --device E64F1911-723A-5428-8C71-BC19218C174E app.mybike.smartkey
```

Install và launch là hai kết quả riêng. Nếu launch lỗi, đọc lỗi thực; không mặc định là màn hình khóa. Không khẳng định đã cài khi chỉ nhìn thấy build thành công.

## Ma trận nghiệm thu trên TN

Ghi phiên bản app/iOS/firmware, cấu hình auto, ngưỡng RSSI, intent, thời điểm và sessionID mỗi lượt.

0. **FG-OPEN GUARANTEE (mới, ưu tiên cao)**: mở app khi đứng gần xe (xe đang bật) → kết nối + vào Dashboard trong ≤ ~5s, KHÔNG cần bấm gì. Log mong đợi: `[CKPT request]` → `[CKPT did-connect]` (req→dc ngắn) → `[CKPT gatt-ready]` → `[FG_OPEN_AUTH] Foreground mở app → auth ngay` → `[CYCLE] outcome=success`. Nếu 10s chưa xong: `[FG_HEAL]` tự force-reconnect (tối đa 2 lần). Ranh giới: xe tắt/không quảng bá → `[CYCLE] outcome=fail stage=connect` + thông báo "Không tìm thấy xe".
1. App foreground: xa → gần, xe còn quảng bá BLE.
2. App background/màn hình khóa: xa → gần sau thời gian ngắn và dài.
3. Xe ngủ sâu: xác định còn quảng bá hay không; không quy mọi thất bại cho app.
4. Mất link trong GATT discovery/auth: không để callback phiên cũ chuyển active/báo thành công.
5. Manual-only: gần/xa, foreground, BT toggle không tự auth/bật. Mode change không gửi powerOff/arm.
6. Chủ động kết nối: thoát manual-only và không bị retry cũ phá phiên.
7. Bluetooth tắt/bật từ Settings; thử Control Center riêng, không coi hai thao tác tương đương poweredOff.
8. Khôi phục state sau hệ thống thu hồi app; user force-quit là kịch bản riêng với giới hạn hệ điều hành (iOS không relaunch app bị force-quit cho BLE — kịch bản force-quit chỉ kiểm chứng app mở lại đúng, không kiểm chứng auto-reconnect).
   - Kịch bản 8 bổ sung: mở nhiều app nặng để ép iOS jettison app trong khi có pending connect → lại gần xe → mong đợi `willRestoreState` với peripheral `.connecting`/`.connected` được adopt, tiếp theo `didConnect` → GATT → auth. Log mong đợi: `[RESTORE] Adopt peripheral restore` hoặc `Adopt peripheral restore (state=…)`, tiếp `centralManagerDidUpdateState=5` với dòng `[CB_STATE] Context đang .connecting (pending connect của iOS) → giữ nguyên, chờ didConnect` nếu relaunch xảy ra trước khi link hoàn tất.
9. ASK thêm/hủy/gỡ phụ kiện: không kẹt processing; không báo đã remove trước khi API thành công.
10. Auto-bật thất bại: không thông báo thành công; không lặp lệnh vật lý vô hạn.

Đề xuất 20 lượt tiếp cận có điều kiện xác định. Ghi từng mốc:

`intent → connect request → didConnect → GATT ready → auth → RSSI đủ điều kiện → command → xác nhận unlocked`

### Định dạng log [CYCLE] / [CKPT] (từ 2.1.0)

Mỗi lượt tiếp cận tự đo bằng các dòng log có thể grep:

- `[CKPT request]` — connect() / ASK request bắt đầu (kèm source, intent, bg/fg)
- `[CKPT did-connect] sid=xxx | req→dc=…ms` — link vật lý lên (đo độ trễ chờ xe vào sóng)
- `[CKPT gatt-ready] sid=xxx t=+…ms | dc→gatt=…ms | chars=N` — GATT discovery xong
- `[CKPT rssi-cross] dir=enter|exit | smoothed | raw | threshold | fresh` — EMA vào/ra vùng ngưỡng auto-bật (chỉ log khi đổi band, không flood)
- `[CKPT auto-cmd]` — quyết định gửi turnOnBike (kèm toàn bộ input của gate)
- `[CYCLE] sid=xxx outcome=success|fail|disconnected via=auth|session-restore | req→dc=…ms dc→gatt=…ms gatt→now=…ms total=…ms [stage=… code=… linkDur=…ms]` — tổng kết mỗi chu kỳ

Phân tích: grep `\[CYCLE\]` → bảng kết quả 20 lượt (outcome + total + stage fail nếu có); grep `\[CKPT` → tái lập timeline từng lượt theo `sid` (6 ký tự đầu sessionID). `linkDur` trên disconnected cho biết link sống bao lâu trước khi rớt — phân biệt "kết nối rồi rớt" với "không bao giờ kết nối được".

Đo tỷ lệ thành công và thời gian các bước; không hứa trước reconnect 1–2 giây. Pending connect không chứng minh khoảng cách hoặc mức pin bằng 0. Timer/polling 10 giây không được bảo đảm chạy khi iOS suspend app.

## Chưa nghiệm thu

Ownership toàn core, fencing cùng peripheral qua nhiều phiên, chống ping-pong RSSI, command arbitration và retry auto vẫn cần hoàn thiện. Hiện không có bằng chứng đủ để tuyên bố đã hết lỗi lại gần xe lúc được lúc không.
