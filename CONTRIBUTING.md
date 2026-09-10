# Contributing / Đóng góp

Cảm ơn bạn quan tâm đóng góp. Dự án nhỏ, duy trì bởi cá nhân — quy trình giữ nhẹ nhưng **nguyên tắc bằng chứng thì nghiêm**.

## Setup

```bash
git clone <repo> && cd ios-app
open DatBikeSmartkey.xcodeproj   # Xcode 16+, iOS 18 SDK
```

Không có dependency ngoài (không SPM/CocoaPods). Nếu bạn chỉnh `project.yml`, chạy `xcodegen generate` và commit cả `.xcodeproj` sinh ra.

## Trước khi gửi PR

1. **Unit tests phải xanh:**

   ```bash
   xcodebuild -project DatBikeSmartkey.xcodeproj -scheme DatBikeSmartkey \
     -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.0' \
     -configuration Debug test
   ```

2. **Build device phải thành công:**

   ```bash
   xcodebuild -project DatBikeSmartkey.xcodeproj -scheme DatBikeSmartkey \
     -configuration Debug -destination 'generic/platform=iOS' \
     -derivedDataPath build/tn CODE_SIGN_STYLE=Automatic build
   ```

3. Không mask exit code bằng pipeline (`| tail`, `|| true`) — PR mô tả kết quả phải kèm exit code thật.

## Quy tắc kỹ thuật (BLE)

- **BLE queue**: callback CoreBluetooth chạy trên `bleQueue`. API vòng đời public đi qua `executeOnBleQueue`. Đụng `activeContext`/timers/flags từ queue khác phải ghi rõ lý do trong PR.
- **State machine**: không bao giờ set state trực tiếp ngoài `BLEStateMachine.transition(to:)`. Publication đã có thứ tự đảm bảo — đừng thêm subject.send song song.
- **Callback fencing**: mọi delayed work (Task, DispatchQueue.asyncAfter) phải re-check `activeContext === ctx` / generation trước khi tác động state.
- **Lệnh vật lý** (power on/off, arm, find): mỗi phiên một lần cho auto-command; không blind-retry sau timeout không rõ kết quả. Không thêm đường tự gửi powerOff/arm khi đổi mode.
- **RSSI**: giá trị hợp lệ −127…−1; mọi lọc phải qua `ProximitySampleWindow` (EMA theo sessionID) — không tự thêm bộ lọc song song.
- **Docs đi kèm code**: sửa hành vi reconnect/background/auto-command mà không cập nhật `docs/ARCHITECTURE_BLE_AND_ASK.md` sẽ bị yêu cầu bổ sung.

## Quy tắc báo cáo kết quả

- Ghi **pass/skip/fail đúng số đo được**, kể cả test skip (10 test backlog skip là chủ đích — cần thiết bị thật).
- Build xanh + test simulator xanh **không** chứng minh ổn định trên xe. Mọi tuyên bố về hành vi vật lý phải dẫn kết quả theo ma trận nghiệm thu trong `docs/TEST_AND_DEPLOYMENT_GUIDE.md`.
- Không dùng từ "đã fix hoàn toàn", "100%", "zero leak" nếu không kèm số liệu đo được.

## An toàn dữ liệu & thiết bị

- **Không commit** `datbike_ble_logs.txt`, ảnh chụp màn hình có định danh người, hay bất kỳ log BLE chứa UUID thiết bị người khác (đã có trong `.gitignore`).
- Không chạy lệnh actuation trên xe thật trừ khi bạn là chủ xe và đang chủ động thử nghiệm.

## Quy trình PR

1. Fork → branch (`fix/...`, `feat/...`).
2. PR mô tả: **vấn đề → căn cứ (code/log) → thay đổi → bằng chứng (exit code + số test)**.
3. Chủ sở hữu xe thật (maintainer) chịu trách nghiệm thu trên thiết bị trước khi merge những thay đổi động vào reconnect/actuation.

## Báo cáo lỗi

Issue kèm: phiên bản app, iOS, firmware xe, log `datbike_ble_logs` đoạn liên quan (đã xoá thông tin nhạy cảm nếu chia sẻ công khai), các bước tái hiện theo đánh số trong ma trận nghiệm thu.
