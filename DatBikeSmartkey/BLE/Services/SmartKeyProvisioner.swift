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
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self = self else { return }
            if self.state == .scanning {
                self.centralManager.stopScan()
                self.state = .error("Không tìm thấy mạch ESP-Smartkey.")
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
        if state == .success { return }
        state = .error("Bị ngắt kết nối đột ngột.")
    }
}

// MARK: - CBPeripheralDelegate
extension SmartKeyProvisioner: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            state = .error("Không tìm thấy Config Service trên ESP32.")
            return
        }
        peripheral.discoverCharacteristics([pinCharUUID, macCharUUID, frameCharUUID], for: service)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        state = .pairingAndWriting
        
        // Bắt đầu ghi dữ liệu
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
            state = .error("Lỗi ghi dữ liệu (Bạn đã nhấn Cancel?): \(error.localizedDescription)")
            return
        }
        
        // Nếu ghi PIN thành công
        if characteristic.uuid == pinCharUUID {
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
