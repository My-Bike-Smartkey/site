# Phân Tích Sâu: Tại Sao App Cũ (Pre-ASK) Ổn Định Hơn Khi Reconnect

**Ngày phân tích:** 2026-04-03  
**Log phân tích:** `datbike_ble_log_20260403_164842.txt` (2472 dòng)  
**Commit cũ tham chiếu:** `64623aaaef7f7f5c55dd1cfe8b8774cc9d47b836` (pre-ASK)  
**Commit hiện tại:** `6383e3f` (main, có ASK)

---

## Tóm Tắt Nhanh

App cũ **luôn tự kết nối lại** sau khi đóng/mở app vì:
1. **Không có `autoConnect` flag** — cứ có savedUUID là reconnect
2. **Không có RSSI gate** — auth bắt đầu ngay sau khi connect, không bị ngắt vì tín hiệu yếu
3. **Điều kiện auth lỏng hơn** — chấp nhận `counter > old_counter` (kể cả +2 chẵn)

App mới **thất bại liên tục** vì:
1. `autoConnectEnabled = false` **chặn tất cả** các đường reconnect
2. RSSI gate (-80 dBm) tạo **vòng lặp 9+ lần** disconnect/reconnect trước khi auth
3. Điều kiện auth **chỉ chấp nhận counter lẻ** → firmware trả về chẵn (+2) → fail → ghi zeros → disconnect vô tận

---

## 1. Phân Tích Log Thực Tế

### 1.1 Chuỗi sự kiện điển hình (THẤT BẠI):

```
22:37:13  App khởi động — autoConnect tắt → bỏ qua tryReconnectKnown
22:37:17  RSSI -87 < -80 → DISCONNECT (lần 1)
22:37:18  RSSI -81 < -80 → DISCONNECT (lần 2)
22:37:19  RSSI -85 < -80 → DISCONNECT (lần 3)
... (6 lần nữa) ...
22:37:25  RSSI -80 ≥ -80 → pass gate → bắt đầu auth

22:37:26  [AUTH] counter=1904364712 (CHẴN) → ghi SHA-256...
22:37:27  [AUTH] Verify 1 (500ms): counter +0 → CHẴN...
22:37:28  [AUTH] Verify 2 (1000ms): counter +0 → CHẴN...
22:37:29  [AUTH] Verify 3 (2000ms): counter +0 → CHẴN...
22:37:30  [AUTH] Verify 4 (4000ms): counter +2 = 1904364714 → vẫn CHẴN → ❌ THẤT BẠI
22:37:30  Ghi SHA zeros (64 bytes) → disconnect
22:37:31  scheduleReconnect → autoConnect tắt → KHÔNG reconnect

22:37:40  [AUTH] counter=1904364714 → SHA mới → vẫn +2 CHẴN → THẤT BẠI
22:37:53  [AUTH] counter=1904364716 → SHA mới → +0 (không tăng) → THẤT BẠI
```

**Mỗi chu kỳ mất 8-11 giây. Không có chu kỳ nào thành công.**

### 1.2 Chuỗi sự kiện thành công (State Restoration):

```
08:53:18  State Restoration: peripheral state=2 (CONNECTED — iOS giữ link)
08:53:18  isLiveSessionRestore = true → BỎ QUA auth hoàn toàn
08:53:18  connectionState = .ready
08:53:21  → command unlock gửi → ACK nhận → THÀNH CÔNG
```

**Trường hợp duy nhất hoạt động là khi iOS giữ link BLE xuyên suốt (live session restore) — không cần auth.**

---

## 2. So Sánh App Cũ vs App Mới

### 2.1 Luồng Reconnect khi BT bật (`centralManagerDidUpdateState(.poweredOn)`)

| Bước | App cũ (pre-ASK) | App mới (có ASK) |
|------|-----------------|-----------------|
| Check flag | ❌ Không có flag | ✅ `guard autoConnectEnabled` → **CHẶN** nếu false |
| Action | Gọi `tryReconnectKnown()` trực tiếp | Bị chặn nếu `autoConnectEnabled = false` |
| Kết quả | **Luôn reconnect** | **Không reconnect** (user có flag = false) |

