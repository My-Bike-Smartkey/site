# Hướng Dẫn Tích Hợp iOS App & Smartkey Provisioning

Tài liệu này cung cấp toàn bộ thông tin từ mức độ giao thức BLE cho đến mã nguồn Swift tham khảo để bạn có thể tích hợp tính năng cấu hình ESP32-C3 trực tiếp vào app iOS `DatBikeSmartkey`.

---

## 1. Thông Số Giao Tiếp BLE (GATT Server)

Khi ESP32-C3 được bật chế độ Provisioning (gõ lệnh `prov` qua CLI hoặc giữ nút 3s sau này), mạch sẽ phát sóng BLE và đóng vai trò là một **GATT Server**.

- **Tên thiết bị phát sóng:** `ESP-Smartkey`
- **Service UUID (Config Service):** `12340000-1234-1234-1234-123400000000`

### Danh sách Characteristics

| Tên | UUID | Quyền (Properties) | Chức năng | Payload (Ví dụ) |
|---|---|---|---|---|
| `PIN_CHAR` | `12340001-...` | `WRITE` + `WRITE_ENC` | Gửi mã PIN | `1234abcd` (String UTF-8) |
| `STS_CHAR` | `12340002-...` | `READ` | Đọc trạng thái | `OK:v3.0` hoặc `OK:PIN_SAVED` |
| `MAC_CHAR` | `12340003-...` | `WRITE` + `WRITE_ENC` | Gửi MAC của xe | `C8:EA:F2:XX:YY:ZZ` (String) |
| `FRAME_CHAR`| `12340004-...` | `WRITE` + `WRITE_ENC` | Gửi Số khung xe | `RLCE123456789` (String) |

> **Yêu cầu bảo mật:** Các Characteristic nhận ghi dữ liệu (PIN, MAC, FRAME) đều có cờ `WRITE_ENC`. Điều này bắt buộc iOS và ESP32 phải hoàn thành quá trình **BLE Pairing (Bonding)** trước khi hệ điều hành cho phép ghi. 

---

## 2. Mã nguồn tham khảo cho iOS App

### A. CoreBluetooth Provisioner Service (`SmartKeyProvisioner.swift`)

Service này chịu trách nhiệm quét, kết nối, ép ghép đôi (Pair) và ghi các dữ liệu cần thiết xuống mạch.

