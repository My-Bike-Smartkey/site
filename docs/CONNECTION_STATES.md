# DatBike Smartkey — Tài liệu Trạng thái Kết nối

> **Phiên bản:** 4.2.2 · **File tham chiếu:** `IoTTypedModels.swift`, `DatBikeCore.swift`

---

## Tổng quan: 2 Tầng Kết nối

Trước khi đọc từng trạng thái, cần nắm rõ có **2 tầng kết nối riêng biệt** hoạt động độc lập:

| Tầng | Đại diện | Mô tả |
|---|---|---|
| **Tầng Hệ thống iOS** | `CBPeripheral.state` | iOS quản lý. Hiển thị trong Cài đặt Bluetooth. Giá trị: `disconnected(0)`, `connecting(1)`, `connected(2)`, `disconnecting(3)` |
| **Tầng Ứng dụng** | `IoTConnectionState` | App quản lý thông qua State Machine. Đây là trạng thái hiển thị trên UI. |

> **Điểm then chốt:** Xe có thể đang `connected` ở tầng iOS nhưng App vẫn ở trạng thái `scanning` hoặc `standby` vì chưa hoàn thành xác thực SHA-256.

---

## Sơ đồ State Machine

```
                    ┌─────────────────────────────────────────────┐
         Launch /   │                                             │
       Terminated   │                                             ▼
                    │                                          [IDLE]
                    │                                             │
                    │                               Có savedPin/UUID?
                    │                           ┌─────────────────┴────────────────┐
                    │                          YES                                  NO
                    │                           │                                   │
                    │                           ▼                                   ▼
                    │                      [SCANNING]  ◄───────────────────   (Yêu cầu ghép đôi)
                    │                           │
                    │                  Tìm thấy xe BLE?
                    │                           │
                    │                           ▼
                    │                      [CONNECTING]
                    │               (Hệ thống iOS đang kết nối)
                    │                           │
                    │                    didConnect xảy ra?
                    │                     ┌─────┴─────┐
                    │                    YES          TIMEOUT 5s
                    │                     │               │
                    │                     │         cancel + scan lại
                    │                     ▼
                    │              Kiểm tra SHA Counter
                    │              ┌──────┴──────┐
                    │           Counter LẺ    Counter CHẴN
                    │           (Phiên cũ)    (Phiên mới)
                    │               │              │
                    │               ▼              ▼
                    │            [ACTIVE]      [STANDBY]
                    │        (Bỏ qua auth)    (Chờ lại gần)
                    │                              │
                    │                    RSSI đạt ngưỡng (-70 dBm)?
                    │                              │
                    │                              ▼
                    │                       [AUTHENTICATING]
                    │                    (SHA-256 Challenge/Response)
                    │                              │
                    │                       Auth thành công?
                    │                    ┌─────────┴────────┐
                    │                  YES                  NO
                    │                    │                   │
                    │                    ▼                  error
                    │                 [ACTIVE] ─────────────┘
                    │                    │
                    │             Mất kết nối vật lý?
                    └────────────────────┘ (quay lại SCANNING)
```

---

## Chi tiết từng trạng thái

---

### 1. `idle` — Chưa kết nối (Idle)

**Ý nghĩa:**
Trạng thái khởi đầu. App chưa thực hiện bất kỳ hành động BLE nào, hoặc vừa mới load xong sau khi bị kill.

**BLE Layer (`CBPeripheral.state`):** N/A — không có peripheral nào

**App Layer:** `IoTConnectionState.idle`

**Điều kiện chuyển:**
- → `scanning`: Khi `connect()` được gọi và chưa có savedPin/UUID (lần đầu dùng), hoặc không tìm được peripheral trong cache iOS.
- → `connecting`: Khi `connect()` được gọi và tìm thấy peripheral trong cache iOS.

**Foreground:** Hiển thị màn hình chờ / nút "Kết nối xe".

