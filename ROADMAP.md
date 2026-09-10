# Dat Bike Smartkey — Lộ trình phát triển

> **Ghi chú trạng thái (2.0.0):** Tài liệu này là **lịch sử kế hoạch** — các mốc v3.x/v4.x dưới đây đã hoàn thành và được gộp/thay thế bằng bản viết lại 2.0.0 (ASK + iOS 18 + stability rework). Nhiệm vụ đang mở hiện tại nằm ở [`docs/ARCHITECTURE_BLE_AND_ASK.md` §7](docs/ARCHITECTURE_BLE_AND_ASK.md) và ma trận nghiệm thu trong [`docs/TEST_AND_DEPLOYMENT_GUIDE.md`](docs/TEST_AND_DEPLOYMENT_GUIDE.md).

## So sánh tổng quát

| | **v3.0 (Hiện tại)** | **v3.5 (+ ASK)** | **v4.0 (Auto Unlock)** |
|---|---|---|---|
| **Mô hình** | Background BLE + State Restoration | ASK pairing + Background BLE | Background BLE + Proximity Unlock |
| **Pairing** | Scan thủ công + NFC PIN | Apple system picker (ASK) | ASK + background auto |
| **Reconnect khi mở app** | ✅ Tự động | ✅ Tự động | ✅ Tự động |
| **Reconnect khi app bị kill** | ⚠️ Có nhưng không 100% | ⚠️ Có nhưng không 100% | ✅ Tối ưu (~95%) |
| **Auto-reconnect khi xe vào tầm** | ⚠️ Pending connect (phụ thuộc iOS) | ⚠️ Pending connect | ✅ Pending connect + optimized |
| **Auto-unlock khi tới gần** | ❌ | ❌ | ✅ RSSI-based proximity |
| **iOS tối thiểu** | 15.0 | 17.0 | 15.0 |
| **App Store review** | Cần giải trình background | Dễ (ASK = chuẩn Apple) | Cần giải trình background |
| **Pin tiêu thụ** | Thấp–Trung bình | Thấp–Trung bình | Trung bình–Cao |
| **Độ phức tạp** | ⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |

---

## v3.0 — Background BLE + State Restoration *(Hiện tại)*

### Kiến trúc

```
FOREGROUND (khi mở app)
   Scan/Retrieve → Connect → Auth (SHA-256) → Dashboard

BACKGROUND (app ẩn hoặc bị kill)
   ├── bluetooth-central background mode
   ├── CBCentralManager State Restoration (RestoreID)
   ├── Pending connect vô thời hạn (NotifyOnConnection)
   ├── willRestoreState → khôi phục peripheral
   └── didConnect → tự động auth lại
```

### Tính năng

- Bật / Tắt xe, Khóa chống trộm, Tìm xe (còi)
- Xác thực SHA-256 challenge-response (odd/even counter)
- PIN bảo mật 12 ký tự (SecRandomCopyBytes)
- Đọc telemetry: % pin (SOC), odo, nhiệt độ motor/controller
- Đọc thông tin xe: tên, model, số khung, firmware
- Tự động đồng bộ giờ xe 1 lần/ngày

---

### Cơ chế Background BLE — Phân tích chi tiết

v3.0 có **đầy đủ cơ sở hạ tầng** để chạy ngầm:

| Thành phần | File | Mô tả |
|---|---|---|
| `bluetooth-central` background mode | `Info.plist` | Cho phép iOS duy trì BLE khi app ở background |
| `RestoreIdentifierKey` | `DatBikeCore.swift` | ID = `"datbike.core.central"` để iOS nhận diện |
| `willRestoreState` | `DatBikeCore.swift` | Khôi phục peripheral + context khi app bị kill → relaunch |
| Pending connect | `DatBikeCore.swift` | `central.connect(peripheral)` với `NotifyOnConnectionKey` |
| `didConnect` → Auth | `DatBikeCore.swift` | Discover services → discover chars → trigger auth tự động |

---

### Vòng đời iOS khi app bị tắt — Timeline

#### Kịch bản: User vuốt tắt app → rời xa xe → quay lại