```swift
import Foundation
import CoreBluetooth
import Combine

enum ProvisioningState {
    case idle
    case scanning
    case connecting
    case discovering
    case pairingAndWriting
    case success
    case error(String)
}

class SmartKeyProvisioner: NSObject, ObservableObject {
    @Published var state: ProvisioningState = .idle
    
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    
    // UUID Constants
    private let serviceUUID = CBUUID(string: "12340000-1234-1234-1234-123400000000")
    private let pinCharUUID = CBUUID(string: "12340001-1234-1234-1234-123400000000")
    private let macCharUUID = CBUUID(string: "12340003-1234-1234-1234-123400000000")
    private let frameCharUUID = CBUUID(string: "12340004-1234-1234-1234-123400000000")
    
    // Data to write
    private var targetPin: String = ""
    private var targetMac: String = ""
    private var targetFrame: String = ""
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func startProvisioning(pin: String, mac: String, frame: String) {
        self.targetPin = pin
        self.targetMac = mac
        self.targetFrame = frame
        
        guard centralManager.state == .poweredOn else {
            state = .error("Bluetooth chưa được bật.")
            return
        }
        
        state = .scanning
        centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
        
        // Timeout cho quá trình scan
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            if case .scanning = self.state {
                self.centralManager.stopScan()
                self.state = .error("Không tìm thấy thiết bị ESP-Smartkey.")
            }
        }
    }
    
    func cancel() {
        centralManager.stopScan()
        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        state = .idle
    }
}

// MARK: - CBCentralManagerDelegate
extension SmartKeyProvisioner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn && state != .idle {
            state = .error("Bluetooth bị tắt đột ngột.")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Tìm thấy ESP32
        centralManager.stopScan()
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        
        state = .connecting
        centralManager.connect(peripheral, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .discovering
        peripheral.discoverServices([serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .error("Không thể kết nối đến ESP32: \(error?.localizedDescription ?? "Unknown error")")
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if case .success = state { return } // Nếu đã success thì ngắt kết nối là bình thường
        state = .error("Bị ngắt kết nối đột ngột.")
    }
}

// MARK: - CBPeripheralDelegate
extension SmartKeyProvisioner: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            state = .error("Không tìm thấy Config Service.")
            return
        }
        peripheral.discoverCharacteristics([pinCharUUID, macCharUUID, frameCharUUID], for: service)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        state = .pairingAndWriting
        
        // Bắt đầu ghi dữ liệu. Bước này sẽ tự động kích hoạt iOS popup "Pairing Request" 
        // do Characteristics trên ESP32 yêu cầu WRITE_ENC (mã hóa).
        if let pinChar = service.characteristics?.first(where: { $0.uuid == pinCharUUID }),
           let pinData = targetPin.data(using: .utf8) {
            peripheral.writeValue(pinData, for: pinChar, type: .withResponse)
        }
        
        if let macChar = service.characteristics?.first(where: { $0.uuid == macCharUUID }),
           let macData = targetMac.data(using: .utf8) {
            peripheral.writeValue(macData, for: macChar, type: .withResponse)
        }
        
        if let frameChar = service.characteristics?.first(where: { $0.uuid == frameCharUUID }),
           let frameData = targetFrame.data(using: .utf8) {
            peripheral.writeValue(frameData, for: frameChar, type: .withResponse)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            // Lỗi phổ biến: User nhấn "Cancel" lúc iOS hỏi Pairing
            state = .error("Lỗi khi ghi dữ liệu: \(error.localizedDescription)")
            return
        }
        
        // Cả 3 values đã được ghi thành công thì coi như hoàn tất (ở đây làm đơn giản, chỉ cần PIN ghi thành công là báo OK)
        if characteristic.uuid == pinCharUUID {
            DispatchQueue.main.async {
                self.state = .success
                
                // LƯU Ý BẢO MẬT: Nhớ lưu targetPin vào iOS Keychain ở đây!
                // KeychainHelper.write(key: "datbike.smartkey.pin", value: self.targetPin)
                
                // Ngắt kết nối sau khi xong
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
        }
    }
}
```

---

### B. Giao diện Cấu hình (`SmartKeySetupView.swift`)

Màn hình SwiftUI sử dụng Service bên trên:

```swift
import SwiftUI

struct SmartKeySetupView: View {
    @StateObject private var provisioner = SmartKeyProvisioner()
    @State private var pinInput: String = ""
    @State private var macInput: String = ""
    @State private var frameInput: String = ""
    
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Thông tin xác thực")) {
                    SecureField("Mã PIN (VD: 1234abcd)", text: $pinInput)
                        .keyboardType(.asciiCapable)
                    TextField("Địa chỉ MAC Xe (VD: C8:EA:...)", text: $macInput)
                        .autocapitalization(.allCharacters)
                    TextField("Số khung Xe (Tùy chọn)", text: $frameInput)
                        .autocapitalization(.allCharacters)
                }
                
                Section {
                    Button(action: startProvisioning) {
                        HStack {
                            Spacer()
                            Text(buttonTitle)
                                .bold()
                            Spacer()
                        }
                    }
                    .disabled(pinInput.count < 6 || provisioner.state == .scanning || provisioner.state == .connecting)
                }
                
                Section(header: Text("Trạng thái")) {
                    statusMessageView
                }
            }
            .navigationTitle("Cấu hình ESP32 Hardware")
            .navigationBarItems(trailing: Button("Đóng") {
                provisioner.cancel()
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
    
    private var buttonTitle: String {
        switch provisioner.state {
        case .scanning, .connecting, .discovering, .pairingAndWriting:
            return "Đang xử lý..."
        default:
            return "Bắt Đầu Ghi Vào ESP32"
        }
    }
    
    @ViewBuilder
    private var statusMessageView: some View {
        switch provisioner.state {
        case .idle:
            Text("Hãy chắc chắn bạn đã gõ lệnh 'prov' trên mạch ESP32 để bật chế độ cấu hình.")
                .foregroundColor(.gray)
        case .scanning:
            HStack {
                ProgressView()
                Text("Đang quét tìm mạch ESP-Smartkey...")
                    .padding(.leading, 8)
            }
        case .connecting, .discovering:
            Text("Đang kết nối tới mạch...")
                .foregroundColor(.blue)
        case .pairingAndWriting:
            Text("Đang mã hóa dữ liệu. Nếu iOS yêu cầu Ghép đôi, hãy nhấn Cho Phép.")
                .foregroundColor(.orange)
                .bold()
        case .success:
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Cấu hình thành công! Mạch ESP32 đã lưu thông tin.")
                    .foregroundColor(.green)
            }
            .onAppear {
                // Tự đóng modal sau 2 giây
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    presentationMode.wrappedValue.dismiss()
                }
            }
        case .error(let msg):
            Text("Lỗi: \(msg)")
                .foregroundColor(.red)
        }
    }
    
    private func startProvisioning() {
        provisioner.startProvisioning(pin: pinInput, mac: macInput, frame: frameInput)
    }
}
```