**Background:** iOS không thể ở trạng thái này khi app chạy ngầm; AppDelegate sẽ gọi `initializeBluetoothHardware()` ngay khi launch.

**Log cần tìm:**
```
State transitioned to: Chưa kết nối (Idle)
[INIT] Khởi tạo CBCentralManager | savedUUID=...
```

---

### 2. `scanning` — Đang quét tìm xe...

**Ý nghĩa:**
App đang kích hoạt bộ phát sóng BLE để tìm kiếm xe DatBike trong vùng phủ sóng.

**BLE Layer:** `CBCentralManager.scanForPeripherals()` đang chạy

**App Layer:** `IoTConnectionState.scanning`

**Cơ chế chi tiết:**
1. App gọi `startScanWithTimeout(central:)`.
2. iOS quét và gọi callback `didDiscoverPeripheral` cho mỗi thiết bị tìm thấy.
3. Timer `scanTimeoutSeconds = 4s` được bắt đầu đồng thời.
4. Nếu hết 4s không thấy xe → thử lại `retry 1/2` với `allowDuplicates=true`.
5. Sau 2 lần thử hết → chuyển sang "bám sóng nền" (pending connect với cache).

**Điều kiện chuyển:**
- → `connecting`: Tìm thấy xe (`didDiscoverPeripheral`) và gọi `connectPeripheral()`.
- → `idle`/`error`: Bluetooth tắt hoặc chưa cấp quyền.

**Foreground:** Hiển thị spinner "Đang quét tìm xe...".

**Background:** App ở background có thể scan nhưng iOS **giới hạn nghiêm ngặt**:
- Chỉ scan được khi dùng đúng Service UUIDs (không dùng `nil` wildcard).
- Scan tự động dừng sau một thời gian ngắn nếu không tìm thấy.
- `allowDuplicates=true` **không hoạt động** trong background.

**Cờ đặc biệt:**
- `btWasPoweredOff = true`: Bắt buộc scan mới, KHÔNG dùng cache (tránh MIC Failure).
- `forceFullScan = true`: Peripheral bị coi là stale sau State Restoration, bắt buộc scan mới.

**Log cần tìm:**
```
[SCAN] Bắt đầu quét | retry=0/2 | allowDupes=false | timeout=4.0s | btPowerOff=false
[SCAN] Bắt đầu quét | retry=1/2 | allowDupes=true | timeout=4.0s ...
[WARNING] Hết hạn quét xe — chuyển sang bám sóng nền (pending connect)
```

---

### 3. `connecting` — Hệ thống đang kết nối...

**Ý nghĩa:**
App đã ra lệnh kết nối (`CBCentralManager.connect()`) và đang chờ iOS thiết lập kết nối vật lý ở tầng BLE Link Layer. **Giai đoạn này hoàn toàn do iOS kiểm soát.**

**BLE Layer:** `CBPeripheral.state = .connecting (1)`

**App Layer:** `IoTConnectionState.connecting`

**Cơ chế chi tiết:**
1. `connectPeripheral(_:central:)` được gọi.
2. App tạo `BLEConnectionContext`, gán `peripheral.delegate = self`.
3. `CBCentralManager.connect(peripheral, options:)` được gọi.
4. **Phantom Guard (5.0s)** bắt đầu đếm ngược.
5. iOS thực hiện:
   - Trao đổi gói tin BLE Advertisement/Response.
   - Thiết lập link-layer encryption (nếu đã pair).
   - Gọi `centralManager(_:didConnect:)` khi thành công.

> **Tại sao 5.0 giây?** iOS mất tới 3–5 giây để đánh thức thiết bị từ Deep Sleep và hoàn tất BLE Link Layer negotiation. Phantom Guard 5.0s cho phép quá trình này hoàn thành tự nhiên mà không bị app cắt ngang.