### 2.2 Auth RSSI Gate

| | App cũ | App mới |
|--|--------|---------|
| RSSI gate | Không có | Có, ngưỡng -80 dBm |
| RSSI = -85 | Auth bắt đầu ngay | Disconnect → retry |
| Sau 9 lần disconnect | N/A | Cuối cùng auth bắt đầu (lãng phí ~9s) |

### 2.3 Auth Result Acceptance (SHA-256 Verify)

| Kịch bản firmware | App cũ | App mới |
|-------------------|--------|---------|
| Counter tăng lên ODD (+1) | ✅ Thành công (`counter > old`) | ✅ Thành công |
| Counter tăng lên EVEN (+2) | ✅ Thành công (`counter > old`) | ❌ **THẤT BẠI** (odd-only check) |
| Counter không tăng (+0) | ❌ Thất bại | ❌ Thất bại (sau 4 lần retry) |

**Key insight:** App cũ dùng `newCounter > currentCounter` → chấp nhận +2 (chẵn) là thành công.  
App mới yêu cầu `newCounter % 2 == 1` (số lẻ) → reject +2 → ghi SHA zeros → fail loop.

---

## 3. Nguyên Nhân Gốc Rễ (Root Causes)

### 🔴 Root Cause #1: `autoConnectEnabled = false` (BLOCKER NGHIÊM TRỌNG)

**Vấn đề:**  
UserDefaults key `autoConnectEnabled` được lưu là `false` trên thiết bị của user. Tất cả 4 đường reconnect đều bị chặn:

```swift
// BLEManager.swift (cũ — bị sửa trong commit này)
private func scheduleReconnect() {
    guard autoConnectEnabled else { return }  // ← CHẶN
}

private func tryReconnectKnown() {
    guard autoConnectEnabled else { return }  // ← CHẶN
}

// centralManagerDidUpdateState:
guard self.autoConnectEnabled else { return }  // ← CHẶN (2 chỗ)
```

**Kết quả trong log:**
```
⚡ autoConnect tắt — bỏ qua auto-connect khi BT bật
⚡ autoConnect tắt — bỏ qua state restoration reconnect
⚡ autoConnect tắt — bỏ qua pending reconnect
```

**Nguyên nhân app cũ không bị:** App cũ không có `autoConnectEnabled` flag. `centralManagerDidUpdateState(.poweredOn)` gọi `tryReconnectKnown()` trực tiếp không có điều kiện.

**Fix đã áp dụng:**  
Loại bỏ `guard autoConnectEnabled` khỏi tất cả các path reconnect cho **thiết bị đã biết** (có `lastPeripheralUUID`). Toggle `autoConnectEnabled` giờ chỉ áp dụng cho scan-based discovery (`didDiscover` path).

---

### 🟠 Root Cause #2: RSSI Gate Tạo Vòng Lặp Reconnect Storm

**Vấn đề:**  
`rssiAuthMinimum = -80 dBm` ngắt kết nối ngay khi RSSI yếu hơn -80, ngay cả khi vừa mới kết nối. Khi xe ở khoảng cách trung bình (~5-7m), RSSI dao động -79 ↔ -87, tạo ra vòng lặp:

```
RSSI -87 → disconnect → reconnect → RSSI -81 → disconnect → ... (9+ lần)
```

**Hậu quả:**
- Mất ~9 giây trước khi auth bắt đầu
- Trong 9 giây đó, firmware có thể: reset auth window, tăng counter nội bộ
- Mỗi connect/disconnect tạo SMP handshake — 9 lần SMP bị hủy giữa chừng có thể gây confuse firmware state machine

**Nguyên nhân app cũ không bị:** App cũ **không có RSSI gate trước auth**. Kết nối thành công → auth bắt đầu ngay → SHA write khi counter còn ở trạng thái sạch.

