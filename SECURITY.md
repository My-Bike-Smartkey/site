# Security Policy / Chính sách bảo mật

## Ngôn ngữ / Languages: Tiếng Việt (dưới đây) — English summary at the end

## Phạm vi

D-SmartKey là ứng dụng smartkey BLE cho xe Dat Bike, giao tiếp trực tiếp với firmware xe qua GATT. Bảo mật của dự án gồm hai lớp:

1. **Bảo mật ứng dụng** — xử lý PIN, lưu trữ cục bộ, log.
2. **Bảo mật giao thức** — mô hình challenge-response SHA-256 được reverse-engineer từ firmware gốc.

## Báo cáo lỗ hổng (Responsible disclosure)

- Mở issue **không công khai chi tiết khai thác**; mô tả tóm tắt và chờ phản hồi.
- Không thử khai thác trên xe của người khác.
- Cho maintainer thời gian phản hồi trước khi công bố.

## Những gì bảo mật hiện tại / What is secured today

- PIN 12 ký tự sinh bằng `SecRandomCopyBytes` (xem `BLEConstants.generateSecurePIN()`).
- Auth reconnect dùng hash SHA-256 theo counter — không gửi PIN trực tiếp sau lần pair đầu.
- Pairing lần đầu đi qua SMP bonding của iOS (LE Secure Connections tùy firmware xe).
- Bonding do iOS quản lý; ứng dụng không thể đọc LTK.

## Giới hạn đã biết / Known limits (đọc kỹ trước khi đánh giá)

- **Mã hóa giao thức do firmware xe quyết định** — đây là giao thức đóng của hãng, không phải thiết kế do dự án này chọn. Nếu firmware dùng SMP legacy pairing, mức bảo mật liên kết phụ thuộc chính sách đó.
- **Log BLE có thể chứa** UUID thiết bị, timestamp, giá trị RSSI. File `datbike_ble_logs.txt` (nếu có trong máy bạn) là dữ liệu cục bộ, đã được thêm vào `.gitignore` — **không commit** file log này.
- **PIN lưu cục bộ trên thiết bị người dùng** để auto-reconnect; mức bảo mật phụ thuộc sandbox iOS. Đây là đánh đổi bắt buộc của giao thức hãng (xe yêu cầu PIN cho mỗi challenge).

## English summary

Report vulnerabilities privately via a non-detailed issue; do not exploit on other people's bikes. The wire protocol is the vendor's closed design (SHA-256 challenge-response over GATT); link encryption depends on the bike firmware's SMP policy. BLE logs (`datbike_ble_logs.txt`) are local-only and gitignored — never commit them.