**Phantom Guard — Cơ chế chống treo:**
Nếu sau 5.0s không có `didConnect`, đây là "phantom connection" (kết nối ảo từ cache iOS nhưng xe thực tế đã mất). Guard sẽ:
1. `cancelPeripheralConnection()` — hủy lệnh kết nối.
2. Xóa `activeContext`.
3. Đặt `forceFullScan = true`.
4. Gọi `connect()` → quay về `scanning`.

**Điều kiện chuyển:**
- → `standby` hoặc `authenticating`: `didConnect` thành công, kiểm tra SHA counter.
- → `scanning`: Phantom Guard timeout 5.0s.

**Foreground:** Spinner "Hệ thống đang kết nối...".

**Background:** App vẫn nhận callback `didConnect` khi ở background. iOS đảm bảo điều này để hỗ trợ State Restoration.

**Log cần tìm:**
```
[CONNECT_PERIPHERAL] name=Ngựa sắt | uuid=7D2F7D10 | peripheralState=0 | centralState=5
[PHANTOM_GUARD] Bắt đầu connecting timeout 5.0s | peripheral=7D2F7D10 | peripheralState=1
[SUCCESS] [DID_CONNECT] name=Ngựa sắt | ...
[PHANTOM_GUARD] Timeout 5.0s! Peripheral stale | ... → hủy + scan mới
```

---

### 4. `standby` — Kết nối ngầm (Chờ lại gần)

**Ý nghĩa:**
Kết nối BLE đã được thiết lập thành công ở tầng vật lý (iOS), **nhưng App chưa xác thực**. Đây là trạng thái "giữ chỗ" an toàn khi xe ở xa (RSSI thấp hơn ngưỡng).

**BLE Layer:** `CBPeripheral.state = .connected (2)`

**App Layer:** `IoTConnectionState.standby`

**Điều kiện vào:**
- Sau `didConnect` thành công, kiểm tra SHA Counter → **Counter chẵn** (phiên auth đã hết, cần xác thực lại).
- Setting "Chỉ kết nối khi gần" đang BẬT.
- Người dùng ấn nút "Ngắt kết nối" (Standby thủ công).

**Cơ chế Proximity Monitor:**
- Timer 2s đọc RSSI liên tục.
- Nếu `RSSI >= rssiThreshold (-70 dBm)` → chuyển sang `authenticating`.
- Log mỗi lần check: `Standby chờ gần: RSSI=-79 / Ngưỡng=-70.0`

**Điều kiện chuyển:**
- → `authenticating`: RSSI đạt ngưỡng, bắt đầu xác thực SHA-256.
- → `scanning`: Mất kết nối vật lý (`didDisconnect`).
- → `active`: Người dùng ấn "Đánh thức xe" (forceAuthenticate).

**Foreground:** Badge "Kết nối ngầm · Chờ lại gần", nút "Đánh thức xe" hiển thị.

**Background:** App vẫn theo dõi RSSI qua BLE Notify. Khi RSSI đạt ngưỡng, sẽ tự động kích hoạt auth. Không hiện thị UI.

**Log cần tìm:**
```
State transitioned to: Kết nối ngầm (Chờ lại gần)
Standby chờ gần: RSSI=-79 / Ngưỡng=-70.0
[STANDBY_CHECK] Bắt đầu | peripheral=... | rssiThreshold=-70.0 | autoUnlock=false
```

---

### 5. `authenticating` — App đang xác thực...

**Ý nghĩa:**
App đang thực hiện giao thức xác thực **SHA-256 Challenge/Response** với firmware xe. Đây là bước bảo mật bắt buộc trước khi có thể gửi lệnh điều khiển.

**BLE Layer:** `CBPeripheral.state = .connected (2)`, đang read/write GATT Characteristics.

**App Layer:** `IoTConnectionState.authenticating`

