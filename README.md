# Dat Bike Smartkey — iOS Native App

Ứng dụng iOS native thay thế smartkey chính thức cho xe **Dat Bike Quantum S3**, được xây dựng hoàn toàn từ kết quả reverse-engineering giao thức BLE độc quyền của hãng.

---

## Tóm tắt dự án

| Hạng mục | Chi tiết |
|---|---|
| **Nền tảng** | iOS 16+, Swift 5.9, SwiftUI |
| **BLE Stack** | CoreBluetooth (native), không dùng thư viện bên thứ ba |
| **Mã hóa** | SHA-256 (CryptoKit), PIN challenge-response |
| **Mô hình** | Native GATT client — reverse-engineered từ `btsnoop_hci.log` |
| **Xe hỗ trợ** | Dat Bike Quantum S3 (firmware 1.10.1) |

---

## Quy trình kỹ thuật Reverse Engineering

### Nguồn dữ liệu
- File `btsnoop_hci.log` capture từ thiết bị Android khi dùng app chính thức
- Mã JS obfuscated (Hermes bytecode) giải nén từ APK
- Phân tích thủ công các GATT handle bằng script Python (`phantichlogs/`)

### Phát hiện giao thức BLE

Xe Dat Bike Quantum S3 dùng 4 GATT Service chính:

```
Auth Service:    10CB0217-FF02-4474-A1EF-6FD88B5BDAEA  (handle 0x00a–0x010)
Config Service:  CF6900A7-4520-4A4C-977C-82979E8BACCF  (handle 0x011–0x017)
Main Service:    D4905F67-8931-4FAA-8C61-86EC7490F3C5  (handle 0x018–0x03e)
Ext Service:     5B6D1069-A0BC-4875-BA5B-FDC94647D918  (handle 0x03f–0xffff)
Scan UUID:       0000FCF1-0000-1000-8000-00805F9B34FB   (advertisement)
```

### Các Characteristic quan trọng

| Tên | UUID (short) | Handle | Mô tả |
|---|---|---|---|
| `authChallenge` | C8EAF27B | 0x000C | Ghi PIN / SHA hash. Đọc để lấy Challenge nonce |
| `sessionToken` | 44E2BDE6 | 0x002E | Ghi random 5-digit session ID sau auth |
| `autoUnlock` | 87EFAB0D | 0x032 | Ghi UUID proximity token (auto-unlock) |
| `smartkeyEcho` | EEC8FD7F | 0x036 | Đọc/ghi trạng thái khóa (0x31=khóa, 0x30=mở) |
| `unlockCmd` | 7F13FE5C | 0x030 | Lệnh mở khóa |
| `findBike` | 350D9A82 | 0x034 | Bật/tắt còi tìm xe |
| `vehicleStatus` | 88C30D2C | 0x01A | Tên xe |
| `lockState` | 5D681587 | 0x01C | Trạng thái khóa raw |
| `serviceChanged` | 2A05 | 0x008 | BLE standard — bật CCCD sau nhận token |
| `deviceToken` | 73D50009 | 0x03A | Device ID dùng để xác minh xe |

---

## Giao thức xác thực (Authentication Protocol)

Xe Dat Bike dùng **2 luồng khác nhau** phụ thuộc vào việc thiết bị đã từng pair chưa:

### Luồng 1: Pairing lần đầu (Plaintext PIN + NFC)

Dùng khi thiết bị chưa có trong bonding table của xe:

```
App → [TX] Write PIN (plaintext)  → handle 0x000C  (lần 1)
App → [TX] Write PIN (plaintext)  → handle 0x000C  (lần 2)
App → [RX] WriteResponse (ACK)
App → [TX] Read Challenge         → handle 0x000C
App → [TX] Write PIN (plaintext)  → handle 0x000C  (lần 3)
→ iOS popup: "Ghép đôi với Dat Bike?" (SMP Pairing)
→ Xe yêu cầu quẹt thẻ NFC (NFC card authorization)
→ Người dùng quẹt thẻ → Xe xác nhận Bond
```

### Luồng 2: Reconnect (SHA-256 Challenge-Response)

Dùng khi thiết bị đã pair — xe đã có LTK (Long Term Key):

