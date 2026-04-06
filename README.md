# Dat Bike Smartkey — iOS Native App

Ứng dụng iOS native thay thế smartkey chính thức cho xe **Dat Bike Quantum S3**, được xây dựng hoàn toàn từ kết quả reverse-engineering giao thức BLE độc quyền của hãng.

---

## Tóm tắt dự án

| Hạng mục | Chi tiết |
|---|---|
| **Phiên bản** | 3.0.1 |
| **Nền tảng** | iOS 15+, Swift 5.9, SwiftUI |
| **BLE Stack** | CoreBluetooth + Background BLE (State Restoration) |
| **Mã hóa** | SHA-256 (CryptoKit), PIN challenge-response |
| **PIN** | 12 ký tự ngẫu nhiên (chữ thường + hoa + số + đặc biệt), SecRandomCopyBytes |
| **Mô hình** | Native GATT client — reverse-engineered từ `btsnoop_hci.log` |
| **Xe hỗ trợ** | Dat Bike Quantum S3 (firmware 1.10.1+) |

---

## Kiến trúc v3.0

```
┌─────────────────────────────────────────┐
│  DatBikeSmartKeyApp                     │
│  ├── AppDIContainer (IoC)               │
│  ├── DatBikeCore (BLE Coordinator)      │
│  │   ├── CBCentralManager              │
│  │   │   └── State Restoration         │
│  │   ├── BLEAuthenticator              │
│  │   │   ├── Pairing: Plaintext PIN    │
│  │   │   └── Reconnect: SHA-256 Hash   │
│  │   ├── BLECommandDispatcher          │
│  │   ├── BLEPollingEngine (RSSI/Tele)  │
│  │   └── BLEConnectionContext           │
│  ├── DashboardViewModel                 │
│  ├── SettingsViewModel                  │
│  └── Views (SwiftUI)                    │
└─────────────────────────────────────────┘
```

### Mô hình hoạt động

- **Foreground**: Scan → Connect → Auth → Dashboard điều khiển
- **Background**: iOS duy trì kết nối + pending reconnect vô thời hạn
- **App bị kill**: State Restoration khôi phục peripheral đã kết nối
- **Xe quay lại tầm**: iOS tự động reconnect (pending connect)

---

## Giao thức xác thực

Xe Dat Bike dùng **2 luồng** phụ thuộc vào việc thiết bị đã pair chưa:

### Luồng 1: Pairing lần đầu (Plaintext PIN + NFC)

```
App → Write PIN (12 chars) → authChallenge (0x000C)
Xe → Trigger SMP pairing
User → Quẹt thẻ NFC lên xe → Xác nhận Bonding
```

### Luồng 2: Reconnect (SHA-256 Challenge-Response)

```
1. Đọc authChallenge (0x000C) → counter (4 byte, little-endian)
2. Kiểm tra counter:
   - Lẻ (odd) = Đã xác thực trước đó → skip
   - Chẵn (even) = Cần xác thực
3. hash = SHA-256( (counter >> 1) + PIN )
4. Ghi hash → authChallenge (0x000C) — NGAY LẬP TỨC (không delay)
5. Đọc lại counter:
   - Chẵn → Lẻ = ✅ Thành công
   - Vẫn chẵn = ❌ Thất bại
6. Ghi sessionToken → proximityToken → enable Notify serviceChanged
```

> **Quy tắc counter**: Chẵn = chờ xác thực, Lẻ = đã xác thực. Xem chi tiết tại `.agent/workflows/ble-auth-protocol.md`

---

## Các Command xe

| Tên | UUID (short) | Giá trị (HEX) | Chức năng |
|---|---|---|---|
| `unlockCmd` | 7F13FE5C | `0x31` | **Bật xe (Power ON)** |
| `unlockCmd` | 7F13FE5C | `0x30` | **Tắt xe (Power OFF)** |
| `smartkeyEcho` | EEC8FD7F | `0x31` | **Khóa chống trộm (Arm)** |
| `findBike` | 350D9A82 | `0x31` / `0x30` | Bật / Tắt còi tìm xe |