**Quy trình SHA-256 (chi tiết):**
1. App đọc characteristic `authChallenge` → nhận về **Counter (4 bytes, little-endian)**.
2. App tính `HMAC-SHA256(key=PIN, data=counter_bytes)`.
3. App ghi hash 64 hex chars vào `authChallenge`.
4. App poll counter, chờ **Counter tăng lên 1 và trở thành số LẺ** (xác nhận firmware đã xác thực thành công).
5. App đồng bộ thời gian (ghi timestamp hiện tại).

**Fast-Path (Skip Auth):**
- Nếu session cũ vẫn còn (Counter LẺ), App bỏ qua toàn bộ bước này và nhảy thẳng vào `active`.
- Giảm thời gian kết nối từ ~2s xuống còn <0.5s.

**Điều kiện chuyển:**
- → `active`: SHA counter chuyển LẺ thành công.
- → `standby` + retry: Auth thất bại (counter không thay đổi sau 4 vòng polling).
- → `scanning` + retry: GATT timeout, không đọc được characteristic.

**Foreground:** Spinner "App đang xác thực...", UI bị khóa.

**Background:** Auth vẫn chạy được trong background nhờ `UIBackgroundTask` để tranh thủ CPU time. Nếu hết CPU time background trước khi auth xong → kết nối thất bại.

**Log cần tìm:**
```
State transitioned to: App đang xác thực...
[AUTH] Bắt đầu | peripheral=7D2F7D10 | isKnown=true | pinLen=12
[SHA] Challenge nhận được | counter=1462380600 | isEven=true | rawHex=38282a57
[SHA] Hash tính xong | hashPrefix=dbc9bd9f... | hashLen=64
[SHA] Verify vòng 1/4 | counter=1462380601 | isOdd=true | delta=1 | delay=200ms
[SUCCESS] [SHA] Counter chuyển lẻ → auth thành công ✅ | counter=1462380601
```

---

### 6. `active` — Đã kết nối (Active Session)

**Ý nghĩa:**
Trạng thái hoạt động đầy đủ. App đã xác thực xong, có toàn quyền gửi lệnh điều khiển xe (bật/tắt, chống trộm, tìm xe) và đọc dữ liệu telemetry.

**BLE Layer:** `CBPeripheral.state = .connected (2)`, GATT subscriptions đang hoạt động.

**App Layer:** `IoTConnectionState.active`

**Các tác vụ đang chạy song song:**
| Tác vụ | Chu kỳ | Mô tả |
|---|---|---|
| RSSI Poll | 2s | Cập nhật cường độ tín hiệu |
| LockStatus Notify | Realtime | Nhận ngay khi xe thay đổi trạng thái |
| Telemetry Poll | 30s | Cập nhật tốc độ, nhiệt độ, ODO |
| BMS Poll | 60s | Cập nhật trạng thái pin |
| Time Sync | 1 lần/ngày | Đồng bộ giờ xe với điện thoại |
| Widget Sync | 400ms debounce | Cập nhật Widget sau mỗi thay đổi trạng thái |

**Điều kiện chuyển:**
- → `scanning`: Mất kết nối vật lý (`didDisconnect`) với error code 6 (timeout).
- → `standby`: Người dùng ấn "Ngắt kết nối" thủ công, hoặc app chuyển background với setting "Chỉ kết nối khi gần".

**Foreground:** UI hoạt động đầy đủ. Nút Bật/Tắt xe, Chống trộm, Tìm xe đều enabled.

**Background:**
- App vẫn nhận BLE Notify qua `isAppInBackground = true`.
- `Live Activity` được cập nhật trạng thái trên màn hình khóa.
- Widget được reload qua `WidgetCenter.shared.reloadAllTimelines()`.
- **Không gọi Live Activity khi background** (tránh lỗi "Target is not foreground").

**Log cần tìm:**
```
State transitioned to: Đã kết nối (Active Session)
[SUCCESS] Xác thực: Phiên làm việc sẵn sàng ✅
Xe: Ngựa sắt / QT_S3 / RL9C4MJSSRCC00667 / FW: ...
[BLE Notify] Trang thai xe thay doi: Đã tắt/khoá
```

