# Bộ Test Suites cho DatBike Smartkey (iOS)

Tài liệu này định nghĩa các kịch bản kiểm thử (Test Scenarios), Test Suites và Test Cases cho ứng dụng DatBike Smartkey. Các bài test tập trung mạnh vào vòng đời kết nối BLE (AccessorySetupKit - ASK), phục hồi phiên ở chế độ nền (Background State Restoration) và tính ổn định của Authentication.

---

## Test Suite 1: Quá trình ghép đôi & Khởi tạo (Pairing & Initialization)
**Mục tiêu:** Đảm bảo luồng ghép đôi lần đầu diễn ra suôn sẻ, an toàn và đúng chuẩn mã hoá.

| ID | Test Case | Tiền điều kiện | Các bước thực hiện | Kết quả mong đợi |
|---|---|---|---|---|
| 1.1 | Quét tìm xe lân cận | App chưa từng ghép đôi xe nào, Bluetooth đang bật. | Mở app, cấp quyền Bluetooth. Đợi màn hình radar quét. | Hiển thị danh sách các xe DatBike ở gần. Các thiết bị không phải DatBike bị lọc bỏ. |
| 1.2 | Bắt tay AccessorySetupKit (ASK) | Đã thấy xe trên màn hình radar. | Chọn xe, iOS bật popup hỏi quyền quản lý phụ kiện. Chọn "Connect". | App nhận quyền ASK, màn hình chuyển sang nhập mã PIN. |
| 1.3 | Ghép đôi PIN đúng | Đang ở màn hình nhập PIN. | Nhập PIN đúng (12 ký tự). | App lưu PIN, thực hiện SHA protocol, chuyển sang màn hình chính (Dashboard) với đầy đủ Telemetry. |
| 1.4 | Ghép đôi PIN sai | Đang ở màn hình nhập PIN. | Nhập mã PIN sai. | Báo lỗi xác thực, yêu cầu nhập lại, không lưu PIN sai vào hệ thống. |
| 1.5 | Xe từ chối kết nối (Bonding removed) | Xe đã xóa kết nối với điện thoại. | Mở app để tự động kết nối lại. | Hệ thống báo lỗi Code 14. App hiển thị popup hướng dẫn user vào Cài đặt iOS để quên thiết bị. |

---

## Test Suite 2: Phục hồi phiên & Chạy ngầm (Session Restoration & Background)
**Mục tiêu:** Đảm bảo ứng dụng tự động kết nối lại với xe trong mọi tình huống (tắt màn hình, vuốt tắt app, đi xa về gần).

| ID | Test Case | Tiền điều kiện | Các bước thực hiện | Kết quả mong đợi |
|---|---|---|---|---|
| 2.1 | Reconnect khi đi xa về gần (Foreground) | Đã ghép đôi. Đang mở app. Đứng xa xe (>20m). | Cầm điện thoại đi lại gần xe (<5m). | Trạng thái chuyển từ "Đang tìm xe..." -> "Đang kết nối..." -> "Đã kết nối". Telemetry cập nhật lập tức. |
| 2.2 | Reconnect từ dưới nền (Background Wake) | Đã ghép đôi. Đã khóa màn hình hoặc chuyển app khác. Đang ở xa. | Đi lại gần xe (<5m). | iOS đánh thức app ngầm. Gửi Notification: "Phát hiện di chuyển gần xe". Trạng thái chuyển sang "Đã kết nối (Chờ gần)". |
| 2.3 | Vuốt tắt App (Force-kill) & Đi lại gần | App đã bị vuốt tắt hẳn khỏi đa nhiệm. Đang ở xa xe. | Đi lại gần xe (<5m). | iOS đánh thức app thông qua `AppDelegate` và State Restoration. Kết nối thiết lập ngầm, bắn Notification thành công. |
| 2.4 | Fast-path Session (Counter Lẻ) | Đã kết nối, vuốt tắt app nhưng VẪN ĐỨNG GẦN xe (chưa mất kết nối vật lý do ASK giữ). | Mở app lại. | Chuyển thẳng vào trạng thái `Đã kết nối` (không qua Standby). Tốc độ phục hồi dưới 1 giây. Log báo "Fetching initial data...". |
| 2.5 | Stale Session (Counter Chẵn) | Đã kết nối. Bỏ xe qua đêm. Hôm sau mở app. | Mở app khi đứng gần xe. | Chuyển qua "Chờ gần" -> "Đang xác thực bảo mật" -> "Đã kết nối". Quá trình mất ~3s do cần auth lại bằng SHA. |
| 2.6 | Xử lý lỗi "Phantom Connection" | iOS báo "Đang kết nối" nhưng xe bị mất điện đột ngột. | Mở app lên. | App chờ 1.5s. Timer Timeout kích hoạt, hủy kết nối ảo, scan tìm lại từ đầu. |

---

## Test Suite 3: Điều khiển truy cập (Access Control)
**Mục tiêu:** Kiểm tra các tính năng mở/khóa xe thủ công và tự động.