```
Bước 1: App đang connected + authenticated
        ↓
Bước 2: User vuốt tắt app (swipe kill)
        ↓
Bước 3: iOS fire didDisconnect
        → App gọi central.connect(peripheral) [pending connect]
        → iOS ghi nhận pending connect request
        ↓
Bước 4: iOS KILL process hoàn toàn
        → RAM bị xóa sạch, tất cả biến mất
        → Pending connect VẪN ĐƯỢC iOS GIỮ ở tầng hệ thống
        ↓
Bước 5: User rời xa xe (ngoài tầm BLE ~20m)
        → iOS hủy BLE link layer
        → Pending connect vẫn tồn tại
        ↓
Bước 6: User quay lại gần xe
        → iOS phát hiện peripheral advertisement
        → Match với pending connect request
        → iOS RELAUNCH app ngầm (không có giao diện)
        ↓
Bước 7: iOS gọi tuần tự:
        ① willRestoreState → khôi phục peripheral object
        ② centralManagerDidUpdateState(.poweredOn)
        ③ didConnect → discoverServices → auth SHA-256
```

#### Bảng timeline chi tiết

| Thời điểm | iOS lifecycle | Xe thấy gì |
|---|---|---|
| 0s | User vuốt tắt app | Xe mất kết nối BLE |
| 0-3s | `didDisconnect` → pending connect | Xe không thấy phone |
| 3s+ | iOS kill process | Phone hoàn toàn offline |
| ... | User rời xa xe | Xe standby |
| ... | User quay lại gần xe | iOS detect advertisement |
| +0s | iOS relaunch app ngầm | Phone reconnecting |
| +1-2s | `willRestoreState` | Khôi phục peripheral |
| +2-3s | `centralManagerDidUpdateState` | Central sẵn sàng |
| +3-5s | `didConnect` | BLE connected (chưa auth) |
| +5-15s | Discover → Auth SHA-256 | Xe thấy icon BT ✅ |

---

### Tại sao bạn không thấy xe auth khi tắt app?

Mặc dù cơ sở hạ tầng background đã có, **có 5 lý do** khiến auth ngầm không hoạt động đáng tin cậy:

#### Lý do 1: iOS không đảm bảo relaunch kịp thời

```
User tắt app → iOS quyết định khi nào relaunch:

  ┌─ Relaunch ngay (hiếm khi, ~10%)
  ├─ Relaunch sau vài giây (~30%)  
  ├─ Relaunch sau vài phút (~40%)
  └─ KHÔNG relaunch (~20%, pin thấp / memory áp lực)
```

iOS **ưu tiên tiết kiệm pin**. Background relaunch không phải real-time. Trong một số trường hợp (pin thấp, nhiều app chạy ngầm), iOS có thể **không relaunch** hoàn toàn.

#### Lý do 2: iOS giới hạn thời gian background ~30 giây

```
App relaunch ngầm
     ↓
  ┌─────── ~30 giây ──────┐
  │ willRestoreState       │
  │ centralManagerDidUpdate│
  │ connect()              │ ← iOS có thể SUSPEND ở bất kỳ điểm nào
  │ didConnect             │  
  │ discoverServices       │
  │ discoverCharacteristics│
  │ Auth SHA-256           │
  │ Post-auth setup        │
  └────────────────────────┘
           ↓
    iOS SUSPEND app → tất cả dừng lại
```

Auth flow hiện tại cần **5-15 giây** (discover + auth + tokens). Nếu BLE connection chậm hoặc MIC retry → **vượt quá 30s** → iOS suspend trước khi auth xong.

#### Lý do 3: willRestoreState bị ghi đè bởi connect()

```
Bước ①: willRestoreState
    activeContext = Context(restored_peripheral)  ← Context A

Bước ②: centralManagerDidUpdateState → gọi connect()
    connect() → retrievePeripherals → connectPeripheral()
    activeContext = Context(new_peripheral)        ← Context B GHI ĐÈ A!
```

Context được tạo tại `willRestoreState` bị **ghi đè** bởi `connect()` ở bước tiếp theo. Điều này có thể gây ra xung đột peripheral reference.

#### Lý do 4: Background scan bị iOS hạn chế nghiêm ngặt

Nếu `connect()` rơi vào nhánh `startScanWithTimeout()` (không tìm thấy peripheral trong cache):
- iOS **giảm tốc độ scan** 10-100x ở background  
- iOS có thể **không báo kết quả discovery** ở background
- Timeout scan có thể kích hoạt trước khi iOS cho kết quả

#### Lý do 5: Firmware xe có timeout chờ auth

