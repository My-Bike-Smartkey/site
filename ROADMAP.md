# Dat Bike Smartkey — Lộ trình phát triển

## So sánh tổng quát

| | **v3.0 (Hiện tại)** | **v3.5 (+ ASK)** | **v4.0 (Auto Unlock)** |
|---|---|---|---|
| **Mô hình** | Background BLE + State Restoration | ASK pairing + Background BLE | Background BLE + Proximity Unlock |
| **Pairing** | Scan thủ công + NFC PIN | Apple system picker (ASK) | ASK + background auto |
| **Reconnect khi mở app** | ✅ Tự động | ✅ Tự động | ✅ Tự động |
| **Reconnect khi app bị kill** | ✅ State Restoration + pending connect | ✅ State Restoration + pending connect | ✅ Hoàn toàn tự động |
| **Auto-reconnect khi xe vào tầm** | ✅ Pending connect (iOS tự reconnect) | ✅ Pending connect | ✅ Pending connect |
| **Auto-unlock khi tới gần** | ❌ | ❌ | ✅ RSSI-based proximity |
| **iOS tối thiểu** | 14.0 | 17.0 | 14.0 |
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
- **Background BLE hoạt động đầy đủ**:
  - `bluetooth-central` background mode
  - State Restoration khi iOS kill app
  - Pending connect — iOS tự reconnect khi xe vào tầm
  - MIC failure auto-recovery (6 retries, progressive delay)
- Đọc telemetry: % pin (SOC), odo, nhiệt độ motor/controller
- Đọc thông tin xe: tên, model, số khung, firmware
- Tự động đồng bộ giờ xe 1 lần/ngày

### Ưu điểm

- **Chạy ngầm tốt** — iOS tự reconnect khi xe quay lại tầm BLE
- **State Restoration** — app bị kill vẫn khôi phục kết nối
- **Tiết kiệm pin hợp lý** — chỉ pending connect, không scan liên tục
- **MIC failure tự phục hồi** — retry 6 lần với delay tăng dần

### Hạn chế

- Không có auto-unlock proximity (tới gần xe → tự mở khóa)
- Phải mở app để điều khiển (bấm nút bật/tắt/chống trộm)
- Pairing lần đầu cần chọn xe thủ công từ danh sách scan

### Phù hợp với

> User dùng app **khi cần** (bấm khóa/mở trước khi đi), nhưng app **tự duy trì kết nối ngầm** với xe mà không cần mở lại.

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
- **Apple-approved pattern** — dễ duyệt App Store hơn
- **Automatic discovery** — ASK tự tìm thiết bị theo descriptor
- Giữ nguyên toàn bộ background BLE capabilities của v3.0

### Hạn chế

- **iOS 17+ only** — mất user iOS 14-16
- **Phức tạp hơn** — dual path (ASK + fallback CBCentralManager)
- Vẫn không có auto-unlock proximity

> **Lưu ý:** ASK cải thiện **pairing UX**, không thay đổi gì về background reconnect (đã có sẵn ở v3.0).

---

## v4.0 — Auto Unlock Proximity

### Khác biệt so với v3.0

v3.0 đã có background reconnect. v4.0 bổ sung thêm:
- **RSSI proximity monitoring** — đo khoảng cách tới xe liên tục
- **Auto unlock** — tự mở khóa khi user đến gần (<2m)
- **Local notification** — thông báo "Xe đã mở khóa" khi auto-unlock
- **Thread-safe state machine** — Actor-based cho background reliability

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