---

### 7. `pairingRequired` — Chờ xác thực bảo mật...

**Ý nghĩa:**
Trạng thái chờ đặc biệt: App cần người dùng nhập mã PIN hoặc xác thực qua thẻ NFC để hoàn tất ghép đôi. Chỉ xuất hiện trong lần đầu thiết lập hoặc khi PIN bị xóa.

**BLE Layer:** `CBPeripheral.state = .connected (2)` hoặc chưa kết nối.

**App Layer:** `IoTConnectionState.pairingRequired`

**Điều kiện vào:**
- Không có `savedPin` trong Keychain.
- Người dùng chưa hoàn thành luồng ghép đôi ASK (AccessorySetupKit).

**Điều kiện chuyển:**
- → `authenticating`: Sau khi người dùng nhập PIN thành công.
- → `idle`: Hủy ghép đôi.

**Foreground:** Hiển thị màn hình nhập PIN.

**Background:** Không xảy ra trong background.

---

### 8. `error(String)` — Lỗi kết nối

**Ý nghĩa:**
Kết nối thất bại không thể tự phục hồi. Message lỗi được đóng gói trong associated value.

**Các loại lỗi phổ biến:**

| Lỗi | Nguyên nhân | Hành động |
|---|---|---|
| `Bluetooth đang tắt` | `CBManagerState.poweredOff` | Hiển thị alert, chờ user bật lại |
| `Chưa cấp quyền Bluetooth` | `CBManagerState.unauthorized` | Mở Settings |
| `Thiết bị không hỗ trợ BLE` | `CBManagerState.unsupported` | Thông báo lỗi cứng |
| MIC/Encryption failure | Code 15, `CBErrorDomain` | Tự động retry tối đa 3 lần với full scan |
| Connection timeout | Code 6, "timed out" | Coi như MIC failure, retry với full scan |

**Cơ chế MIC Retry:**
```
MIC Failure lần 1 → forceFullScan=true, btWasPoweredOff=true → delay 1s → scan mới
MIC Failure lần 2 → như lần 1
MIC Failure lần 3 → transition to .error("Lỗi mã hóa, vui lòng thử lại")
```

---

## Lifecycle: Foreground vs Background

### Khởi động bình thường (Foreground)

```
1. AppDelegate.didFinishLaunchingWithOptions → DatBikeCore.initializeBluetoothHardware()
2. CBCentralManager init với RestoreIdentifierKey
3. centralManagerDidUpdateState(.poweredOn)
4. DatBikeCore.connect() → idle → scanning → connecting → standby/active
```

### Khởi động lại từ Background (iOS State Restoration)

```
1. iOS relaunch app trong background khi phát hiện tín hiệu BLE
2. AppDelegate.didFinishLaunchingWithOptions với launchOptions chứa BLE key
3. CBCentralManager.willRestoreState được gọi trước didUpdateState
4. App nhận lại peripheral đã kết nối từ iOS (state=1 hoặc 2)
5. Nếu peripheral.state==2 → skip scan, auth luôn
6. Nếu peripheral.state==1 → coi là stale, scan mới để tránh MIC
```

### App bị vuốt tắt (Terminated) rồi xe lại gần

```
1. iOS phát hiện BLE advertisement khớp với RestoreIdentifierKey
2. iOS tự động relaunch app trong background (isBackground=true)
3. Toàn bộ quy trình State Restoration chạy như trên
4. Nếu auth thành công → app ở active trong background, không có UI
```

### App ở Background, xe mất kết nối rồi quay lại

```
1. didDisconnect → transition to scanning
2. connect() → retrieveConnectedPeripherals (xe đã kết nối ở iOS?) → kết nối nhanh
3. hoặc → scan → discover → connect
4. auth → active
5. Widget + Live Activity được cập nhật
```