Firmware Dat Bike có thể có **timeout chờ xác thực** (~30s kể từ BLE connect). Nếu app relaunch chậm + auth flow chậm → firmware đã close connection trước khi hash được ghi.

---

### Trạng thái Background thực tế

| Khả năng | Có/Không | Tin cậy | Ghi chú |
|---|---|---|---|
| Background mode enabled | ✅ | 100% | `Info.plist` configured |
| State Restoration configured | ✅ | 100% | `RestoreIdentifierKey` + `willRestoreState` |
| Pending connect sau disconnect | ✅ | 100% | `central.connect()` trong `didDisconnect` |
| iOS relaunch app ngầm | ✅ | ~60-80% | Phụ thuộc iOS scheduling, pin, memory |
| Auth hoàn tất ở background | ⚠️ | ~40-60% | Phụ thuộc timing, có thể timeout |
| Xe nhận auth ngầm | ⚠️ | ~40-60% | Auth phải xong trong giới hạn iOS |
| Auto-unlock proximity | ❌ | 0% | Chưa implement |

**Tỷ lệ background auth thành công tổng thể: ~40-70%** (phụ thuộc điều kiện)

---

### Cách kiểm chứng background auth

1. Mở app → kết nối xe → xác thực thành công
2. Vuốt tắt app hoàn toàn (swipe kill)
3. Rời xa xe > 20m (ngoài tầm BLE) → đợi 30 giây
4. Quay lại gần xe → đợi 1-2 phút
5. Mở app → vào Settings → Xem BLE Log → tìm:

| Log message | Ý nghĩa |
|---|---|
| `"State Restoration: khôi phục QT_xxx"` | ✅ iOS đã relaunch app ngầm |
| `"Auth: SHA-256 reconnect mode"` | ✅ Auth đã chạy ở background |
| `"Auth thành công (counter chẵn → lẻ)"` | ✅ Xe đã nhận auth |
| Không có log mới | ❌ iOS không relaunch app |
| `"MIC failure"` hoặc disconnect | ❌ Auth thất bại, cần retry |

---

### Kết luận v3.0

> v3.0 có **cơ sở hạ tầng đầy đủ** cho background BLE, nhưng **không 100% đáng tin cậy** do hạn chế của iOS. 
>
> Đây là mức tốt nhất có thể đạt được với kiến trúc hiện tại. Để đạt **>95% reliability**, cần v4.0 với: `beginBackgroundTask`, auth pipeline < 5s, Actor-based state machine, persistent state to disk.

### Phù hợp với

> User dùng app **khi cần** (bấm khóa/mở trước khi đi). Background reconnect là **bonus** — có khi hoạt động, có khi cần mở app lại. **Không nên phụ thuộc** vào background auth cho use case quan trọng.

---

## v3.5 — AccessorySetupKit (ASK)

### AccessorySetupKit là gì?

ASK (iOS 17+) là framework Apple cho phép:
- **System-level pairing UI** — Apple quản lý picker, không cần quyền Bluetooth trước
- **Persistent identity** — accessory identity lưu ở system level
- **Privacy**: user thấy rõ thiết bị nào đang connect

### Thay đổi so với v3.0

| Thành phần | v3.0 | v3.5 |
|---|---|---|
| **Pairing lần đầu** | Scan thủ công → chọn từ list | `ASAccessorySession.showPicker()` |
| **Lưu UUID** | `PreferencesManager.savedPeripheralUUID` | `ASAccessory.bluetoothIdentifier` |
| **Reconnect** | `retrievePeripherals(withIdentifiers:)` | Giữ nguyên |
| **Auth flow** | SHA-256 challenge-response | Giữ nguyên |
| **UI scan** | Custom bike picker | Apple system sheet |
| **Background BLE** | Giữ nguyên | Giữ nguyên |

### Ưu điểm so với v3.0

- **Pairing đẹp hơn** — system picker thay vì custom list
- **Không cần hỏi quyền Bluetooth** trước khi scan
- **Apple-approved pattern** — dễ duyệt App Store hơn
- **Automatic discovery** — ASK tự tìm thiết bị theo descriptor
- Giữ nguyên background BLE capabilities của v3.0

### Hạn chế

- **iOS 17+ only** — mất user iOS 14-16
- **Phức tạp hơn** — dual path (ASK + fallback CBCentralManager)
- Vẫn không có auto-unlock proximity

