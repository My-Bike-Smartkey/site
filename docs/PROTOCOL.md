# Dat Bike Quantum S3 — BLE GATT Protocol Reference

> Nguồn: reverse-engineer từ `btsnoop_hci.log` (commit tham chiếu `64623aa`), đối chiếu với
> `DatBikeSmartkey/BLE/Domain/BLEConstants.swift` và `.agent/workflows/ble-auth-protocol.md`.
> Đây là giao thức đóng của hãng, tài liệu hóa cho mục đích tương thích. Tên handle là offset
> GATT quan sát được; có thể thay đổi theo firmware.

Firmware tham chiếu: **1.10.1+** — các xe Quantum S3.

## 1. Services

| Service | UUID | GATT handles (quan sát) | Vai trò |
|---|---|---|---|
| Scan/Adv | `0000FCF1-0000-1000-8000-00805F9B34FB` | advertisement | UUID quảng bá chính (dùng cho ASK descriptor) |
| Auth | `10CB0217-FF02-4474-A1EF-6FD88B5BDAEA` | 0x00a–0x010 | Xác thực PIN / challenge-response |
| Config | `CF6900A7-4520-4A4C-977C-82979E8BACCF` | 0x011–0x017 | Dashboard, battery log, bike config JSON |
| Main | `D4905F67-8931-4FAA-8C61-86EC7490F3C5` | 0x018–0x03e | Điều khiển xe, trạng thái, lệnh khóa |
| Ext | `5B6D1069-A0BC-4875-BA5B-FDC94647D918` | 0x03f+ | Mở rộng |
| AltScan | `15111100-3023-455B-86CE-615F79EE8ECE` | advertisement | UUID quảng bá thay thế |

App discover `auth → config → main → ext` sau khi connect. Scan lọc theo `auth`/`main`.

Tên quảng bá: prefix `Dat Bike` hoặc `QT_`.

## 2. Characteristics

### Auth service

| UUID (short) | Handle | Thuộc tính | Ý nghĩa |
|---|---|---|---|
| `C8EAF27B` | 0x00c | read/write | **authChallenge** — đọc counter; ghi PIN (pair lần đầu) hoặc hash SHA-256 (reconnect) |
| `C75EBE03` | 0x00e | read/notify | **authResponse** — phản hồi xác thực |
| `91E84EB0` | 0x010 | read/write | **authToken** — session token sau auth |

### Config service

| UUID (short) | Handle | Nội dung |
|---|---|---|
| `6D2EB205` | 0x013 | **dashboardData** — cấu hình + dashboard |
| `84C7BE0B` | — | **batteryData** — log pin, payload JSON |
| `018E6A6F` | — | **bikeConfigJson** — name, model, số khung, firmware, controller, mainPcb (JSON) |

### Main service

| UUID (short) | Handle | Thuộc tính | Ý nghĩa |
|---|---|---|---|
| `88C30D2C` | 0x01a | read | **vehicleStatus** — tên thiết bị (string) |
| `5D681587` | 0x01c | read | **statusFlags** — quan sát `0x08 0x00` |
| `041D5A06` | 0x022 | read | serial (alt) |
| `4AAE98E9` | 0x028 | read | model (alt) |
| `D1DA175E` | 0x02a | read | **fwVersion** — string, ví dụ `"1.10.1"` |
| `44E2BDE6` | 0x02e | rw | **timeSync** — đồng bộ giờ / session token |
| `7F13FE5C` | 0x030 | write | **unlockCmd** — lệnh nguồn xe |
| `87EFAB0D` | 0x032 | rw | **autoUnlock** — proximity token |
| `350D9A82` | 0x034 | write | **findBike** — còi tìm xe |
| `EEC8FD7F` | 0x036 | read/write/notify | **smartkeyEcho** — đọc trạng thái khóa; ghi để arm |
| `73D50009` | 0x03a | read | **commitHash** — commit firmware |
| `69C79762` | — | read | **smartkeyFlag** — `0x01` = SmartKey enabled |

