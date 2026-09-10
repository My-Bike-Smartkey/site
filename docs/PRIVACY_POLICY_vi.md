# Chính sách quyền riêng tư / Privacy Policy

> Bản này dùng để HOST (GitHub Pages) làm Privacy Policy URL cho App Store Connect.
> Ngày hiệu lực: 2026-09-10 · Phiên bản 1.0

D-SmartKey ("ứng dụng") được xây dựng theo nguyên tắc **không thu thập dữ liệu**. Ứng dụng hoạt động hoàn toàn trên thiết bị của bạn và kết nối trực tiếp với xe của bạn qua Bluetooth — không qua bất kỳ máy chủ nào của chúng tôi.

## Dữ liệu chúng tôi thu thập

**Không có.** Ứng dụng không gửi bất kỳ dữ liệu nào đến máy chủ của chúng tôi hay bên thứ ba:

- Không tài khoản, không đăng ký, không email
- Không phân tích hành vi (analytics), không quảng cáo, không theo dõi
- Không báo lỗi tự động (crash report) đến dịch vụ bên thứ ba
- Ứng dụng không kết nối internet cho chức năng nào — mọi giao tiếp là Bluetooth trực tiếp với xe

## Dữ liệu lưu trên thiết bị của bạn

Các thông tin sau được lưu **chỉ trong không gian riêng (sandbox) của ứng dụng** trên iPhone của bạn, và chỉ rời khỏi thiết bị nếu bạn chủ động xuất chúng:

| Loại dữ liệu | Nơi lưu | Mục đích |
|---|---|---|
| PIN ghép đôi xe | Keychain/app sandbox | Xác thực với xe mỗi phiên |
| Tuỳ chọn (ngưỡng khoảng cách, tự mở khóa…) | UserDefaults | Ghi nhớ cấu hình của bạn |
| Nhật ký Bluetooth (BLE logs) | File trong Documents/ble_logs/ | Debug khi bạn yêu cầu hỗ trợ |
| Số liệu xe (pin, trạng thái khóa) | Bộ nhớ trong sandbox | Hiển thị trong ứng dụng |

Gỡ cài đặt ứng dụng = toàn bộ dữ liệu trên bị xoá vĩnh viễn khỏi thiết bị.

## Quyền hệ thống ứng dụng yêu cầu

- **Bluetooth**: kết nối và điều khiển xe — đây là chức năng cốt lõi
- **Thông báo (tuỳ chọn)**: báo trạng thái kết nối/cảnh báo pin

## Bên thứ ba

Ứng dụng không chia sẻ dữ liệu với bên thứ ba nào vì không có dữ liệu nào rời thiết bị. Ứng dụng là sản phẩm của bên thứ ba, không liên kết với hãng sản xuất xe.

## Quyền của bạn

Vì dữ liệu chỉ nằm trên thiết bị, bạn toàn quyền kiểm soát: xoá ứng dụng để xoá toàn bộ; không yêu cầu "xuất/xoá dữ liệu khỏi server" vì không tồn tại server.

## Liên hệ

Báo cáo lỗi & yêu cầu hỗ trợ: https://github.com/My-Bike-Smartkey/ios-app/issues

---

*Privacy Policy — English summary: D-SmartKey collects no data. There is no server, no account, no analytics, no ads, and no tracking. All data (pairing PIN, preferences, BLE logs, vehicle metrics) stays in the app's on-device sandbox and is permanently deleted when the app is uninstalled. The app only uses Bluetooth (core function) and optional notifications.*