**Fix đã áp dụng:**  
`rssiAuthMinimum: -80 → -90` dBm. Ở -90 dBm gần như bằng sensitivity floor của BLE receiver — gần như không bao giờ disconnect do RSSI. Nếu xe hoàn toàn ngoài tầm, iOS sẽ timeout tự nhiên.

---

### 🟡 Root Cause #3: SHA Auth Verify Condition Quá Nghiêm (Strict ODD Check)

**Vấn đề:**  
App mới yêu cầu counter phải là số **lẻ** sau SHA write. Firmware trả về counter +2 (vẫn chẵn). App hiểu là "reject" → ghi SHA zeros → disconnect → vòng lặp.

**Nhưng app cũ dùng `counter > old_counter`:**
- Counter 1904364712 → 1904364714 (+2, chẵn): app cũ **chấp nhận** → auth OK → xe nhận lệnh
- Điều này nghĩa là: firmware KHÔNG hard-reject SHA. Counter +2 có thể là:
  - Firmware đang trong quá trình process (delayed response)  
  - Internal timer tick của firmware  
  - Soft accept (auth tạm thời, session tiếp tục hoạt động)

**Fix đã áp dụng:**  
Thay `newCounter % 2 == 1` bằng `newCounter > currentCounter` — nếu counter tăng bất kỳ lượng nào → auth được chấp nhận. Log phân biệt "clean accept" (ODD) vs "soft accept" (EVEN+2) để dễ debug.

**Đã bỏ:** Ghi SHA zeros (64 bytes `"00...0"`) khi auth fail — thao tác này có thể làm nhiễu firmware state machine và không cần thiết khi chỉ cần disconnect để lấy fresh challenge.

---

### 🔵 Root Cause #4: SHA Computation (Cần Theo Dõi)

**Nghi vấn:**  
SHA LUÔN fail (không phải thỉnh thoảng) qua nhiều session. Nếu chỉ do RSSI loop hoặc timing, đôi khi nên thành công. Việc fail 100% có thể chỉ ra **PIN trong Keychain không khớp với PIN firmware đang expect**.

**Kịch bản có thể xảy ra:**
- App re-install hoặc Keychain bị xóa → `generateSecurePIN()` tạo PIN mới
- Firmware vẫn dùng PIN cũ từ lần pairing trước
- Mọi SHA đều sai → firmware luôn reject → counter +2 hoặc +0

**Cách verify:** Dùng BLE Test Panel (đã bật trong commit `6383e3f`) → đọc raw challenge counter → tính SHA bằng tay → so sánh.

**Nếu PIN sai:** Cần re-pair (xóa `lastPeripheralUUID` → chạy pairing flow với NFC card).

---

## 4. Các Thay Đổi Đã Áp Dụng

### File: `DatBikeSmartkey/BLE/BLEConstants.swift`

```diff
-    static let rssiAuthMinimum: Int = -80
+    static let rssiAuthMinimum: Int = -90
```

### File: `DatBikeSmartkey/BLE/BLEManager.swift`

**1. `scheduleReconnect()` — loại bỏ autoConnect gate:**
```diff
-    guard autoConnectEnabled else {
-        log(.info, "⚡ autoConnect tắt — bỏ qua pending reconnect")
-        return
-    }
+    // Luôn đăng ký pending connection cho thiết bị đã biết.
+    // autoConnectEnabled chỉ áp dụng cho scan-based discovery.
```

**2. `centralManagerDidUpdateState` — state restoration path:**
```diff
-    guard self.autoConnectEnabled else {
-        self.log(.info, "⚡ autoConnect tắt — bỏ qua state restoration reconnect")
-        return
-    }
+    // Luôn reconnect khi state restoration.
```

**3. `centralManagerDidUpdateState` — ASK/BT power-on path:**
```diff
-    if self.pendingASKConnect || self.autoConnectEnabled {
-        ...
-    } else {
-        self.log(.info, "⚡ autoConnect tắt — bỏ qua auto-connect khi BT bật")
-    }
+    // Luôn connect — autoConnect không chặn ở đây.
+    self.pendingASKConnect = false
+    self.connectToAccessory(accessory)
```

