# App Store Submission — dữ liệu điền form (App Store Connect)

> Trạng thái: **chuẩn bị** — bản 5.0.0 (7), manifest quyền riêng tư đã vào build.
> Mọi trường "<CẦN HOST>" phải có URL thật trước khi bấm Submit.

## 1. Thông tin build (đã sẵn)

| Trường | Giá trị |
|---|---|
| Bundle ID | `app.mybike.smartkey` |
| Team | `MH385VJBCB` |
| Version / Build | `5.0.0` / `7` |
| Nền tảng | iOS 18.0+, iPhone only (`TARGETED_DEVICE_FAMILY=1`) |
| Ngôn ngữ chính | Việt Nam (`vi`) |
| Privacy manifest | `DatBikeSmartkey/PrivacyInfo.xcprivacy` — không thu thập dữ liệu, 3 required-reason API (UserDefaults CA92.1, FileTimestamp C617.1, SystemBootTime 35F9.1) |
| Export compliance | `ITSAppUsesNonExemptEncryption=false` — chỉ dùng SHA-256 chuẩn cho auth thiết bị → thuộc diện miễn exemption |
| Background mode | `bluetooth-central` (duy nhất) — lý do cho review: giữ pending connect để mở khóa xe khi user lại gần |

## 2. App Information

| Trường | Giá trị đề xuất |
|---|---|
| Name (VN store) | `D-SmartKey – Smartkey cho xe` (28/30 ký tự) — **KHÔNG** đặt "Dat Bike" trong tên (rủi ro trademark khi review) |
| Subtitle | `Điều khiển xe máy điện` (22/30) |
| Primary Language | Vietnamese |
| Bundle / SKU | `app.mybike.smartkey` / `dsmartkey-ios` |
| Category chính | `Utilities` |
| Category phụ | `Travel` |
| Price | **Free** (tier 0) |
| Copyright | `2026 D-SmartKey contributors` |
| Age rating | Xem §5 → `4+` |

## 3. Store listing (locale vi) — copy sẵn

**Promotional text (≤170):**
> Chìa khóa thông minh cho xe máy điện: mở khóa tự động khi lại gần, xem pin & hành trình ngay trên điện thoại. Kết nối BLE ổn định, bảo mật bằng PIN.

**Keywords (≤100 ký tự, nối bằng dấu phẩy):**
```
smartkey,khoa thong minh,xe may dien,chia khoa,ble,xin chao,unlock,gan xe
```
*(62 ký tự — còn dư gianh; KHÔNG lặp từ đã có trong name/subtitle)*

**Description (≤4000):**
```
D-SmartKey biến iPhone thành chìa khóa thông minh cho xe máy điện của bạn.

MỞ KHÓA KHÔNG CẦN CHIẾC CHÌA KHÓA NÀO
• Lại gần xe — xe tự nhận diện và mở khóa (tuỳ chọn, bật/tắt trong Cài đặt)
• Rời xe — tự khóa lại sau khi bạn đi khỏi vùng sóng
• Mở/khóa thủ công chỉ với 1 chạm

THEO DÕI TRẠNG THÁI XE TRỰC TIẾP
• Pin xe, nhiệt độ pin, tốc độ, cung đường
• Cảnh báo khi pin thấp
• Lịch sử hành trình theo ngày

BẢO MẬT LÀM NỀN TẢNG
• Xác thực bằng PIN — thông điệp mã hoá mỗi phiên kết nối
• Toàn bộ dữ liệu lưu TRÊN THIẾT BỊ — không có server, không thu thập, không quảng cáo
• Mã nguồn mở, kiểm chứng được

YÊU CẦU
• Cần xe máy điện tương thích (hãng gắn module BLE cùng chuẩn giao thức)
• iPhone chạy iOS 18 trở lên, Bluetooth luôn bật
• Lần đầu ghép đôi cần thẻ/PIN do hãng xe cấp

LƯU Ý: D-SmartKey là ứng dụng của bên thứ ba, không chính thức bởi bất kỳ hãng xe nào. Tên hãng xe (nếu có) chỉ nhằm mục đích tương thích.
```

**What's New (5.0.0):**
```
Viết lại nền tảng kết nối — ổn định hơn hẳn:
• Mở app khi đứng gần xe: kết nối ngay trong ~5 giây, có watchdog tự phục hồi
• Timeline trực quan màn hình kết nối
• Log chẩn đoán chi tiết để hỗ trợ nhanh hơn
• Nhiều bản sửa ổn định nền (xem CHANGELOG trong kho mã nguồn)
```

