---
description: Dat Bike BLE Authentication Protocol — SHA-256 Challenge/Response
---

# Dat Bike BLE Authentication Protocol

## Overview
Xe Dat Bike (Quantum S3) sử dụng SHA-256 challenge/response để xác thực app sau khi kết nối BLE.
Characteristic: `authChallenge` (UUID: `DE77B250-...`)

## Luồng xác thực (Reconnect Flow)

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
- Retry tối đa 4 lần với delay tăng dần: 400ms, 700ms, 1200ms, 2000ms
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

## Lưu ý
- PIN được lưu vào `PreferencesManager.savedPin` sau lần pair đầu tiên
- Nếu PIN bị ghi đè (ví dụ app resume) → SHA hash sai → auth fail
- MIC failure (code 31) → cần scan lại, không dùng cached peripheral