| ID | Test Case | Tiền điều kiện | Các bước thực hiện | Kết quả mong đợi |
|---|---|---|---|---|
| 3.1 | Mở/Khóa thủ công bằng nút bấm | Mở app, trạng thái "Đã kết nối". | Bấm nút Nguồn (Bật xe) -> Bấm lần nữa (Tắt xe). | Lệnh truyền đi mượt mà. Phản hồi rung. Icon ổ khóa đổi trạng thái theo thời gian thực. |
| 3.2 | Tự động mở khi lại gần (Auto-unlock) | Cài đặt bật "Tự động mở khóa". Khóa màn hình. | Đi từ xa lại sát xe (RSSI > Ngưỡng). | App tự tính toán RSSI, tự động gửi lệnh "Bật xe" khi đủ gần. Bắn Notification "Xe đã được bật". |
| 3.3 | Tránh Race-Condition khi người dùng can thiệp | Tính năng Auto-unlock đang bật, user đang tiến lại gần. | Mở app, tự bấm nút "Bật xe" trước khi Auto-unlock kích hoạt. | Lệnh của người dùng được ưu tiên. Auto-unlock tự động hủy bỏ kịch bản của nó để tránh gửi lệnh đè lên nhau. |
| 3.4 | Gửi lệnh lỗi (Command Retry) | Đang kết nối chập chờn (RSSI rất yếu). | Bấm nút "Bật xe". | Gửi lệnh thất bại lần 1. App tự động thử lại (Retry). Nếu thành công trong 3 lần, báo OK. Nếu fail, báo "Lỗi kết nối". |

---

## Test Suite 4: Telemetry & Dữ liệu
**Mục tiêu:** Đảm bảo hiển thị chính xác trạng thái pin, nhiệt độ, phần mềm từ xe.

| ID | Test Case | Tiền điều kiện | Các bước thực hiện | Kết quả mong đợi |
|---|---|---|---|---|
| 4.1 | Cập nhật Telemetry Real-time | Trạng thái "Đã kết nối" (Active). | Quan sát màn hình Dashboard. Cắm sạc cho xe. | % Pin, dòng sạc, nhiệt độ cập nhật liên tục (mỗi 1s/2s tùy cấu hình Polling Engine). |
| 4.2 | Đọc Device Info khi khởi tạo | Phục hồi kết nối thành công (Fast-path). | Vào menu "Cài đặt". | Hiển thị đầy đủ phiên bản Firmware, loại xe, mã khung (VIN). Nút BMS được hiển thị. |
| 4.3 | Đồng bộ thời gian (Time Sync) | Đã kết nối lần đầu trong ngày. | Xem log đồng bộ. | Log hiện `[RESTORE] Syncing time (1 lần/ngày)`. Chỉ gửi 1 lần duy nhất trong ngày đó. |

---

## Test Suite 5: Tính năng Widget & UI
**Mục tiêu:** Kiểm tra liên kết dữ liệu giữa App Group và các Extension.

| ID | Test Case | Tiền điều kiện | Các bước thực hiện | Kết quả mong đợi |
|---|---|---|---|---|
| 5.1 | Cập nhật Widget Home Screen | Đã kết nối. Pin thay đổi từ 50% -> 49%. | Khóa màn hình / Vuốt ra Home xem Widget. | Widget hiển thị đúng "49%". Dữ liệu đọc thành công từ `AppGroup UserDefaults`. (Không báo lỗi cfprefsd). |
| 5.2 | Thao tác trên Widget | Xe đang khóa. | Bấm nút "Mở xe" trên Widget (App Intent). | Intent chạy nền thành công, gọi lệnh `wakeUpFromStandby()` đánh thức app. Xe được bật mà không cần mở app lên. |
| 5.3 | Thông báo (Push Notification) | Chạy nền. | Xe bị mở khóa vật lý (hoặc mở bằng thẻ từ). | BLE nhận Notify trạng thái khóa. App bắn Notification: "Trạng thái xe thay đổi: Đang bật" lên màn hình điện thoại. |

---

## Test Suite 6: Quản lý Edge Cases (Các trường hợp ngoại lệ)
**Mục tiêu:** Xử lý các lỗi vật lý, môi trường nhiễu sóng Bluetooth.

| ID | Test Case | Tiền điều kiện | Các bước thực hiện | Kết quả mong đợi |
|---|---|---|---|---|
| 6.1 | MIC / Encryption Failure | Xe vừa bị sập nguồn (khởi động lại cứng), iOS vẫn giữ bộ key mã hóa cũ. | Mở app kết nối. | Nhận lỗi `Failed to encrypt` hoặc `MIC failure`. App lập tức `forceFullScan = true`, xóa kết nối ảo, scan và thỏa thuận key mã hóa mới. Khôi phục thành công sau 3-5s. |
| 6.2 | Khởi động lại Bluetooth (Power Cycle) | Đang kết nối. Tắt Bluetooth trên Control Center rồi bật lại. | Mở app. | App nhận tín hiệu `.poweredOff`, ghi nhận `btWasPoweredOff = true`. Khi có lại, tự động scan và khôi phục toàn bộ session mà không cần user thao tác gì. |
| 6.3 | Đứt kết nối đột ngột (GATT Timeout) | Đang chạy app. Che kín ăng-ten điện thoại hoặc đi thang máy. | Quan sát log. | Sự kiện ngắt kết nối không lỗi (hoặc lỗi code 6). App giữ im lặng, chuyển nhẹ nhàng về trạng thái "Đang tìm xe...". Không văng crash. |

---
> [!TIP]
> **Phương pháp thực thi Test (Execution Guide):**
> 1. Sử dụng ứng dụng trên thiết bị vật lý thật (Real Device - iPhone). Trình giả lập (Simulator) không hỗ trợ Test Bluetooth hoặc State Restoration chính xác.
> 2. Các test case ngầm (Background) cần sử dụng console của Mac (App Console.app) lọc theo tên tiến trình `DatBikeSmartkey` để đọc Persistent Logger.
> 3. Cần kết hợp sử dụng xe vật lý hoặc tool giả lập Peripheral (Hardware Mocks) phát sóng đúng UUID và Characteristics của xe DatBike.
