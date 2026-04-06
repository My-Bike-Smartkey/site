# Dat Bike Smartkey — Lộ trình phát triển

## So sánh tổng quát

| | **v3.0 (Hiện tại)** | **v3.5 (+ ASK)** | **v4.0 (Background hoàn hảo)** |
|---|---|---|---|
| **Mô hình** | Foreground-first + State Restoration | ASK pairing + Foreground | Full background BLE |
| **Pairing** | Scan thủ công + NFC PIN | Apple system picker (ASK) | ASK + background auto |
| **Reconnect khi mở app** | ✅ Tự động | ✅ Tự động | ✅ Tự động |
| **Reconnect khi app bị kill** | ⚠️ Partial (state restore) | ⚠️ Partial (state restore) | ✅ Hoàn toàn tự động |
| **Auto-unlock khi tới gần** | ❌ | ❌ | ✅ |
| **iOS tối thiểu** | 14.0 | 17.0 | 14.0 |
| **App Store review** | Dễ duyệt | Dễ (ASK = chuẩn Apple) | Cần giải trình background |
| **Pin tiêu thụ** | Thấp | Thấp | Trung bình–Cao |
| **Độ phức tạp** | ⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |

---

## v3.0 — Foreground-first + State Restoration *(Hiện tại)*

### Kiến trúc

```
User mở App
    ↓
CBCentralManager (RestoreID)
    ↓              ↓
Scan/Retrieve    willRestore
    ↓              ↓
 Connect → Auth (SHA-256) → Dashboard
```

### Tính năng

- Bật / Tắt xe, Khóa chống trộm, Tìm xe (còi)
- Xác thực SHA-256 challenge-response (odd/even counter)
- PIN bảo mật 12 ký tự (chữ thường + hoa + số + đặc biệt, SecRandomCopyBytes)
- Đọc telemetry: % pin (SOC), odo, nhiệt độ motor/controller
- Đọc thông tin xe: tên, model, số khung, firmware
- Tự động đồng bộ giờ xe 1 lần/ngày
- State restoration khi iOS kill app

### Ưu điểm

- **Ổn định nhất** — ít edge case, ít race condition
- **Tiết kiệm pin** — BLE chỉ active khi user dùng app
- **Dễ debug** — mọi thứ xảy ra trong foreground
- **App Store**: không câu hỏi về background usage

### Hạn chế

- Phải mở app để điều khiển xe
- Rời xa xe > vài giờ → cần tap app để reconnect
- Không có auto-unlock proximity

### Phù hợp với

> User dùng app **khi cần** (bấm khóa/mở trước khi đi). Như điều khiển TV — bấm remote khi cần.

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

### Ưu điểm so với v3.0

- **Pairing đẹp hơn** — system picker thay vì custom list
- **Không cần hỏi quyền Bluetooth** trước khi scan
- **Apple-approved pattern** — dễ duyệt App Store
- **Automatic discovery** — ASK tự tìm thiết bị theo descriptor

### Hạn chế

- **iOS 17+ only** — mất user iOS 14-16
- **Vẫn foreground** — không giải quyết auto-reconnect ngầm
- **Phức tạp hơn** — dual path (ASK + fallback CBCentralManager)

> **Lưu ý:** ASK **không hỗ trợ background reconnect**. Nó chỉ cải thiện pairing UX.

---

## v4.0 — Background BLE hoàn hảo

### Kiến trúc

```
FOREGROUND (khi mở app)
  Scan → Connect → Auth → UI Dashboard

        ↕ (chuyển đổi tự động)

BACKGROUND (app đã đóng)
  willRestoreState
      ↓
  Pending connect (vô thời hạn)
      ↓
  didConnect → Auto auth (< 10s)
      ↓
  RSSI monitor → Auto unlock
      ↓
  Local notification: "Xe đã mở khóa"
```

### Yêu cầu kỹ thuật

1. **Pending Connect**: `centralManager.connect(peripheral)` — iOS giữ request vĩnh viễn
2. **Background Auth < 10s**: discover services → read challenge → write hash → verify, tất cả trong ~10s
3. **RSSI-based Auto Unlock**: `peripheral.readRSSI()` → nếu >= threshold → gửi unlock
4. **Thread-safe state machine**: Actor-based concurrency, persist state to disk

### Thách thức lớn

| Vấn đề | Mức độ | Giải pháp |
|---|---|---|
| **iOS 30s time limit** | 🔴 Nghiêm trọng | Auth phải xong < 10s |
| **MIC failure ở background** | 🔴 Nghiêm trọng | Retry trong time budget |
| **Race condition** | 🟡 Trung bình | Actor-based concurrency |
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

1. **Ship v3.0 ngay** — đủ tốt cho 90% use case
2. **v3.5 nếu cần Apple approval** — ASK giúp duyệt App Store dễ hơn
3. **v4.0 khi có thời gian** — chỉ cần nếu user muốn auto-unlock proximity

> Nếu không cần auto-unlock, **v3.0 → v3.5** là đủ. v4.0 chỉ cần thiết nếu muốn "đến gần xe → tự mở" mà không cần mở app.
