---
description: Dat Bike BLE Authentication Protocol — SHA-256 Challenge/Response
---

# Dat Bike BLE Authentication Protocol

## Overview
Xe Dat Bike (Quantum S3) sử dụng SHA-256 challenge/response để xác thực app sau khi kết nối BLE.
Characteristic: `authChallenge` (UUID: `DE77B250-...`)

## Kiến trúc kết nối

### Các tầng quản lý BLE

| Tầng | Component | Vai trò |
|---|---|---|
| App | `DatBikeCore` + `BLEStateMachine` | State machine, auth, data |
| iOS 18+ | `AccessorySetupKit (ASK)` | System-level bond, pairing UI |
| iOS | `CoreBluetooth` + State Restoration | Background BLE, auto-reconnect |
| Hardware | Chip BLE trên xe | Encryption, counter, GATT |

### AccessorySetupKit (ASK) — iOS 18+

> **QUAN TRỌNG:** ASK tạo **system-level bond** giống AirPods.
> Kết nối BLE được iOS hệ thống duy trì **độc lập với app**.
> Force quit app → iOS vẫn giữ kết nối BLE (đèn BT xe vẫn sáng).

- ASK config trong `Info.plist`: `NSAccessorySetupBluetoothServices`, `NSAccessorySetupKitSupports`
- Xe hiển thị trong Settings > Bluetooth
- Managed bởi `ASKManager.swift`

### State Machine (`BLEStateMachine`)

```
idle → scanning → connecting → authenticating → active
                                    ↓
                              pairingRequired → active
                                    
Bất kỳ state → error(String)
```

- `IoTConnectionState` defined in `IoTTypedModels.swift`
- `.active` = kết nối + auth hoàn tất → Dashboard hiển thị
- `.isConnected` chỉ true khi state == `.active`

## Luồng kết nối (Connection Flow)

### 1. Khởi tạo
```
MainView.onAppear → initializeBluetoothHardware()
  → CBCentralManager(restoreIdentifier: "datbike.core.central")
  → centralManagerDidUpdateState(.poweredOn)
  → connect()
```

### 2. connect() — Logic chọn đường
```
connect()
  ├─ btWasPoweredOff == true?  → startScanWithTimeout() [scan mới]
  ├─ retrieveConnectedPeripherals → connectPeripheral() [live session]  
  ├─ retrievePeripherals(cache)  → connectPeripheral() [cached]
  └─ fallback → startScanWithTimeout()
```

### 3. Sau khi kết nối BLE thành công
```
didConnect → discoverServices → didDiscoverServices
  → didDiscoverCharacteristics → executeAuthProtocol()
```

## Luồng xác thực (Reconnect Flow — SHA-256)

### 1. Đọc Challenge Counter
- READ `authChallenge` → 4 bytes Little-Endian → `counter` (UInt32)

### 2. Tính SHA-256 Hash
```
input = String(counter >> 1) + PIN
hash  = SHA-256(input).hexString
```
- `counter >> 1` = chia 2 bỏ bit cuối (shift right 1 bit)
- PIN = chuỗi 12 ký tự đã lưu từ lần NFC pairing

### 3. Ghi Hash
- WRITE `hash` (hex string UTF-8) → `authChallenge`, `.withResponse`
- **Ghi tức thì, KHÔNG ĐỢI delay trước khi ghi**

### 4. Verify Counter (Quy tắc Chẵn/Lẻ)

> **QUAN TRỌNG — Quy tắc counter:**
> - Counter **CHẴN** = đang chờ xác thực (chưa auth)
> - Counter **LẺ** = đã xác thực thành công
> - Xác thực thành công = counter chuyển từ **CHẴN → LẺ**
> - Nếu counter vẫn **CHẴN** sau khi ghi hash → xác thực thất bại

- READ `authChallenge` lại
- Retry tối đa 4 lần với delay tăng dần: 200ms, 400ms, 700ms, 1200ms
- Kiểm tra `newCounter % 2 != 0` (lẻ) → thành công

### Ví dụ
```
Counter = 10 (chẵn)  → chờ xác thực
Hash = SHA-256("5" + PIN)  (10 >> 1 = 5)
Ghi hash...
Counter = 11 (lẻ)   → xác thực thành công ✅
Counter = 10 (chẵn) → thất bại ✗, retry
```

