# Đẩy app iOS lên Firebase App Distribution

## Tổng quan

**Cách đơn giản nhất** cho dự án này: Dùng **Firebase CLI** upload IPA trực tiếp — không cần thêm SDK vào app, không cần CI/CD phức tạp.

---

## Phần 1: Chuẩn bị Firebase

### Bước 1: Tạo Firebase Project
1. Truy cập [console.firebase.google.com](https://console.firebase.google.com)
2. Nhấn **"Add project"** → đặt tên (vd: `DatBikeSmartkey`)
3. Tắt Google Analytics (không cần thiết) → **Create project**

### Bước 2: Thêm iOS App vào Firebase
1. Trong Dashboard → nhấn biểu tượng **iOS** (quả táo)
2. **Apple bundle ID**: `app.sloth9695.cygnus4928` *(lấy từ ExportOptions.plist)*
3. Nhấn **Register app**
4. **Bỏ qua** bước download `GoogleService-Info.plist` và thêm SDK — không cần thiết cho App Distribution
5. Lưu lại **App ID** ở dạng `1:XXXXXXXXXX:ios:YYYYYY` — cần dùng sau

### Bước 3: Bật Firebase App Distribution
1. Trong Firebase Console → menu bên trái → **Release & Monitor** → **App Distribution**
2. Nhấn **Get started**

### Bước 4: Thêm Tester
1. Trong App Distribution → tab **Testers & Groups**
2. Nhấn **Add testers** → nhập email tester
3. Họ sẽ nhận email mời, cần cài **Firebase App Tester** từ App Store để tải app

---

## Phần 2: Cài Firebase CLI (máy dev)

```bash
# Cài Node.js trước nếu chưa có
brew install node

# Cài Firebase CLI
npm install -g firebase-tools

# Đăng nhập Google account
firebase login

# Kiểm tra
firebase --version
```

---

## Phần 3: Upload IPA lên Firebase

### Upload thủ công (cách nhanh nhất)

```bash
# Build IPA trước (đã có sẵn)
# IPA hiện tại: /Users/jedix/Desktop/projects/mybike/ios-app/DatBikeSmartkey.ipa

firebase appdistribution:distribute \
  /Users/jedix/Desktop/projects/mybike/ios-app/DatBikeSmartkey.ipa \
  --app "YOUR_FIREBASE_APP_ID" \
  --release-notes "Phiên bản test: Fix BLE reconnect, icon mới" \
  --testers "email1@example.com,email2@example.com"
```

> **Thay `YOUR_FIREBASE_APP_ID`** bằng App ID từ Firebase Console (dạng `1:123456789:ios:abcdef`)

---

## Phần 4: Tự động hoá với Fastlane (tuỳ chọn)

Nếu build thường xuyên, dùng Fastlane để vừa build vừa upload 1 lệnh.

### Cài Fastlane
```bash
# Dùng Bundler (khuyến nghị hơn gem install)
brew install ruby   # Cài Ruby mới hơn 2.6 hệ thống
gem install bundler

# Trong thư mục ios-app
cd /Users/jedix/Desktop/projects/mybike/ios-app
bundle init
echo 'gem "fastlane"' >> Gemfile
bundle install
```

### Khởi tạo Fastlane
```bash
cd /Users/jedix/Desktop/projects/mybike/ios-app
bundle exec fastlane init
# Chọn option 4: Manual setup
```

### Cài plugin Firebase
```bash
bundle exec fastlane add_plugin firebase_app_distribution
```

### Tạo Fastfile
Tạo file `/Users/jedix/Desktop/projects/mybike/ios-app/fastlane/Fastfile`:

```ruby
default_platform(:ios)

platform :ios do
  desc "Build và Upload lên Firebase App Distribution"
  lane :beta do
    # Build IPA
    gym(
      workspace: nil,
      project: "DatBikeSmartkey.xcodeproj",
      scheme: "DatBikeSmartkey",
      export_method: "ad-hoc",
      export_options: {
        provisioningProfiles: {
          "app.sloth9695.cygnus4928" => "00008140-001C5D8A1EF3001CWIKSOD"
        }
      },
      output_directory: "./build",
      output_name: "DatBikeSmartkey.ipa",
      clean: true
    )

    # Upload lên Firebase
    firebase_app_distribution(
      app: "YOUR_FIREBASE_APP_ID",
      ipa_path: "./build/DatBikeSmartkey.ipa",
      release_notes: "Build tự động: #{Time.now.strftime('%d/%m/%Y %H:%M')}",
      testers: "email1@example.com,email2@example.com"
    )
  end
end
```

### Chạy
```bash
bundle exec fastlane beta
```

---

## Quan trọng: Ad Hoc vs TestFlight

| | **Firebase App Distribution (Ad Hoc)** | **TestFlight** |
|---|---|---|
| **UDID tester** | ✅ Cần đăng ký UDID vào Provisioning Profile | ❌ Không cần |
| **Tốc độ phê duyệt** | ✅ Ngay lập tức | ⏳ Review 1-3 ngày |
| **Số lượng tester** | 100 thiết bị/năm | 10,000 tester |
| **Phù hợp** | Internal test nhóm nhỏ | Beta test rộng |

### Lấy UDID tester
Tester phải gửi UDID của họ cho bạn:
1. Vào [udid.io](https://www.udid.io) hoặc cắm iPhone vào Mac → Finder → nhấn serial
2. Bạn cần thêm UDID vào **Apple Developer Portal** → Devices → Register

---

## Tóm lại: Quy trình tối giản

```
1. Tạo Firebase project + thêm iOS app
2. Cài firebase-tools: npm install -g firebase-tools
3. firebase login
4. Build IPA (đã có sẵn hoặc chạy xcodebuild)
5. firebase appdistribution:distribute <ipa> --app <app-id> --testers <email>
```

Đây là cách nhanh nhất, không cần Fastlane, không cần SDK.
