# Dat Bike Smartkey - Kết Cấu Hashing Của Luồng Reconnect

Dựa trên việc dịch ngược mã máy Hermes Bytecode (React Native iOS/Android v0.70+) thành công bằng môi trường `venv`, tôi đã vạch trần được ĐÚNG CÔNG THỨC MÃ HÓA (Hashing Formula) dùng để âm thầm kết nối lại xe mà không cần thẻ NFC!

## 🎯 Luồng Reconnect (Kết Nối Lại Sau Khi Tắt App)
Thay vì gửi thẳng mã PIN `0978797135` ở lần reconnect (việc gây ra đòi thẻ NFC), App gốc thực hiện cơ chế **Challenge-Response ngầm** sử dụng mã băm `SHA-256`.

### Công Thức Bí Mật (Theo JS Bytecode)
Phân tích tại `module 2130` của file `index.android.bundle`, logic tính toán như sau:

```javascript
// Trích xuất từ mã dịch ngược Assembler của bundle_out
657333:                         r9 = r3.readUInt32LE;
657334:                         r9 = r9.bind(r3)();
657335:                         r13 = 1;
657336:                         r9 = r9 >>> r13; // Dịch phải 1 bit (Logical Right Shift)
...
657343:                         r9 = r9 + r5;    // Cộng chuỗi với PIN Code
657344:                         r9 = r10.bind(r4)(r9); // Hàm SHA-256
```

**Diễn giải logic ra ngôn ngữ lập trình bình thường:**
1. **Lấy Challenge:** Đọc 4-bytes từ `0x000C` (VD: `ee9dac1f`).
2. **Ép kiểu:** Chuyển 4-bytes đó thành mảng số nguyên không dấu 32-bit (Unsigned 32-bit Integer - Little Endian).
   - Với `ee9dac1f` -> Số nguyên là `0x1fac9dee` (hệ thập phân: `531406318`).
3. **Dịch Bit (Toán tử `>>> 1`):** Dịch phải một bit của số nguyên trên (Thực chất là chia 2 và bỏ phần dư).
   - `531406318 >>> 1` = `265703159`.
4. **Nối Chuỗi (Concat):** Do `r9` là số nguyên và `r5` (tham số truyền vào hàm, chính là chuỗi `PIN`), phép `+` trong JavaScript sẽ ép kiểu thành chuỗi.
   - Kết quả: `String(265703159) + "0978797135"` = `"2657031590978797135"`.
5. **Băm kết quả (SHA-256):** Đưa chuỗi trên qua thuật toán SHA-256. Quá trình này sẽ sinh ra đúng 64-ky-tự hex: `cf66*`.

### Kiểm chứng lại thực tế:
Tôi đã viết code test (Python) chạy lại với số liệu từ btsnoop log trước đó:

*   **Cycle 2 (btsnoop):**
    *   Challenge đọc được: `ee9dac1f`
    *   Chuỗi tạo ra: `"2657031590978797135"`
    *   SHA-256 Code: `cf663ef84eac4b9fa3668023eaeb...` **(MATCH 100% HOÀN TOÀN ✅)**
*   **Cycle 3 (btsnoop):**
    *   Challenge đọc được: `f29dac1f`
    *   Chuỗi tạo ra: `"2657031610978797135"`
    *   SHA-256 Code: `035c2691d5748a4feb38b6fb956bc...` **(MATCH 100% HOÀN TOÀN ✅)**

## 🚀 Kế hoạch Triển khai lên App iOS (`BLEManager.swift`)

Bây giờ công thức SHA-256 bí mật đã được lôi ra ánh sáng, sự phụ thuộc vào thẻ NFC ở app "Độ" xem như biến mất!

Kế hoạch điều chỉnh tiếp theo:
1.  Kéo thư viện `CryptoKit` của iOS vào `BLEManager.swift`.
2.  Bắt đặc tính đọc `0x000C` ở giai đoạn Reconnect. Khi Challenge ngẫu nhiên bay về, ép kiểu 4 bytes -> dịch phải 1 -> Nối chuỗi -> Băm SHA256 -> Ghi `0x000C`.
3.  Tích hợp biến trạng thái `isKnownDevice` (xe đã kết nối 1 lần chưa) để quyết định xem xe cần gửi thẳng mã Auth cũ (Pairing thủ công) hay dùng công thức Hash mới này (để âm thầm kết nối lại không hỏi lần 2).