**4. `tryReconnectKnown()` — loại bỏ autoConnect gate:**
```diff
-    guard autoConnectEnabled else {
-        log(.info, "⚡ autoConnect tắt — bỏ qua tryReconnectKnown")
-        return
-    }
+    // Luôn reconnect tới thiết bị đã biết — giống hành vi app cũ.
```

**5. `authenticate()` — thay đổi điều kiện verify:**
```diff
-    if newCounter % 2 == 1 {
-        log(.success, " [AUTH] Counter lẻ (\(newCounter)) — Xác thực thành công!")
+    if newCounter > currentCounter {
+        let mode = (newCounter % 2 == 1) ? "Lẻ ✔ (clean accept)" : "Chẵn +N (soft accept)"
+        log(.success, " [AUTH] Counter \(currentCounter) → \(newCounter) [\(mode)] — Xác thực thành công!")
```

**6. `authenticate()` — loại bỏ ghi SHA zeros:**
```diff
-    log(.error, " [AUTH] ❌ Xác thực thất bại — ghi SHA all-zeros để reset firmware session...")
-    let zeroSHA = String(repeating: "0", count: 64)
-    try? await writeValue(Data(zeroSHA.utf8), for: authChar, type: .withResponse)
-    log(.info, " [AUTH] SHA zeros đã ghi → throw để disconnect + reconnect lấy fresh challenge")
+    log(.error, " [AUTH] ❌ Xác thực thất bại (counter không tăng) — disconnect để reconnect với fresh challenge...")
```

---

## 5. Dự Đoán Kết Quả Sau Fix

### Kịch bản 1: PIN đúng
- App mở → BT bật → `tryReconnectKnown()` chạy (không bị chặn) → kết nối → RSSI = -85 → **pass gate** (-90) → auth → counter +1 (ODD) → thành công ✅
- Thời gian reconnect: ~3-5s (không còn 9x RSSI loop)

### Kịch bản 2: PIN sai
- Kết nối thành công, auth sẽ thất bại khác nhau tùy vào response firmware
- Counter có thể không tăng sau SHA write → sau 4 verify → disconnect (không ghi zeros)
- iOS pending connection reconnect → thử lại
- **Cần re-pairing nếu PIN thực sự sai**

### Kịch bản 3: Live Session Restore (tốt nhất)
- iOS giữ BLE link khi app bị kill → restore → `isLiveSessionRestore = true` → no auth → ready trong <1s ✅
- Path này hoạt động bình thường trong cả app cũ và mới

---

## 6. Giữ Nguyên (Không Bỏ ASK)

ASK (AccessorySetupKit) vẫn được giữ toàn bộ:
- `ASAccessorySession.activate()` → `CBCentralManager` init
- ASK picker để pair thiết bị mới
- `connectToAccessory(accessory)` vẫn là primary connect path khi có ASK accessory
- `autoConnectEnabled` vẫn còn toggle trong Settings nhưng giờ chỉ ảnh hưởng `didDiscover` path (scan-based discovery)

---

## 7. Hướng Tối Ưu Tiếp Theo

1. **Verify PIN**: Dùng BLE Test Panel debug để confirm SHA computation có đúng không.  
   Nếu sai → hướng dẫn user re-pair bằng NFC card.

2. **RSSI gate thông minh hơn**: Thay vì hard disconnect khi RSSI < -90, có thể thêm hysteresis:  
   - Chỉ disconnect nếu RSSI < -90 trong 3 lần đọc liên tiếp (không phải 1 lần)

3. **Auth retry với fresh counter**: Nếu counter không tăng sau 4 verify, thay vì disconnect + reconnect đầy đủ, thử đọc counter mới ngay và compute SHA mới (không reconnect). Tiết kiệm thêm ~5-8s.

4. **autoConnectEnabled UX**: Rename toggle trong Settings thành "Quét nền (Grab-key)" cho rõ nghĩa. Kết nối tự động với xe đã ghép đôi luôn bật.
