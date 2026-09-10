# D-SmartKey — Kiến trúc và trạng thái rà soát

> Tài liệu mô tả code đang sửa, không phải chứng nhận nghiệm thu trên xe.
> Build/test Simulator không chứng minh reconnect nền hoặc hành vi firmware.

## 1. Các tầng độc lập

- CoreBluetooth quản lý liên kết peripheral: disconnected, connecting, connected, disconnecting.
- `DatBikeCore` điều phối GATT, auth, proximity và điều khiển xe.
- `IoTConnectionState.active` khác với `CBPeripheral.state.connected`: có liên kết chưa có nghĩa đã auth hoặc xe đã bật.
- ASK được dùng cho chọn/cấp quyền phụ kiện và sự kiện danh sách phụ kiện. Không dùng ASK như cảm biến khoảng cách.
- `.pairingRequired` trong core là luồng PIN/NFC của giao thức xe, không đồng nghĩa ASK picker.

## 2. Reconnect và chạy nền

CoreBluetooth có thể giữ yêu cầu connect cho peripheral đã biết; thời gian hoàn tất phụ thuộc quảng bá của xe, radio, quyền và lịch hệ điều hành. Pending connect không chứng minh xe ở xa, không chứng minh mức tiêu thụ pin bằng 0, không bảo đảm reconnect trong 1–2 giây.

`bluetooth-central` và state restoration hỗ trợ xử lý sự kiện BLE nền trong điều kiện iOS cho phép. Không đánh đồng user force-quit với hệ thống thu hồi app. Timer trong tiến trình không phải cơ chế đánh thức khi app đã suspend.

Phân biệt ba trạng thái sau khi app không còn foreground:

1. **Suspend với pending connect** — iOS theo dõi yêu cầu connect cho peripheral đã biết và đánh thức app khi có event. Đây là cơ chế chính cho "lại gần xe tự kết nối".
2. **Hệ thống jettison app → relaunch ngầm (state restoration)** — `willRestoreState` trả peripheral kèm trạng thái. Bản hiện tại **adopt cả `.connected` lẫn `.connecting`** (`.connecting` chính là pending connect hệ thống đang giữ — cancel nó là tự hủy cơ chế đánh thức). Nếu link keys mismatch, `didFailToConnect` MIC handler là đường dọn dẹp, không cancel phòng ngừa. `centralManagerDidUpdateState(.poweredOn)` giữ nguyên context `.connecting`, không churn bằng `connect()`. Nhánh `.disconnected` không còn set `forceFullScan` — `connect()` tự retrieve và đăng ký lại pending connect.
3. **User force-quit** — iOS không relaunch app cho BLE event nào; pending connect mất theo process; ASK giữ bonding trong Settings nhưng không có process app là không có smartkey logic. Không thể sửa bằng code app.

Nhánh standby RSSI yếu đã bỏ việc đợi backoff trong app trước khi gọi connect. Hiện nhánh đó gửi reconnect trực tiếp sau cancel; đây chỉ là sửa khoảng trống chưa có yêu cầu connect, chưa chứng minh loại bỏ vòng lặp ngắt/nối hoặc tối ưu pin. Chính sách giữ link/chờ gần cần tiếp tục rà soát.

Background task hiện dùng main queue và định danh lease cho expiration, không còn cutoff 20 giây. Thời lượng iOS cấp không cố định 30 giây. Các đường kết thúc task vẫn phải kiểm tra theo vòng đời phiên.

## 3. State và concurrency

`BLEStateMachine` bảo vệ state bằng lock; enqueue publication theo thứ tự transition, gửi ngoài lock và chuyển delivery UI về main queue. Publisher không còn lazy initialization.

**Không suy ra core đã thread-safe:** `DatBikeCore` vẫn có bleQueue, Main Queue và Task cùng truy cập context/timers/flags. Một số public API đã đi qua bleQueue nhưng ownership toàn core chưa hoàn tất. Lock ở registry characteristic hoặc notification debounce chỉ bảo vệ dữ liệu cục bộ.

Callback read của peripheral không hiện hành bị return sớm. Callback lỗi không cập nhật trạng thái khóa từ dữ liệu cached. Main-queue callback kiểm tra lại context trước khi cập nhật. Kiểm tra identity này chưa giải quyết toàn bộ race hoặc callback cũ trên cùng CBPeripheral sau reconnect.

## 4. Proximity và auto-bật

- `didReadRSSI` là nguồn cập nhật EMA duy nhất; không đưa publisher khởi tạo 0 của polling engine trở lại bộ lọc.
- Mẫu hợp lệ hiện giới hạn -127…-1; loại bỏ 0/127.
- `ProximitySampleWindow` gắn sessionID, dùng uptime monotonic, yêu cầu hai mẫu và age tối đa 3 giây cho auto-bật. Đây là chính sách app cần kiểm chứng trên TN, không phải yêu cầu Apple.
- Bộ lọc reset khi đổi phiên hoặc quá khoảng lấy mẫu.
- Auto-bật yêu cầu active, không manual-only, đúng cài đặt, trạng thái locked và RSSI đủ điều kiện; kiểm tra lại khi Task bắt đầu.
- Thông báo thành công chỉ sau dispatcher trả về unlocked; lỗi có log.
- **Còn mở:** phân biệt reservation auto đang chạy với user suspension, retry có giới hạn, arbitration lệnh thủ công, fencing tại thời điểm thực sự ghi GATT. Không được dùng retry vô hạn cho lệnh tác động vật lý.

Ngưỡng auth (`rssiThreshold`) và ngưỡng bật (`autoTurnOnThreshold`) có mục đích khác nhau; không gộp chỉ vì có hai giá trị.

## 5. Ý định người dùng

`ConnectionIntent`: autoConnect, manualOnlyPausedByUser, manualOnlyNearbyNotInUse. Yêu cầu thiết kế: manual-only chặn mọi tự reconnect/auth/bật; chỉ hành động dùng xe chủ động mới thoát. Mode change không tự gửi powerOff/arm. Không hứa firmware sẽ tự tắt vào thời điểm xác định nếu chưa đo.

## 6. ASK và phục hồi bonding

Picker dành cho thao tác chủ động thêm xe. Code dùng activation event trước khi đọc danh sách trong luồng connect UI. Cần tiếp tục kiểm tra activation failure, picker reentrancy, completion so với dismissal và migration UUID cũ.

Lệnh removeAccessory là bất đồng bộ: gửi yêu cầu không có nghĩa bonding đã xóa thành công. Không tuyên bố MIC/code14 đã được loại bỏ. Descriptor/Info.plist phải đối chiếu API thực; không suy luận mọi cấu hình thiếu đều gây crash.

## 7. Hạng mục chưa nghiệm thu

1. Một executor sở hữu vòng đời core và generation cho mọi công việc trễ.
2. Reconnect không ping-pong, phục hồi không phụ thuộc timer nền.
3. Auto-command reservation/retry và ưu tiên ý định dừng của user.
4. TTL Bluetooth 60 giây: chưa có bằng chứng tương ứng với cache mã hóa iOS.
5. Discovery watchdog theo dõi GATT discovery, không phải scan advertisement.
6. Telemetry polling không được tạo tác vụ chồng hoặc phát dữ liệu của phiên cũ.
7. Test BLE coordinator bằng fake transport và thử nhiều lượt gần/xa trên TN.

Không cài bản đang sửa lên TN chỉ vì build xanh. Xem kế hoạch nghiệm thu trong TEST_AND_DEPLOYMENT_GUIDE.md.