```
Step 1: App → [TX] Read authChallenge (0x000C)
        App ← [RX] challenge_bytes (4 byte nonce, e.g. "64a7ac1f")

Step 2: Tính SHA-256:
        challenge_uint32 = LittleEndian(challenge_bytes)
        shifted = challenge_uint32 >> 1
        hash_input = str(shifted) + PIN       // ví dụ: "2657043701234abcd"
        hash_hex = SHA256(hash_input).hexString  // 64 hex chars

Step 3: App → [TX] Write hash_hex → handle 0x000C
        App ← [RX] WriteResponse (ACK) = xe chấp nhận

Step 4: (không cần) — Challenge nonce tăng 1 đơn vị sau khi SHA đúng

Step 5: App → [TX] Write sessionToken (random 5 digits) → handle 0x002E

Step 6: App → [TX] Write proximityToken (UUID string) → handle 0x032

Step 7: App → [TX] setNotifyValue(true) cho serviceChanged (CCCD write 0x0009=0200)
        → Xe hiển thị icon Bluetooth trên màn hình
```

> **Quan trọng:** Thứ tự Step 5 → 6 → 7 phải đúng theo btsnoop gốc.  
> CCCD write (setNotifyValue) phải đến **SAU** khi ghi session token và proximity token.

---

## Kiến trúc ứng dụng iOS

```
DatBikeSmartkey/
├── BLE/
│   ├── BLEManager.swift       # Core BLE state machine (CBCentralManagerDelegate)
│   └── BLEConstants.swift     # Tất cả UUID, Command, Protocol constants
├── Models/
│   └── BikeState.swift        # BikeInfo, LockStatus, BLELogEntry, ConnectionState
├── ViewModels/
│   └── SmartKeyViewModel.swift # Business logic layer giữa View và BLEManager
├── Views/
│   ├── MainView.swift          # Root view: routing Splash/Dashboard
│   ├── DashboardView.swift     # Màn hình điều khiển chính
│   ├── ConnectingView.swift    # Splash màn hình kết nối/scan
│   ├── SettingsView.swift      # Cài đặt + Forget Bike flow
│   └── DebugLogView.swift      # Xem BLE TX/RX log raw
└── DatBikeSmartKeyApp.swift    # App entry point + State Restoration config
```

### ConnectionState machine

```
.idle → .scanning → .connecting → .authenticating → .ready
                                   ↓ (NFC required)
                               .pairingRequired
                                   ↓
                               .error(msg)
```

---

## Tính năng đã hoàn thiện

| Tính năng | Trạng thái |
|---|---|
| Scan tìm xe tự động | ✅ |
| Pairing lần đầu (NFC) | ✅ |
| Reconnect sau khi tắt app (SHA-256) | ✅ |
| State Restoration (iOS background) | ✅ |
| Khoá / Mở khoá xe | ✅ |
| Bật / Tắt xe | ✅ |
| Chế độ chống trộm (Arm) | ✅ |
| Tìm xe (còi) | ✅ |
| Đọc thông tin xe (tên, serial, model) | ✅ |
| Đọc trạng thái khóa real-time | ✅ |
| Debug log (TX/RX GATT) | ✅ |
| Forget bike (xóa kết nối) | ✅ |
| Xử lý lỗi Peer Removed Pairing | ✅ |
| Local notification (mất kết nối) | ✅ |

---

## Các bug đã phát hiện và sửa

### 1. Race condition UUID (Bug nghiêm trọng nhất)

**Mô tả:** UUID được lưu vào `UserDefaults` **trước** khi gọi `authenticate()`. Trong `authenticate()`, được đọc ngay lập tức để check `isKnownDevice`. Kết quả: ngay cả lần kết nối đầu tiên (chưa pair), `isKnownDevice = true` → dùng SHA flow → SHA thất bại → xe xóa bonding → `Peer removed pairing information` loop.

**Fix:** Di chuyển `UserDefaults.set(uuid)` vào cuối `authenticate()`, chỉ sau khi xác thực thành công hoàn toàn.

```swift
// BEFORE (bug): lưu trước authenticate()
UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "lastPeripheralUUID")
try await authenticate()

// AFTER (fixed): lưu cuối authenticate() khi done
// ... step 7 done ...
UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "lastPeripheralUUID")
DispatchQueue.main.async { self.isAuthenticated = true }
```

### 2. willRestoreState force re-auth (iOS background reconnect bị phá)

**Mô tả:** Khi iOS restore BLE session từ background (peripheral vẫn connected), code force `isAuthenticated = false` và chạy lại SHA. Gửi SHA bất ngờ vào session đang sống → xe từ chối → xóa bonding.

**Fix:** Restore logic về như commit `f8545e5` gốc: nếu `p.state == .connected` → `isAuthenticated = true` trực tiếp, không re-auth.

### 3. Protocol step order sai

**Mô tả:** `setNotifyValue(serviceChanged)` được gọi trước session token + proximity token. Theo btsnoop, thứ tự đúng là: Session Token → Proximity Token → CCCD subscribe.

**Fix:** Sắp xếp lại thứ tự theo đúng btsnoop_hci.log.

### 4. Subscribe sai characteristics

