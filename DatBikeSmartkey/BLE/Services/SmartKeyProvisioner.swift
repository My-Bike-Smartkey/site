import Foundation
import CoreBluetooth
import Combine

enum ProvisioningState: Equatable {
    case idle
    case scanning
    case connecting
    case discovering
    case readyToWrite
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
        print("[PROV] SmartKeyProvisioner INIT")
        centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.main)
    }
    
    deinit {
        print("[PROV] SmartKeyProvisioner DEINIT")
    }
    
    func findAndConnect() {
        print("[PROV] Bắt đầu tìm và kết nối Khóa Phụ...")
        
        guard centralManager.state == .poweredOn else {
            print("[PROV] Lỗi: Bluetooth chưa được bật. Trạng thái hiện tại: \(centralManager.state.rawValue)")
            state = .error("Bluetooth chưa được bật.")
            return
        }
        
        // 1. Kiểm tra xem thiết bị đã kết nối sẵn trong Cài đặt Bluetooth chưa
        // Nếu mạch ESP32 đã được Pair trong iOS Settings và đang kết nối, nó sẽ ngừng phát sóng (stop advertising).
        // Khi đó, cả ASK Picker lẫn lệnh quét truyền thống đều không thể tìm thấy.
        let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: [serviceUUID])
        if let p = connectedPeripherals.first {
            print("[PROV] Tìm thấy ESP32 đã kết nối sẵn từ Hệ thống iOS: \(p.name ?? "Unknown")")
            self.peripheral = p
            self.peripheral?.delegate = self
            state = .connecting
            centralManager.connect(p, options: nil)
            return
        }
        
        // 2. Kiểm tra thiết bị đã từng được lưu UUID (Đã cấp quyền ASK hoặc ghép đôi trước đó)
        if let savedUUIDString = PreferencesManager.shared.savedESP32UUID,
           let savedUUID = UUID(uuidString: savedUUIDString) {
            let knownPeripherals = centralManager.retrievePeripherals(withIdentifiers: [savedUUID])
            if let p = knownPeripherals.first {
                print("[PROV] Tìm thấy ESP32 đã lưu (UUID: \(savedUUIDString)). Bắt đầu kết nối lại...")
                self.peripheral = p
                self.peripheral?.delegate = self
                state = .connecting
                centralManager.connect(p, options: nil)
                return
            }
        }
        
        // 3. Nếu chưa kết nối sẵn, ta phải dùng ASK (System Picker) trên iOS 18
        // LƯU Ý QUAN TRỌNG: Vì UUID 12340000... đã được khai báo trong Info.plist (NSAccessorySetupBluetoothServices)
        // iOS 18 sẽ CHẶN lệnh scanForPeripherals truyền thống với UUID này! Do đó ta BẮT BUỘC phải dùng ASK.
        state = .scanning
        
        if #available(iOS 18.0, *) {
            print("[PROV] Đang hiển thị System Picker qua ASKManager...")
            ASKManager.shared.onESP32Selected = { [weak self] uuid in
                self?.handleASKSelection(uuid: uuid)
            }
            ASKManager.shared.onPickerDismissed = { [weak self] error in
                guard let self = self, self.state == .scanning else { return }
                if let err = error {
                    self.state = .error(err.localizedDescription)
                } else {
                    self.state = .error("Đã huỷ cấp quyền ASK.")
                }
            }
            ASKManager.shared.showPickerForESP32()
        } else {
            print("[PROV] Đang quét BLE tìm ESP-Smartkey (iOS < 18)...")
            centralManager.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }
    
    func syncData(pin: String, mac: String, frame: String) {
        guard state == .readyToWrite || state == .success else {
            print("[PROV] Lỗi: Chưa kết nối hoặc chưa sẵn sàng ghi.")
            return
        }
        
        print("[PROV] Bắt đầu đồng bộ dữ liệu. PIN: \(pin), MAC: \(mac), FRAME: \(frame)")
        self.targetPin = pin
        self.targetMac = mac
        self.targetFrame = frame
        self.state = .pairingAndWriting
        
        guard let peripheral = self.peripheral,
              let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            self.state = .error("Mất kết nối với dịch vụ của ESP32.")
            return
        }
        
        // Bắt đầu ghi dữ liệu
        if let pinChar = service.characteristics?.first(where: { $0.uuid == pinCharUUID }),
           let pinData = targetPin.data(using: .utf8) {
            print("[PROV] Ghi mã PIN...")
            peripheral.writeValue(pinData, for: pinChar, type: .withResponse)
        }
        
        if let macChar = service.characteristics?.first(where: { $0.uuid == macCharUUID }),
           let macData = targetMac.data(using: .utf8) {
            print("[PROV] Ghi địa chỉ MAC...")
            peripheral.writeValue(macData, for: macChar, type: .withResponse)
        }
        
        if let frameChar = service.characteristics?.first(where: { $0.uuid == frameCharUUID }),
           let frameData = targetFrame.data(using: .utf8) {
            print("[PROV] Ghi Số khung...")
            peripheral.writeValue(frameData, for: frameChar, type: .withResponse)
        }
    }
    
    private func handleASKSelection(uuid: UUID) {
        guard state == .scanning else { return }
        print("[PROV] ASK đã cấp quyền. Đang kết nối ESP32 với UUID: \(uuid)")
        
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        if let p = peripherals.first {
            self.peripheral = p
            self.peripheral?.delegate = self
            state = .connecting
            centralManager.connect(p, options: nil)
        } else {
            self.state = .error("Không thể retrieve peripheral từ iOS sau khi cấp quyền ASK")
        }
    }
    
    func cancel() {
        print("[PROV] Đã hủy tiến trình Provisioning bởi người dùng.")
        centralManager.stopScan()
        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        state = .idle
    }
    
    /// Xóa toàn bộ thông tin khóa phụ ESP32 đã lưu
    static func forgetESP32() {
        print("[PROV] Quên khóa phụ ESP32 — xóa UUID, ngày cấu hình")
        PreferencesManager.shared.savedESP32UUID = nil
        PreferencesManager.shared.savedESP32SetupDate = nil
    }
}