Chuẩn BLE: **serviceChanged** `0x2A05` (handle 0x008).

## 3. Lệnh điều khiển

| Lệnh | Characteristic | Giá trị ghi | Hiệu ứng |
|---|---|---|---|
| Power ON | `unlockCmd` | `0x31` (`'1'`) | Bật xe |
| Power OFF | `unlockCmd` | `0x30` (`'0'`) | Tắt xe |
| Arm (khóa chống trộm) | `smartkeyEcho` | `0x31` | Kích hoạt chống trộm |
| Find bike start | `findBike` | `0x31` | Còi kêu |
| Find bike stop | `findBike` | `0x30` | Tắt còi |

Trạng thái khóa đọc từ `smartkeyEcho` (alias `lockStatus`), payload quan sát được:

| Trạng thái | Payload |
|---|---|
| Locked | `∅`, `0x00`, `0x0000`, `0x30`, `0x3000` |
| Unlocked | `0x02`, `0x0200`, `0x31`, `0x3100` |
| Armed | `0x07`, `0x0700` |

## 4. Luồng xác thực

### 4.1 Pairing lần đầu (plaintext PIN + SMP + NFC)

```
App                     Xe
 │── write PIN (12 chars) ──▶ authChallenge (0x00c)
 │◀───────── SMP pairing request ────────────
 │      (user quẹt thẻ NFC lên xe để chấp nhận bonding)
 │── write sessionToken ────▶ authToken (0x010)
 │── write proximityToken ─▶ autoUnlock (0x032)
 │── enable notify ─────────▶ serviceChanged
```

PIN do app sinh: 12 ký tự (thường + hoa + số + đặc biệt), `SecRandomCopyBytes`. PIN phải khớp lần pair đầu cho mọi lần reconnect sau — đổi PIN đòi hỏi can thiệp firmware.

### 4.2 Reconnect (SHA-256 challenge-response)

```
1. Đọc authChallenge (0x00c) → counter 4 byte little-endian
2. Phán định counter:
   - LẺ  = phiên trước đã xác thực → có thể bỏ qua auth
   - CHẴN = cần xác thực
3. hash = SHA-256( (counter >> 1) || PIN )
4. Ghi hash → authChallenge (0x00c) — ngay lập tức, không delay
5. Đọc lại counter:
   - Chẵn → Lẻ = ✅ thành công
   - Vẫn chẵn  = ❌ thất bại (sai PIN / bonding mismatch)
6. Thành công → sessionToken → proximityToken → notify serviceChanged
```

Timing quan sát được (nằm trong `BLEProtocol`): `authConfirmDelay` 0.12s, `authSessionDelay` 0.5s, `rssiReadInterval` 2.0s, `rssiThreshold` −65 (ngưỡng auth mặc định; ngưỡng auto-bật là cài đặt riêng).

## 5. Lỗi bonding (MIC / code 14)

Khi xe xóa bonding nhưng iOS vẫn giữ LTK: mọi write/read trả MIC failure. iOS **không cho app xóa LTK** — phục hồi buộc phải remove accessory (ASK) hoặc Settings → Bluetooth → Quên thiết bị, rồi pair lại bằng NFC. Xem `ARCHITECTURE_BLE_AND_ASK.md` §6.

## 6. Ghi chú dành cho người triển khai

- Giao thức **không có** cơ chế nhận diện khoảng cách: RSSI là chỉ báo thô, dao động theo môi trường. App dùng EMA + cửa sổ mẫu tươi (xem `ProximitySampleWindow`) — đây là chính sách app, không thuộc giao thức.
- `0x30`/`0x31` là ASCII `'0'`/`'1'` — firmware nhận byte ký tự, không phải giá trị số.
- Payload lock-state có nhiều dạng (rỗng → 2 byte) vì firmware trả độ dài khác nhau theo phiên bản — parse theo bảng ở §3, đừng so khớp 1 giá trị duy nhất.