## Luồng Pairing (Lần đầu / NFC)
- WRITE PIN plain-text → `authChallenge`, `.withResponse`
- Retry 10 lần × 2s (chờ user quẹt thẻ NFC)
- Sau khi pair: confirm PIN thêm 2 lần

## MIC Failure — Nguyên nhân và Giải pháp

### Nguyên nhân gốc
```
iOS cache Link-Layer Encryption Keys (LTK) theo peripheral UUID.
Khi BT tắt/bật: xe xóa keys → iOS giữ keys cũ → MIC failure.
ASK làm trầm trọng thêm vì duy trì system-level bond sau force quit.
```

### 3 tầng bảo vệ (đã implement)

#### Tầng 1: `btWasPoweredOff` flag

```swift
// poweredOff → đánh dấu
btWasPoweredOff = true

// poweredOn → xóa context cũ + cancelPeripheralConnection
if btWasPoweredOff {
    central.cancelPeripheralConnection(ctx.peripheral) // flush encryption
    activeContext = nil
}

// connect() → bỏ qua retrievePeripherals, scan mới
if btWasPoweredOff {
    startScanWithTimeout() // fresh advertisement → fresh encryption
}
```

#### Tầng 2: `willRestoreState` — chỉ tin peripheral `.connected`

```swift
if restored.state == .connected {
    // encryption keys vẫn sống → dùng tiếp
    activeContext = ctx
} else {
    // state 0 hoặc 1 → keys có thể stale → bỏ qua
    // connect() sẽ scan mới
}
```

#### Tầng 3: MIC failure handler — scan mới ngay

```swift
if isMICFailure {
    btWasPoweredOff = true  // đánh dấu để connect() scan mới
    startScanWithTimeout()   // không retry delay, scan ngay
}
```

### Quy tắc vàng

> **KHÔNG BAO GIỜ dùng `retrievePeripherals` (cache) sau khi:**
> 1. Bluetooth bị tắt/bật (power-cycle)
> 2. App bị kill và restore với peripheral không connected
> 3. Đã dính MIC failure 1 lần
>
> **LUÔN LUÔN scan mới** trong các trường hợp trên để iOS negotiate fresh link-layer encryption.

## Background & Auto-reconnect

### Cơ chế chạy nền

| Kịch bản | Hoạt động? | Cơ chế |
|---|---|---|
| Vuốt về Home | ✅ | `UIBackgroundModes: bluetooth-central` |
| iOS kill (thiếu RAM) | ✅ | State Restoration (`CBCentralManagerOptionRestoreIdentifierKey`) |
| Đi xa, quay lại | ✅ | `central.connect()` treo chờ nền + `NotifyOnConnectionKey` |
| Force quit (vuốt tắt) | ❌ | Apple chặn — không app nào bypass được |

### didDisconnectPeripheral
- Disconnect có error → `central.connect()` treo chờ, fallback `connect()` sau 3s
- Disconnect không error (user-initiated) → `disconnect()` dọn dẹp

## Lưu ý cho developer

- PIN được lưu vào `PreferencesManager.savedPin` sau lần pair đầu tiên
- Peripheral UUID lưu vào `PreferencesManager.savedPeripheralUUID`
- Nếu PIN bị ghi đè → SHA hash sai → auth fail
- `BLEStateMachine` transition qua `DispatchQueue.main.async` để tránh "Publishing changes from within view updates"
- `showPicker()` của ASK cần delay 0.2s để tránh "Application is not in foreground"

## File quan trọng

| File | Vai trò |
|---|---|
| `BLE/Core/DatBikeCore.swift` | State machine, connection, reconnect |
| `BLE/Core/BLEStateMachine.swift` | Single source of truth cho state |
| `BLE/Core/ASKManager.swift` | AccessorySetupKit session |
| `BLE/Services/BLEAuthenticator.swift` | SHA-256 auth + NFC pairing |
| `BLE/Services/BLECryptography.swift` | SHA-256 hash computation |
| `BLE/Domain/IoTTypedModels.swift` | `IoTConnectionState` enum |
| `ViewModels/DashboardViewModel.swift` | UI bridge, thread-safe state |
| `Views/MainView.swift` | Screen routing (splash vs dashboard) |
