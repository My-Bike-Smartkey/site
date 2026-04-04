# Dat Bike Smartkey — iOS Native App

Ứng dụng iOS native thay thế smartkey chính thức cho xe **Dat Bike Quantum S3**, được xây dựng hoàn toàn từ kết quả reverse-engineering giao thức BLE độc quyền của hãng.

---

## Tóm tắt dự án

| Hạng mục | Chi tiết |
|---|---|
| **Nền tảng** | iOS 16+, Swift 5.9, SwiftUI |
| **BLE Stack** | CoreBluetooth (Foreground-Only), AccessorySetupKit |
| **Mã hóa** | SHA-256 (CryptoKit), PIN challenge-response |
| **Mô hình** | Native GATT client — reverse-engineered từ `btsnoop_hci.log` |
| **Xe hỗ trợ** | Dat Bike Quantum S3 (firmware 1.10.1) |

---

## Cấu trúc Kiến trúc Mới (Foreground-Only & ASK)

Ứng dụng đã được tái cấu trúc hoàn toàn để loại bỏ các API chạy ngầm lỗi thời (State Restoration) nhằm trị dứt điểm tình trạng deadlock khóa chết Bluetooth. Thay vào đó, app hoạt động theo mô hình **Foreground-Only**:
- Chủ động ngắt kết nối (`disconnect()`) khi người dùng ẩn ứng dụng (Background).
- Sử dụng **AccessorySetupKit (ASK)** của iOS để quản lý kết nối an toàn, thay thế cho cơ chế Background Scanning không đáng tin cậy.
- Sử dụng `UIBackgroundTask` để bọc các tác vụ phục hồi lỗi (ví dụ: MIC failure) phòng khi app bị đóng giữa chừng.

---

## Giao thức & Các Command (Đã Hiệu Đính)

Qua quá trình debug và test thực tế, các byte thao tác của xe đã được ánh xạ chuẩn xác:

| Tên | UUID (short) | Giá trị ghi (HEX) | Chức năng (Đã kiểm chứng) |
|---|---|---|---|
| `unlockCmd` | 7F13FE5C | `0x31` | **Bật xe (Power ON)** |
| `unlockCmd` | 7F13FE5C | `0x30` | **Tắt xe (Power OFF)** |
| `smartkeyEcho` | EEC8FD7F | `0x31` | **Khoá chống trộm (Lock/Arm)** |
| `findBike` | 350D9A82 | `0x31` / `0x30` | Bật / Tắt còi tìm xe |

> **Lưu ý Lịch sử lỗi:** Ở các phiên bản trước, hàm `unlock()` và `turnOff()` đã bị code đảo ngược logic (gọi hàm Mở nhưng lại gửi lệnh Tắt). Bản này đã **đính chính trọn vẹn danh pháp hàm**, đảm bảo tính trung thực với phần cứng.

---

## Tính năng đã hoàn thiện

| Tính năng | Trạng thái |
|---|---|
| AccessorySetupKit Integration | ✅ |
| Pairing lần đầu (NFC) | ✅ |
| Reconnect an toàn mượt mà | ✅ |
| Auto-Unlock khi mở App | ✅ |
| Khoá / Mở khoá xe | ✅ |
| Bật / Tắt xe | ✅ |
| Chế độ chống trộm (Arm) | ✅ |
| Tìm xe (còi) | ✅ |
| Đọc trạng thái telemetry (Odo, % pin) | ✅ |
| Đọc trạng thái khóa real-time | ✅ |
| Debug log (TX/RX GATT) | ✅ |

---

## Giao thức xác thực (Authentication Protocol)

Xe Dat Bike dùng **2 luồng khác nhau** phụ thuộc vào việc thiết bị đã từng pair chưa:

### Luồng 1: Pairing lần đầu (Plaintext PIN + NFC)
App → Write PIN → Xe xử lý. Nếu đúng, màn hình SMP tự động trigger NFC pairing. Quẹt thẻ để xác nhận Bonding.

### Luồng 2: Reconnect (SHA-256 Challenge-Response)
Khi thiết bị đã pair:
1. Đọc `authChallenge (0x000C)` để lấy nonce (4 byte).
2. Tính chuỗi hash = `SHA256( (nonce >> 1) + PIN )`.
3. Trả kết quả hash ngược lại `0x000C`.
4. Ghi `sessionToken` (random) ➔ `proximityToken` (UUID).
5. Cuối cùng bật `Notify` trên `serviceChanged (0x0008)` ➔ Xe xác nhận hiện icon Bluetooth.

---

## Lưu ý quan trọng khi phát triển

1. **Không dùng CoreBluetooth State Restoration**: Quên key `CBCentralManagerOptionRestoreIdentifierKey` đi, iOS 18 không còn mặn mà với nó. Khi app ẩn, chúng ta sẽ ngắt. Khi mở lên, `centralManager` sẽ tự quét lại.
2. **PIN mặc định**: (`BLEProtocol.authPIN`) phải khớp với PIN đã đăng ký khi NFC pairing. PIN sai → SHA sai → xe xóa bonding tức thì.
3. **Tuân thủ đúng btsnoop flow**: CCCD write (setNotifyValue) cho `serviceChanged` LUÔN PHẢI gọi cuối cùng sau tất cả các bước xác thực Session và Proximity token.

---

## Hạn chế đã biết

- **Xóa bonding từ iOS:** iOS không cho phép app xóa LTK programmatically. Khi xe xóa bonding do dính MIC Failure, phải vào **Settings → Bluetooth → Quên thiết bị** rồi pair lại bằng NFC thủ công.
- **PIN cứng:** PIN hiện tại cần khớp với lần pair đầu. Muốn đổi PIN phải can thiệp firmware code.