// MARK: - CBCentralManagerDelegate
extension SmartKeyProvisioner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("[PROV] CBCentralManager didUpdateState: \(central.state.rawValue)")
        if central.state != .poweredOn && state != .idle {
            state = .error("Bluetooth bị tắt đột ngột.")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unknown"
        
        let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasService = uuids.contains(serviceUUID)
        
        // In ra tất cả thiết bị quét được để debug
        print("[PROV-SCAN] Nhìn thấy thiết bị: \(name), UUID: \(peripheral.identifier), Có Service: \(hasService)")
        
        if name.contains("ESP-Smartkey") || hasService {
            print("[PROV] Đã tìm thấy ESP-Smartkey! UUID: \(peripheral.identifier), RSSI: \(RSSI)")
            centralManager.stopScan()
            self.peripheral = peripheral
            self.peripheral?.delegate = self
            
            state = .connecting
            centralManager.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[PROV] Đã kết nối tới \(peripheral.name ?? "thiết bị"). Bắt đầu Discover Services...")
        state = .discovering
        peripheral.discoverServices([serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[PROV] Kết nối thất bại: \(error?.localizedDescription ?? "Unknown")")
        
        // Nếu kết nối lại bằng UUID đã lưu bị thất bại (VD: do người dùng xoá Bluetooth trong Cài đặt hệ thống)
        if PreferencesManager.shared.savedESP32UUID == peripheral.identifier.uuidString {
            print("[PROV] Xóa UUID đã lưu bị lỗi và thử tìm lại (kích hoạt lại ASK)...")
            PreferencesManager.shared.savedESP32UUID = nil
            
            // Đặt lại state về scanning để có thể gọi lại tìm kiếm
            self.state = .scanning
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.findAndConnect()
            }
            return
        }
        
        state = .error("Không thể kết nối đến ESP32: \(error?.localizedDescription ?? "Unknown error")")
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[PROV] Bị ngắt kết nối. Lỗi (nếu có): \(error?.localizedDescription ?? "Không có")")
        if state == .success { return }
        state = .error("Bị ngắt kết nối đột ngột.")
    }
}

// MARK: - CBPeripheralDelegate
extension SmartKeyProvisioner: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("[PROV] Lỗi Discover Services: \(error.localizedDescription)")
            state = .error("Lỗi khi tìm Service: \(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            print("[PROV] Không tìm thấy Config Service (UUID \(serviceUUID)) trên ESP32!")
            state = .error("Không tìm thấy Config Service trên ESP32.")
            return
        }
        print("[PROV] Tìm thấy Config Service. Bắt đầu Discover Characteristics...")
        peripheral.discoverCharacteristics([pinCharUUID, macCharUUID, frameCharUUID], for: service)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("[PROV] Lỗi Discover Characteristics: \(error.localizedDescription)")
            state = .error("Lỗi khi tìm Characteristics: \(error.localizedDescription)")
            return
        }
        
        print("[PROV] Tìm thấy Characteristics. Đã sẵn sàng ghi dữ liệu.")
        state = .readyToWrite
        
        // Lưu lại UUID của thiết bị này để lần sau có thể kết nối thẳng không cần ASK Picker / Quét lại
        PreferencesManager.shared.savedESP32UUID = peripheral.identifier.uuidString
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("[PROV] Lỗi ghi dữ liệu tại Char \(characteristic.uuid): \(error.localizedDescription)")
            state = .error("Lỗi ghi dữ liệu (Bạn đã nhấn Cancel?): \(error.localizedDescription)")
            return
        }
        
        print("[PROV] Đã ghi thành công vào Char \(characteristic.uuid)!")
        
        // Nếu ghi PIN thành công
        if characteristic.uuid == pinCharUUID {
            print("[PROV] Quá trình Provisioning thành công! Đang lưu PIN. Giữ kết nối để Sync lại nếu cần.")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.state = .success
                
                // Cập nhật PIN vào PreferencesManager để dùng chung cho App
                PreferencesManager.shared.savedPin = self.targetPin
            }
        }
    }
}