**Support URL:** `https://github.com/My-Bike-Smartkey/ios-app/issues` ✓ (đang sống)
**Marketing URL:** `<CẦN HOST>` — host `landingpage.html` (GitHub Pages) → `https://my-bike-smartkey.github.io/`
**Privacy Policy URL:** `<CẦN HOST>` — nội dung sẵn ở `docs/PRIVACY_POLICY_vi.md` → host cùng GitHub Pages → `https://my-bike-smartkey.github.io/privacy`

## 4. App Privacy (Data Safety) — trả lời form

Chọn: **"Data Not Collected"** (không thu thập dữ liệu nào).

Căn cứ (đối chiếu code):
- Không network call nào ngoài BLE — không analytics, không ads, không crash-report SDK bên thứ ba
- PIN + tuỳ chọn lưu trong app sandbox (UserDefaults) — không rời thiết bị
- Log BLE ghi file local `Documents/ble_logs/` — chỉ ra khỏi máy khi user tự pull
- `NSPrivacyCollectedDataTypes = []` trong PrivacyInfo.xcprivacy khớp với tuyên bố này — sai lệch giữa 2 nơi là lý do reject phổ biến

## 5. Age Rating — trả lời questionnaire

Tất cả câu hỏi nội dung (bạo lực, cờ bạc, chất cấm, nội dung 18+, v.v.): **None / No**.
Kết quả: **4+**. Không có unrestricted web access (không WKWebView), không user-generated content.

## 6. App Review Information — phần quan trọng nhất với app này

**Demo Account:** N/A (không có hệ thống tài khoản).

**Notes for review (copy sẵn, điền URL video trước khi submit):**
```
This app is a Bluetooth smart key for electric scooters. It requires the
physical vehicle to test the full flow, which we understand reviewers don't
have access to.

• Demo video (full pairing → auto-unlock → lock → battery screens):
  <CẦN QUAY VIDEO — đăng unlisted YouTube/Drive, dán URL đây>

• CoreBluetooth background mode "bluetooth-central" is required for the
  product's core function: maintaining a pending connection so the vehicle
  unlocks when the user walks up to it. No audio/voip/location background use.

• All data stays on device (see PrivacyInfo.xcprivacy) — no servers,
  no account system, no tracking.

• Without the vehicle the app shows the connecting screen with a timeout
  message "Cannot find the vehicle" — this is expected behavior.

Contact: <EMAIL ĐIỀN VÀO> (timezone GMT+7, Vietnam)
```

**Review contact:** tên + email + phone của chủ dự án (điền lúc submit).

## 7. Screenshots — checklist chụp

Bắt buộc: **6.9"** (1320×2868 hoặc 1290×2796), tối thiểu 1, nên 3–5 tấm. Simulator iPhone 16 Pro Max chụp:
1. Màn hình kết nối (timeline đang chạy) — minh hoạ UI đặc trưng
2. Dashboard chính (xe đã kết nối, trạng thái khóa + pin)
3. Màn hình pin/telemetry
4. Cài đặt (tuỳ chọn gần xe, ngưỡng RSSI)
5. (Tuỳ chọn) màn hình ghép đôi PIN

Lệnh chụp nhanh simulator: `xcrun simctl io booted screenshot <tên>.png`.

## 8. Kiểm tra kỹ thuật trước khi Archive

- [x] `PrivacyInfo.xcprivacy` đã vào target (build 5.0.0 (7), tests xanh 40/0 fail)
- [x] `ITSAppUsesNonExemptEncryption=false`
- [x] Icon 1024pt không alpha (kiểm tra lại lần cuối trong Assets)
- [x] Background modes: chỉ `bluetooth-central`
- [ ] Privacy Policy URL đã host (GitHub Pages từ repo)
- [ ] Marketing URL đã host
- [ ] Video demo đã quay + link
- [ ] Ghi chú: bản Release đang giữ debug log BLE bật (`PersistentLogger`) — cân nhắc tắt mặc định cho bản App Store nếu không muốn log file nằm trong sandbox user (không chặn submit)

## 9. Lệnh Archive + Upload

```bash
xcodebuild archive -project DatBikeSmartkey.xcodeproj -scheme DatBikeSmartkey \
  -destination 'generic/platform=iOS' -archivePath build/D-SmartKey.xcarchive

xcodebuild -exportArchive -archivePath build/D-SmartKey.xcarchive \
  -exportOptionsPlist ExportOptions.testflight.plist

# exportIPA xong sẽ tự upload (destination=upload trong plist).
# Bắt buộc dùng Xcode signing MH385VJBCB đã cấu hình.
```

Khuyến nghị: upload lên **TestFlight** trước, nghiệm thu trên TN theo ma trận `docs/TEST_AND_DEPLOYMENT_GUIDE.md`, rồi mới submit review.