> **Lưu ý:** ASK cải thiện **pairing UX**, không thay đổi gì về background reconnect (cùng hạn chế như v3.0).

---

## v4.0 — Auto Unlock Proximity

### Khác biệt so với v3.0

v3.0 đã có background reconnect (~40-70% reliability). v4.0 nâng lên **>95%** và bổ sung:
- **`beginBackgroundTask`** — xin iOS thêm thời gian cho auth
- **Auth pipeline < 5s** — tối ưu GATT flow, loại bỏ delay
- **Actor-based state machine** — thread-safe, không race condition
- **Persistent state to disk** — không mất state khi app bị kill
- **RSSI proximity monitoring** — đo khoảng cách tới xe liên tục
- **Auto unlock** — tự mở khóa khi user đến gần (<2m)
- **Local notification** — thông báo "Xe đã mở khóa" khi auto-unlock

### Kiến trúc

```
FOREGROUND (khi mở app)
  Scan → Connect → Auth → UI Dashboard

        ↕ (chuyển đổi tự động)

BACKGROUND (app đã đóng)
  willRestoreState
      ↓
  beginBackgroundTask (xin thêm ~30s)
      ↓
  Pending connect (vô thời hạn)
      ↓
  didConnect → Optimized auth (< 5s)
      ↓
  RSSI monitor → Auto unlock
      ↓
  Local notification: "Xe đã mở khóa"
```

### Yêu cầu kỹ thuật

1. **`beginBackgroundTask`**: Xin iOS thêm ~30s execution time khi auth ở background
2. **Auth < 5s**: Optimize GATT pipeline — parallel discover, skip unnecessary reads
3. **RSSI-based Auto Unlock**: `peripheral.readRSSI()` → nếu >= threshold → unlock
4. **Actor-based state machine**: Thread-safe, persist to UserDefaults
5. **Proper `willRestoreState`**: Không ghi đè context, tái sử dụng peripheral đã restore

### Thách thức lớn

| Vấn đề | Mức độ | Giải pháp |
|---|---|---|
| **iOS 30s time limit** | 🔴 Nghiêm trọng | `beginBackgroundTask` + auth < 5s |
| **MIC failure ở background** | 🔴 Nghiêm trọng | Compact retry (1s delay, max 3x) |
| **Race condition** | 🟡 Trung bình | Actor-based concurrency |
| **willRestoreState conflict** | 🟡 Trung bình | Check existing context trước khi connect |
| **Pin tiêu thụ** | 🟡 Trung bình | RSSI chỉ khi gần xe |
| **App Store review** | 🟡 Trung bình | Giải trình smartkey use case |
| **Testing** | 🔴 Rất khó | Physical device + firmware |

### Kiến trúc đề xuất

```
DatBikeCore
├── ForegroundCoordinator   ← UI-driven operations
├── BackgroundCoordinator   ← iOS-triggered operations  
├── AuthStateMachine        ← Actor-based, thread-safe
├── PendingConnectManager   ← Track pending connects
└── ProximityMonitor        ← RSSI-based unlock trigger
```

> **Cảnh báo:** Background BLE trên iOS là chiến trường khắc nghiệt. Apple chủ ý hạn chế để tiết kiệm pin. Expect 6-8 tuần dev + test.

---

## Lộ trình đề xuất

```
Tháng 4/2026
├── v3.0: Ổn định + ship ✅
└── v3.0: Field testing 2 tuần

Tháng 5/2026
├── v3.5: Tích hợp ASK pairing (~2 tuần)
└── v3.5: Test iOS 17+ (~1 tuần)

Tháng 6-7/2026
├── v4.0: Thiết kế background arch (~2 tuần)
├── v4.0: Implement + test (~6 tuần)
└── v4.0: Field testing 2 tuần
```

### Khuyến nghị

1. **Ship v3.0 ngay** — đủ tốt cho 90% use case (mở app → điều khiển xe)
2. **v3.5 nếu cần Apple approval** — ASK giúp duyệt App Store dễ hơn
3. **v4.0 khi có thời gian** — chỉ cần nếu user muốn auto-unlock proximity

> Nếu không cần auto-unlock, **v3.0 → v3.5** là đủ. v4.0 chỉ cần thiết nếu muốn "đến gần xe → tự mở" mà không cần mở app.
