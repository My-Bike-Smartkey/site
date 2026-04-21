# DatBike Smartkey — Tài liệu Kỹ thuật BLE Connection Lifecycle

> Cập nhật: 2026-04-21 | Branch: `ask-background`

---

## Mục lục

1. [Kiến trúc tổng quan](#1-kiến-trúc-tổng-quan)
2. [Máy trạng thái (State Machine)](#2-máy-trạng-thái-state-machine)
3. [Kịch bản mở app](#3-kịch-bản-mở-app)
4. [Chạy ngầm (Background Mode)](#4-chạy-ngầm-background-mode)
5. [Xác thực bảo mật (Auth Protocol)](#5-xác-thực-bảo-mật-auth-protocol)
6. [Proximity Detection & Auto-Unlock](#6-proximity-detection--auto-unlock)
7. [Reconnect & Disconnect Handling](#7-reconnect--disconnect-handling)
8. [AccessorySetupKit (ASK) — iOS 18+](#8-accessorysetupkit-ask--ios-18)
9. [GATT Queue & I/O Safety](#9-gatt-queue--io-safety)
10. [Battery Monitoring](#10-battery-monitoring)
11. [Cờ trạng thái quan trọng](#11-cờ-trạng-thái-quan-trọng)

---

## 1. Kiến trúc tổng quan

```
┌─────────────────────────────────────────────────────────┐
│                       UI Layer                          │
│  MainView → DashboardView / ConnectingSplashView        │
└────────────────────┬────────────────────────────────────┘
                     │ @Published / Combine publishers
┌────────────────────▼────────────────────────────────────┐
│                  ViewModel Layer                        │
│  DashboardViewModel  BatteryViewModel  SettingsViewModel│
└────────────────────┬────────────────────────────────────┘
                     │ Gọi methods trực tiếp
┌────────────────────▼────────────────────────────────────┐
│              DatBikeCore (Facade)                       │
│  BLEStateMachine  BLEPollingEngine  BLEAuthenticator    │
│  BLEConnectionContext (BLETaskQueue + BLECharacteristicIO)│
└────────────────────┬────────────────────────────────────┘
                     │ CoreBluetooth
┌────────────────────▼────────────────────────────────────┐
│              iOS CoreBluetooth                          │
│  CBCentralManager  CBPeripheral  CBCharacteristic       │
└─────────────────────────────────────────────────────────┘
```

| Class | Vai trò |
|-------|---------|
| `DatBikeCore` | Facade trung tâm, xử lý toàn bộ CBCentralManager/CBPeripheral delegates |
| `BLEStateMachine` | Máy trạng thái với `removeDuplicates()` — Single Source of Truth |
| `BLEConnectionContext` | Đóng gói 1 phiên kết nối (peripheral + queue + I/O) |
| `BLETaskQueue` | FIFO Actor queue đảm bảo GATT commands không xung đột |
| `BLECharacteristicIO` | Wrap async/await + timeout 8s cho từng read/write |
| `BLEPollingEngine` | Timer đọc RSSI và telemetry khi đang active |
| `BLEAuthenticator` | SHA-256 challenge-response auth protocol |
| `BLECommandDispatcher` | Điều khiển xe (bật/tắt/chống trộm) |
| `ASKManager` | AccessorySetupKit wrapper cho iOS 18+ |
| `PreferencesManager` | Singleton quản lý UserDefaults + App Group |

---

## 2. Máy trạng thái (State Machine)

```
          App launch
          ──────────▶  IDLE
                       (chưa khởi tạo BT)
                            │ connect()
                            ▼
                        SCANNING
                       (scan / pending connect)
                            │ didConnect
                            ▼
                        CONNECTING
                       (discover GATT services)
                            │ GATT complete + savedPin
              ┌─────────────┤
              │connectOnlyWhenNear=true
              ▼             │connectOnlyWhenNear=false (fast path)
           STANDBY          │
          (chờ RSSI đủ gần) │
              │ RSSI >= threshold
              └─────────────┤
                            ▼
                      AUTHENTICATING
                       (SHA-256 auth)
                            │ success
                            ▼
                          ACTIVE ✅
                       (điều khiển xe)

  Nhánh đặc biệt:
    CONNECTING ── chưa có savedPin ──▶ PAIRING_REQUIRED (chờ NFC)
    Bất kỳ state ──▶ ERROR (lỗi auth / BT tắt / xe xóa bond)
```

### `isConnected` vs `isWorking`

| Property | States | Dùng để |
|---|---|---|
| `isConnected` | `.active`, `.standby`, `.authenticating` | Ẩn ConnectingSplashView, hiện Dashboard |
| `isWorking` | `.scanning`, `.connecting`, `.authenticating`, `.pairingRequired` | Hiện spinner |

### Quy tắc guard chuyển state

```swift
// Không cho phép: .active → .connecting (vòng lặp lỗi)
case (.active, .connecting): return
```

> **Tất cả state transitions đều dispatch sang `DispatchQueue.main`** qua `BLEStateMachine.transition()`.

---

## 3. Kịch bản mở app

### 3A — Lần đầu (chưa pair xe)

```
MainView.onAppear
  → requestPermission { callback }
    → initializeHardware()
        [iOS 18] hasAuthorizedAccessory=false → LOG "Trì hoãn" → KHÔNG init BT
        [iOS 17] → initializeBluetoothHardware()
    → savedPin == nil → KHÔNG auto-connect → Hiện nút "Thêm xe"
```

### 3B — Bình thường (đã pair, BT bật, xe gần)

```
connect() → central.state == .poweredOn
  → 🛡️ Guard: peripheral.state==.connected? → NO
  → retrieveConnectedPeripherals → không thấy (xe disconnect)
  → retrievePeripherals → tìm theo UUID cache
  → connectPeripheral(p)
    → didConnect → discoverServices
      → didDiscoverCharacteristicsFor
        → startStandbyProximityChecks / fast-path auth
          → executeAuthProtocol → ACTIVE ✅

Timeline điển hình: ~3-5 giây
```

### 3C — Sau khi BT bị tắt/bật (power-cycle)

```
Điều kiện: btWasPoweredOff=true
  (set trong centralManagerDidUpdateState(.poweredOff))

connect():
  → guard btWasPoweredOff || forceFullScan:
      LOG "BT power-cycle → bỏ qua cache, scan mới"
      btWasPoweredOff = false
      startScanWithTimeout() ← scan 4s × 2 lần = max 8s

Lý do phải scan mới:
  iOS giữ LTK (Long-Term Key) encryption keys cho UUID cũ.
  Xe đã xóa keys sau khi BT reset.
  Dùng keys cũ → MIC failure (code 31) / Encryption failure (code 6) sau 5s.
  Scan mới → iOS negotiate fresh link-layer encryption.

Timeline: 8s scan (worst case) + iOS pending connect + auth
```

### 3D — App bị iOS kill, mở lại (State Restoration) ⭐

```
iOS giữ CBCentralManager context với RestoreIdentifierKey: "DatBikeCentralManagerRestoreID"

connect() → centralManager==nil:
  initializeBluetoothHardware()
    CBCentralManager(delegate: self, queue: nil, options: [RestoreKey...])
    ↓
    ┌── iOS gọi willRestoreState() ĐỒNG BỘ bên trong constructor ──┐
    │  restored.state == .connected (2)?                           │
    │    YES → LOG "Xe đang kết nối (live session)"                │
    │         activeContext = ctx                                  │
    │         stateMachine.transition(→ .connecting)               │
    │    NO  → forceFullScan = true                               │
    └─────────────────────────────────────────────────────────────┘
  ← constructor return, centralManager được set

  🛡️ if activeContext == nil:   ← KEY: chỉ transition nếu willRestoreState chưa set
      stateMachine.transition(→ .scanning)
  return

centralManagerDidUpdateState(.poweredOn):
  🛡️ if activeContext != nil && peripheral.state == .connected:
      → [tự sửa state nếu bị override thành .scanning]
      → peripheral.discoverServices() → return ✅
  else:
      → connect() → scan mới

Timeline: < 1 giây từ open app đến ACTIVE
```

> **Tại sao cần guard `activeContext == nil`?**
>
> `willRestoreState` chạy ĐỒNG BỘ bên trong CBCentralManager constructor (confirmed qua log).
> Nếu không guard, `transition(→ .scanning)` sẽ OVERRIDE `.connecting` vừa được set →
> guard trong `centralManagerDidUpdateState` nhìn thấy `.scanning` → không nhận ra live session →
> gọi `connect()` lần 2 → log "Xe đang kết nối" xuất hiện gấp đôi + ghi đè `activeContext`.

---

## 4. Chạy ngầm (Background Mode)

### 4A — Entitlement

```xml
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
</array>
```

Với `bluetooth-central`, iOS cho phép:
- ✅ Duy trì kết nối BLE khi app ẩn
- ✅ Nhận CBCentralManager/CBPeripheral callbacks
- ❌ Timer/DispatchQueue bị đóng băng sau ~10 giây

### 4B — Background execution time

```swift
// Khi app vào background:
appDidEnterBackground():
  isAppInBackground = true
  extendBackgroundExecutionTime()  ← yêu cầu ~30s CPU từ iOS

// Trong 30s: polling, auto-unlock, RSSI check vẫn chạy

// Sau 30s: iOS thu hồi CPU → timers đóng băng
// BLE connection VẪN sống nhờ bluetooth-central
// Xe ngắt → iOS wake app tạm → didDisconnectPeripheral

// Khi foreground lại:
appWillEnterForeground():
  isAppInBackground = false
  stopBackgroundExecutionTime()
  if state == .scanning: connect()
```

### 4C — Background → Standby (ra xa xe khi app ẩn)

```
ACTIVE, isAppInBackground=true, RSSI < threshold-3dBm:
  downgradeToStandby() với background path:
    cancelPeripheralConnection(peripheral)
    activeContext = nil
    central.connect(peripheral, [...])  ← PENDING CONNECT (không dùng Timer!)

Lý do không dùng startScanWithTimeout() trong background:
  scanTimer = Timer → bị đóng băng → scan không bao giờ timeout/kết thúc
  → App mắc kẹt ở state .scanning mãi mãi

Pending connect: iOS tự quản lý, hoạt động đầy đủ trong background ✅
  → Khi xe gần lại: iOS gọi didConnectPeripheral → discoverServices → auth
```

### 4D — State Restoration sau kill

Khi iOS kill app:
- CoreBluetooth context được iOS giữ lại nội bộ (nếu có `RestoreIdentifierKey`)
- Khi app mở lại → `willRestoreState` trả về danh sách peripherals đã restore
- Xe còn connected? → tái sử dụng context ngay, không cần scan
- Xe đã disconnect? → `forceFullScan = true` → scan mới khi BT sẵn sàng

---

## 5. Xác thực bảo mật (Auth Protocol)

### 5A — SHA-256 Challenge-Response

```
App                            Xe (Firmware)
 │── Read authChallenge ──────▶│
 │◀─ [16 bytes nonce] ─────────│
 │                             │
 │  HMAC = sha256(nonce + PIN + counter)
 │                             │
 │── Write response ──────────▶│
 │◀─ ACK / NACK ───────────────│
 │                             │
 │── Write autoUnlock token ──▶│  ← kích hoạt phiên
 │── Write timeSync ──────────▶│  ← đồng bộ đồng hồ
 │                             │
 │  ACTIVE ✅                  │
```

### 5B — Counter mechanism

Xe đếm số lần kết nối qua counter. Counter lẻ → xe đang giữ phiên cũ chưa đóng.

```swift
if counter % 2 == 0:
    throw IoTError.staleAuthentication(counter)
    → invalidateSession() → retry auth
```

### 5C — Retry delays

```
retryDelays: [200ms, 400ms, 700ms, 1200ms]
Tổng tối đa: 2500ms | Thực tế: thường thành công trong 200-400ms
```

### 5D — Xử lý lỗi auth

| Lỗi | Xử lý |
|-----|-------|
| `shaChallengeFailed` | `disconnect()` → `.error` (sai PIN) |
| `staleAuthentication` | `invalidateSession()` → retry |
| Encryption/MIC failure | `btWasPoweredOff=true` → scan mới |
| Code 14 (peer removed pairing) | `savedPeripheralUUID=nil` → `.error` "cần ghép lại" |

---

## 6. Proximity Detection & Auto-Unlock

### 6A — connectOnlyWhenNear: true vs false

| Cài đặt | STANDBY wait | Auto-unlock | Downgrade |
|---|---|---|---|
| `true` | Có (RSSI poll 0.5s) | ✅ Hoạt động | ✅ Hoạt động |
| `false` (default) | **Skip** (auth ngay) | ❌ Bị tắt | ❌ Bị tắt |

### 6B — RSSI Thresholds

```
rssiThreshold (default -75 dBm):
  → Ngưỡng auth từ STANDBY: RSSI >= rssiThreshold

autoTurnOnThreshold (default -50 dBm):
  → Ngưỡng AUTO BẬT XE: RSSI >= autoTurnOnThreshold (phải gần hơn)

Far threshold (downgrade hysteresis):
  rssiThreshold - 3 dBm = -78 dBm
  → Tránh flapping khi RSSI dao động ở ranh giới
```

### 6C — Auto-unlock flow

```
ACTIVE state, connectOnlyWhenNear=true, autoUnlockEnabled=true:
  BLEPollingEngine: poll RSSI 1s/lần

  setupAutoUnlock combineLatest(RSSI, lockState, autoUnlockEnabled, threshold):
    if RSSI >= autoTurnOnThreshold && lockState == .locked && !isSessionAutoSuspended:
      isSessionAutoSuspended = true  ← phòng re-trigger
      turnOnBike()
      notification "Gần xe, tự động bật xe"

  setupAutoUnlock downgrade logic:
    if RSSI < rssiThreshold-3 && lockState == .locked/.armed && !isSessionAutoSuspended:
      downgradeToStandby()
```

### 6D — One-shot protection (isSessionAutoSuspended)

```
Set khi: auto-unlock fire / user bấm nút bật/tắt thủ công / forceStandby
Effect: block tất cả auto-features (auto-unlock, auto-downgrade)
Reset khi: didDisconnectPeripheral() / startStandbyProximityChecks() (phiên mới)
```

---

## 7. Reconnect & Disconnect Handling

### 7A — Disconnect flow

```
didDisconnectPeripheral(error):
  pollingEngine?.stopPolling()
  isAuthenticating = false
  isSessionAutoSuspended = false  ← RESET phiên cũ
  standbyTimer?.invalidate()

  MIC failure (code 31)? → delegate → didFailToConnect → btWasPoweredOff=true → scan mới
  Code 14 (peer removed)? → savedPeripheralUUID=nil → .error "cần ghép lại"
  
  Thông thường:
    state → .scanning
    central.connect(peripheral, options)  ← Pending connect
    fallback sau 5s: nếu vẫn .scanning →
      cancelPeripheralConnection()
      connect()  ← scan mới
```

### 7B — Pending Connect vs Active Scan

| | Pending Connect | Active Scan |
|---|---|---|
| API | `central.connect(peripheral, ...)` | `central.scanForPeripherals(...)` |
| Timeout | Không có (iOS quản lý) | 4s/lần, max 2 lần |
| Background | ✅ Hoạt động tốt | ❌ Timer bị đóng băng |
| Dùng khi | Biết UUID, disconnect thông thường | UUID stale, lần đầu pair |

### 7C — didFailToConnect (Encryption failure)

```
Encryption/MIC failure sau 5s:
  didFailToConnect:
    btWasPoweredOff = true
    forceFullScan = true
    pendingASKUUID = nil  ← tránh bypass scan
    scanRetryCount = 0
    state → .scanning
    startScanWithTimeout()
```

---

## 8. AccessorySetupKit (ASK) — iOS 18+

### 8A — Flow ghép đôi

```
connectBike() → ASKManager.showPicker()
  iOS hiện system picker UI
  User chọn xe:
    onAccessorySelected(uuid):
      core.initializeBluetoothHardware()
      core.connect(to: uuid)
  User dismiss:
    onPickerDismissed(error?)
```

### 8B — Tại sao trì hoãn init BT trên iOS 18

`CBCentralManager` init khi ASK đang pending có thể conflict với XPC handshake của system picker.

```swift
// initializeHardware():
if #available(iOS 18.0, *) {
    if ask.hasAuthorizedAccessory {
        core.initializeBluetoothHardware()  // Safe
    } else {
        // Defer → init sau khi user bấm "Thêm xe"
    }
}
```

### 8C — pendingASKUUID

ASK confirm UUID có thể đến TRƯỚC khi `CBCentralManager` ready (.poweredOn):
```swift
connect(to: uuid):
  central.state != .poweredOn → pendingASKUUID = uuid

centralManagerDidUpdateState(.poweredOn):
  if let uuid = pendingASKUUID:
    pendingASKUUID = nil
    connect(to: uuid)
```

---

## 9. GATT Queue & I/O Safety

### 9A — Tại sao cần queue

CoreBluetooth không hỗ trợ concurrent GATT operations. Gọi nhiều read/write cùng lúc:
- `CBError: GATT operation already in progress`
- App crash / response mất

```swift
// Mọi I/O phải qua FIFO queue:
let data = try await ctx.queue.enqueue {
    try await ctx.io.readValue(from: char)
}
```

### 9B — I/O Timeout 8 giây

```swift
// Nếu xe không ACK trong 8s → throw IoTError.commandTimeout
// Giải phóng queue cho operations tiếp theo
// Tránh app bị treo hoàn toàn khi firmware không phản hồi
```

---

## 10. Battery Monitoring

BMS data từ xe qua `batteryData` characteristic (JSON):
```json
{"soc": {"soc": 0.67}, "charging_state": 1}
```

| Sự kiện | Notification |
|---------|-------------|
| SOC: X% → 100% | "Pin đã đầy" |
| SOC vượt ngưỡng thấp (default 20%) | "Pin yếu: X%" |
| Mất sạc khi xe tắt | "Cảnh báo ngắt sạc!" |

---

## 11. Cờ trạng thái quan trọng

| Cờ | Ý nghĩa | Set khi | Reset khi |
|----|---------|---------|-----------|
| `btWasPoweredOff` | BT power-cycle → phải scan mới | `centralManagerDidUpdateState(.poweredOff)` | `connect()` dùng xong |
| `forceFullScan` | Peripheral stale → phải scan mới | `willRestoreState` (disconnect), encryption fail | `connect()` dùng xong |
| `isAuthenticating` | Đang auth → không trigger lại | Trước `executeAuthProtocol` | Auth xong / disconnect |
| `isSessionAutoSuspended` | User can thiệp → đình chỉ auto | Auto-unlock fire / nút thủ công | Disconnect vật lý |
| `shouldTurnOnBikeAfterAuth` | Widget "Đánh Thức" → bật sau auth | Widget deep link | Sau khi bật xe |
| `isAppInBackground` | App đang ngầm → dùng pending connect | `appDidEnterBackground` | `appWillEnterForeground` |
| `pendingASKUUID` | ASK UUID đến sớm, BT chưa sẵn | `connect(to:)` khi BT chưa ready | BT poweredOn xử lý |
| `scanRetryCount` | Số lần retry scan (max 2) | Mỗi lần scan fail | Connect thành công / MIC fail |

---

## Appendix: Timeline thực tế

### State Restoration thành công (log 11)
```
08:37:33.854  App launch
08:37:33.897  willRestoreState: peripheral.state=2 → activeContext set
08:37:33.907  State → .standby (hoặc fast-path auth)
08:37:33.956  Auth bắt đầu
08:37:34.841  ✅ Auth thành công
08:37:34.924  State → .active

Tổng: ~1.1 giây
```

### Cold start sau BT power-cycle (log cũ, trước các fix)
```
0s    App launch
+5s   Encryption failure (stale cache)  → scan mới
+18s  Scan timeout × 3 lần (nay: 8s sau fix)
+48s  iOS pending connect
+20s  Standby RSSI wait (nay: nhanh hơn với 0.5s + instant read + fast-path)
+2s   Auth

Tổng: ~91s (ước tính sau fix: 50-60s trong worst case)
```
