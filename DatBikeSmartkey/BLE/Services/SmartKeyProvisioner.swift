import Foundation
import CoreBluetooth
import Combine

enum ProvisioningState: Equatable {
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
        print("[PROV] SmartKeyProvisioner INIT")
        centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.main)
    }
    
    deinit {
        print("[PROV] SmartKeyProvisioner DEINIT")
    }
    
    func startProvisioning(pin: String, mac: String, frame: String) {
        print("[PROV] Bắt đầu Provisioning via ASK. PIN: \(pin), MAC: \(mac), FRAME: \(frame)")
        self.targetPin = pin
        self.targetMac = mac
        self.targetFrame = frame
        
        guard centralManager.state == .poweredOn else {
            print("[PROV] Lỗi: Bluetooth chưa được bật. Trạng thái hiện tại: \(centralManager.state.rawValue)")
            state = .error("Bluetooth chưa được bật.")
            return
        }
        
        state = .scanning
        print("[PROV] Đang hiển thị System Picker qua ASKManager...")
        
        if #available(iOS 18.0, *) {
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
            self.state = .error("Tính năng này yêu cầu iOS 18 trở lên.")
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
        
        print("[PROV] Tìm thấy Characteristics. Bắt đầu ghi dữ liệu...")
        state = .pairingAndWriting
        
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
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("[PROV] Lỗi ghi dữ liệu tại Char \(characteristic.uuid): \(error.localizedDescription)")
            state = .error("Lỗi ghi dữ liệu (Bạn đã nhấn Cancel?): \(error.localizedDescription)")
            return
        }
        
        print("[PROV] Đã ghi thành công vào Char \(characteristic.uuid)!")
        
        // Nếu ghi PIN thành công
        if characteristic.uuid == pinCharUUID {
            print("[PROV] Quá trình Provisioning thành công! Đang lưu PIN và ngắt kết nối...")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.state = .success
                
                // Cập nhật PIN vào PreferencesManager để dùng chung cho App
                PreferencesManager.shared.savedPin = self.targetPin
                
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
        }
    }
}