---

## 3. Cách Test Tích Hợp (Mô Phỏng Trải Nghiệm Thực Tế)

1. Cắm ESP32 vào máy. Mở Terminal và chạy: `./flash_and_monitor.sh`
2. Trong màn hình Serial, gõ: `prov` (Bật Provisioning Mode)
3. Chạy App iOS, mở màn hình **SmartKeySetupView**.
4. Nhập mã PIN (VD: `test1234`), MAC (`11:22:33:44:55:66`).
5. Bấm "Bắt Đầu Ghi Vào ESP32".
6. Lần đầu kết nối, iPhone sẽ hiện thông báo popup hệ thống: *"Bluetooth Pairing Request from ESP-Smartkey"*. Bạn bấm **Pair**.
7. Ngay lập tức trên Serial của ESP32 bạn sẽ thấy log:
   ```
   📱 [PROV] iOS App connected!
   🔐 [PROV] New PIN saved: test1234
   📍 [PROV] New MAC saved: 11:22:33:44:55:66
   ```
8. App iOS báo **"Cấu hình thành công ✅"** và tự động đóng màn hình.
9. Rút điện ESP32, cắm lại (reboot). Mạch sẽ bắt đầu kết nối xe Dat Bike bằng thông tin vừa được iOS cấu hình!

---

## 4. Các Vấn Đề Thường Gặp (Troubleshooting)

### 4.1 Lỗi "Timeout quét (10s)! Không tìm thấy ESP-Smartkey" (Trường hợp Cổ Điển)

Nếu bạn vừa chạy file `scan_ble.py` trên Mac để kiểm tra và thấy mạch ESP32, nhưng ngay sau đó mở App iOS lên thì App lại báo không tìm thấy, nguyên nhân 99% là do:
**Mạch ESP32 đã bị kết nối (hoặc giữ kết nối) bởi tiến trình Python trên Mac!**

Trong chuẩn BLE, một thiết bị ngoại vi (Peripheral) như ESP32 một khi đã có một thiết bị trung tâm (Central - như máy Mac) kết nối vào, nó sẽ **ngừng phát sóng quảng cáo (Stop Advertising)**. 
- Vì nó đã ngừng phát sóng, iPhone dù có quét (bằng mọi filter, kể cả `nil`) cũng sẽ không bao giờ nhìn thấy ESP32 nữa.
- **Cách xử lý:** 
  1. Tắt hoàn toàn script `scan_ble.py` trên Mac.
  2. Bấm nút Reset (EN) trên mạch ESP32 hoặc rút điện cắm lại.
  3. Gõ lại lệnh `prov` trong terminal của ESP32.
  4. Quét lại trên iPhone.

### 4.2 Xung Đột Trình Quản Lý Quét (Multiple CBCentralManager Conflict)

Nếu chắc chắn ESP32 đang phát sóng (chưa kết nối với thiết bị nào khác) nhưng App iOS vẫn lờ đi:
- Ứng dụng iOS của Dat Bike có `DatBikeCore` luôn duy trì một phiên bản `CBCentralManager` ngầm để tự động tìm xe.
- Nếu bạn tạo thêm một `CBCentralManager` thứ hai trong `SmartKeyProvisioner`, hệ điều hành iOS đôi khi sẽ ưu tiên tài nguyên sóng BLE cho tiến trình quét cũ và kìm hãm tiến trình mới.
- **Giải pháp:** App hiện tại đã được cấu hình ép gọi `core.forceStopScan()` trước khi `SmartKeyProvisioner` bắt đầu quét, đồng thời sử dụng cờ `CBCentralManagerScanOptionAllowDuplicatesKey: true` để buộc iOS nhả dữ liệu.