---

## Cờ trạng thái nội bộ (Internal Flags)

| Cờ | Mô tả | Khi nào bật | Khi nào tắt |
|---|---|---|---|
| `btWasPoweredOff` | BT vừa trải qua poweredOff→poweredOn | `centralManagerDidUpdateState(.poweredOff)` | Khi `connect()` thực sự scan mới |
| `forceFullScan` | Peripheral stale, bắt buộc scan mới | Phantom Guard timeout, State Restoration disconnect | Khi scan mới bắt đầu |
| `isSessionAutoSuspended` | Auto-features bị đình chỉ bởi user action | Bất kỳ thao tác thủ công nào | Khi mất kết nối vật lý |
| `isAuthenticating` | Auth đang chạy, tránh auth kép | Khi SHA auth bắt đầu | Khi auth hoàn thành hoặc thất bại |
| `isAppInBackground` | App đang ở background | `appDidEnterBackground` | `appWillEnterForeground` |
| `isDowngrading` | Tránh `downgradeToStandby` chạy trùng | Khi downgrade bắt đầu | Khi downgrade xong |

---

## Hướng dẫn Debug Log

### Đọc log theo dòng thời gian

Mỗi dòng log có format:
```
YYYY-MM-DD HH:mm:ss.SSS [LEVEL] [TAG] message | key1=val1 | key2=val2
```

**LEVEL:** `[INFO]`, `[SUCCESS]`, `[WARNING]`, `[ERROR]`

**TAG quan trọng:**
| Tag | Ý nghĩa |
|---|---|
| `[UI ACTION]` | Người dùng bấm nút gì |
| `[APP_LAUNCH]` | App khởi động (foreground/background) |
| `[RESTORE]` | State Restoration từ iOS |
| `[CONNECT]` | Hàm `connect()` được gọi |
| `[SCAN]` | Bắt đầu quét BLE |
| `[CONNECT_PERIPHERAL]` | Bắt đầu kết nối thiết bị cụ thể |
| `[PHANTOM_GUARD]` | Timer bảo vệ kết nối ảo |
| `[DID_CONNECT]` / `[DID_DISCONNECT]` | Sự kiện BLE từ iOS |
| `[GATT]` | Discover services/characteristics |
| `[SESSION_CHECK]` | Kiểm tra SHA counter |
| `[AUTH]` | Luồng xác thực |
| `[SHA]` | Chi tiết từng bước SHA-256 |
| `[LIFECYCLE]` | Foreground/Background transitions |

### Các mẫu log báo hiệu vấn đề

**Lỗi Phantom Guard lặp lại:**
```
[PHANTOM_GUARD] Timeout 5.0s! → scan mới
...
[PHANTOM_GUARD] Timeout 5.0s! → scan mới   ← LOOP
```
*Nguyên nhân:* RSSI quá yếu, xe đang ở trạng thái deep sleep khó đánh thức.

**MIC Failure:**
```
[ERROR] [DID_FAIL_CONNECT] error=Failed to encrypt... code=15 | micRetry=0/3
[WARNING] Encryption failure (lần 1/3) → delay 1s rồi scan mới
```
*Nguyên nhân:* iOS giữ encryption key cũ nhưng xe đã reset. Cần scan mới để negotiate fresh key.

**Session bị kick về Standby:**
```
[SESSION_CHECK] counter=1462380598 | isOdd=false → INACTIVE
[RESTORE] Phiên auth đã hết (counter chẵn) → vào standby + auth lại
```
*Nguyên nhân:* Bình thường — phiên cũ đã hết (firmware reset counter về chẵn sau khi tắt).

**Auth thành công:**
```
[SUCCESS] [SHA] Counter chuyển lẻ → auth thành công ✅ | counter=1462380601
[SUCCESS] Xác thực: Phiên làm việc sẵn sàng ✅
State transitioned to: Đã kết nối (Active Session)
```