---

## Tính năng v3.0

| Tính năng | Trạng thái |
|---|---|
| Pairing NFC + secure PIN (12 chars) | ✅ |
| Reconnect SHA-256 (odd/even counter) | ✅ |
| Background BLE (State Restoration) | ✅ |
| Auto-reconnect khi xe vào tầm (pending connect) | ✅ |
| MIC failure auto-recovery (6 retries) | ✅ |
| Bật / Tắt xe | ✅ |
| Khóa chống trộm (Arm) | ✅ |
| Tìm xe (còi) | ✅ |
| Đọc telemetry: % pin, odo, nhiệt độ | ✅ |
| Đọc thông tin xe: tên, model, số khung, firmware | ✅ |
| RSSI signal strength real-time | ✅ |
| Tự động đồng bộ giờ xe (1 lần/ngày) | ✅ |
| Auto-unlock khi tới gần xe | ❌ (Planned v4.0) |

---

## Cấu trúc dự án

```
DatBikeSmartkey/
├── DatBikeSmartKeyApp.swift     # Entry point
├── AppDIContainer.swift         # Dependency injection
├── Info.plist                   # bluetooth-central background mode
│
├── BLE/
│   ├── Core/
│   │   ├── DatBikeCore.swift           # BLE coordinator chính
│   │   ├── BLEStateMachine.swift       # State management
│   │   └── PreferencesManager.swift    # Lưu trữ cài đặt
│   ├── Domain/
│   │   ├── BLEConstants.swift          # UUIDs, protocol constants
│   │   ├── IoTTypedModels.swift        # Data models
│   │   ├── IoTProtocols.swift          # Protocol definitions
│   │   └── IoTError.swift              # Error types
│   └── Services/
│       ├── BLEAuthenticator.swift      # SHA-256 auth flow
│       ├── BLECommandDispatcher.swift  # Command execution
│       ├── BLEPollingEngine.swift      # RSSI + telemetry polling
│       └── BLECryptography.swift       # SHA-256 hash computation
│
├── ViewModels/
│   ├── DashboardViewModel.swift        # Dashboard binding
│   └── SettingsViewModel.swift         # Settings binding
│
├── Views/
│   ├── MainView.swift                  # Root view + scan picker
│   ├── DashboardView.swift             # Dashboard + lock control
│   ├── SettingsView.swift              # Settings + vehicle info
│   └── Components/
│       ├── LockButton.swift            # Animated lock button
│       └── StatusCard.swift            # Connection status card
│
└── Models/
    └── BikeState.swift                 # Telemetry + state models
```

---

## Hạn chế đã biết

- **Xóa bonding từ iOS**: iOS không cho phép app xóa LTK. Khi xe xóa bonding (MIC failure), phải vào **Settings → Bluetooth → Quên thiết bị** rồi pair lại NFC.
- **PIN cứng**: PIN phải khớp với lần pair đầu. Đổi PIN cần can thiệp firmware.
- **Không có auto-unlock proximity**: App chạy ngầm và tự reconnect, nhưng không tự mở khóa khi tới gần xe.

---

## Lộ trình phát triển

Xem chi tiết tại [ROADMAP.md](ROADMAP.md)

| Version | Mô tả | Thời gian |
|---|---|---|
| **v3.0** *(hiện tại)* | Foreground-first + State Restoration | ✅ Đã ship |
| **v3.5** | + AccessorySetupKit pairing (iOS 17+) | Q2 2026 |
| **v4.0** | Full background BLE + auto-unlock proximity | Q3 2026 |

---

## Build & Run

```bash
# Yêu cầu: Xcode 15+, iOS 14+ device (BLE không hoạt động trên Simulator)
open DatBikeSmartkey.xcodeproj
# Chọn team signing → Build & Run trên thiết bị thật
```

---

*Sản phẩm được tạo bởi tình yêu dành cho chiếc xe Dat Bike* 🏍️