**Mô tả:** Thêm `setNotifyValue` cho `smartkeyEcho` và `lockState`. Hai characteristic này dùng polling (đọc định kỳ), không phải notification mode theo giao thức gốc.

**Fix:** Xóa bỏ, chỉ giữ `serviceChanged` CCCD.

### 5. Verify read sau SHA gây timing issue

**Mô tả:** Thêm một Read request ngay sau SHA write để "xác minh". Read này không có trong btsnoop gốc và có thể gây race condition với firmware xe.

**Fix:** Xóa bỏ verify read.

---

## Giao thức BLE chi tiết — Sequence diagram reconnect

```
iPhone (App)                              Dat Bike Quantum S3
    |                                              |
    |-- [SCAN FCF1 UUID] ---------------------->  |
    |<- [ADV: Dat Bike Quantum S3] -------------- |
    |                                              |
    |-- [CONNECT] ------------------------------>  |
    |<- [CONNECTED] ----------------------------- |
    |                                              |
    |-- [DISCOVER SERVICES] ------------------->  |
    |<- [SERVICES: auth, config, main, ext] ----- |
    |                                              |
    |-- [READ authChallenge 0x000C] ----------->  |
    |<- [RESP: e.g. 64a7ac1f] ------------------- |
    |                                              |
    |   [COMPUTE: SHA256(str(0x1faca764>>1) + PIN)]
    |   = SHA256("2657043701234abcd")              |
    |   = "2bb5f1d0ec7356e1..."                   |
    |                                              |
    |-- [WRITE hash_hex → 0x000C] ------------->  |
    |<- [ACK] ----------------------------------- |
    |                                              |
    |-- [WRITE sessionToken → 0x002E] -------->  |
    |<- [ACK] ----------------------------------- |
    |                                              |
    |-- [WRITE proximityToken → 0x032] ------->  |
    |<- [ACK] ----------------------------------- |
    |                                              |
    |-- [CCCD WRITE 0x0200 → 0x0009] -------->  |
    |<- [ACK] ----------------------------------- |
    |                                              |
    |   [AUTH COMPLETE — Dashboard ready]          |
    |   [Xe hiển thị icon Bluetooth trên màn hình]
    |                                              |
    |-- [READ vehicleInfo...] ----------------->  |
    |-- [READ lockState 0x0036] --------------->  |
    |<- [RESP: 0x0000 = tắt / 0x0200 = bật] ---- |
```

---

## Lưu ý quan trọng khi phát triển

1. **PIN mặc định** (`BLEProtocol.authPIN`) phải khớp với PIN đã đăng ký khi NFC pairing. PIN sai → SHA sai → xe xóa bonding.

2. **Một chiều duy nhất**: Bật CCCD (`setNotifyValue`) chỉ cho `serviceChanged` (UUID `2A05`). Các characteristic khác dùng polling.

3. **`isKnownDevice`** kiểm tra xem UUID trong `UserDefaults` có khớp `peripheral.identifier.uuidString` không. Đây là gate để chọn SHA vs PlainPIN flow.

4. **State Restoration** (`CBCentralManagerOptionRestoreIdentifierKey`) là bắt buộc để iOS duy trì BLE session trong background. Cần khai báo trong `Info.plist` key `bluetooth-central`.

5. **Trạng thái xe** (thô) đọc từ `smartkeyEcho` (0x0036):
   - `0x0000` hoặc `0x31` = Đang tắt/khóa
   - `0x0200` hoặc `0x30` = Đang bật/mở
   - `0x0700` = Chế độ chống trộm (Arm)

---

## Công cụ reverse engineering đã dùng

| Công cụ | Mục đích |
|---|---|
| `Wireshark` + `btsnoop_hci.log` | Capture và phân tích GATT packets |
| `parse_btsnoop2.py` | Parse raw btsnoop thành TX/RX readable format |
| `find_hash.py`, `test_hash.py` | Xác minh công thức SHA-256 theo challenge nonce |
| `nRF Connect` (Android) | Debug GATT services trực tiếp trên xe |
| JS decompiler | Phân tích Hermes bytecode của app chính thức |

---

## Hạn chế đã biết

- **Xóa bonding từ iOS:** iOS không cho phép app xóa LTK programmatically. Khi xe xóa bonding (power cycle lâu dài, firmware reset), phải vào **Settings → Bluetooth → Dat Bike → Quên thiết bị này** rồi pair lại bằng NFC.
- **PIN cứng:** PIN hiện tại cần khớp với lần pair đầu. Nếu muốn đổi PIN, phải pair lại.
- **Firmware specific:** Giao thức này xác minh trên firmware 1.10.1. Firmware mới có thể thay đổi characteristic UUID hoặc SHA formula.
