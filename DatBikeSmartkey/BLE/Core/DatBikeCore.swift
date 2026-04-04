import Foundation
import CoreBluetooth
import AccessorySetupKit
import Combine

/// -------------------------------------------------------------
/// LỚP BỌC TỐI THƯỢNG (FACADE) - MANAGER MỚI (V2)
/// -------------------------------------------------------------
/// Lớp này đóng vai trò Central Controller.
/// Nó KHÔNG làm toán SHA, KHÔNG dịch Telemetry, KHÔNG xử lý Async Wait.
/// Nó chỉ "bắt sóng", "bơm context", và "ủy quyền trách nhiệm" cho các Service.
class DatBikeCore: NSObject, IoTCoordinatorProtocol {
    
    // Khối trạng thái Generic
    private let stateMachine = BLEStateMachine()
    var connectionState: AnyPublisher<IoTConnectionState, Never> { stateMachine.statePublisher }
    
    // Publishers cho View
    @Published private(set) var currentTelemetry = IoTTelemetryData()
    var telemetryData: AnyPublisher<IoTTelemetryData, Never> { $currentTelemetry.eraseToAnyPublisher() }
    
    @Published private(set) var currentLockState: IoTLockState = .unknown(Data())
    var lockState: AnyPublisher<IoTLockState, Never> { $currentLockState.eraseToAnyPublisher() }
    
    // Biến môi trường CoreBluetooth
    private var centralManager: CBCentralManager!
    private var activeContext: BLEConnectionContext?
    
    // Các nhánh Worker (Khởi tạo khi có xe)
    private var commandDispatcher: BLECommandDispatcher?
    
    override init() {
        super.init()
        let queue = DispatchQueue(label: "datbike.core.ble", qos: .userInitiated)
        self.centralManager = CBCentralManager(delegate: self, queue: queue)
    }
    
    func connect() {
        // ... Logic liên kết ASK tương tự như cũ ...
        stateMachine.transition(to: .scanning)
    }
    
    func disconnect() {
        if let ctx = activeContext {
            centralManager.cancelPeripheralConnection(ctx.peripheral)
        }
    }
    
    // MARK: - API Cho ViewModel Cấp Cao
    func getDispatcher() throws -> IoTCommandService {
        guard let d = commandDispatcher else { throw IoTError.notConnected }
        return d
    }
}

extension DatBikeCore: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            stateMachine.transition(to: .error("Bluetooth bị tắt trên điện thoại."))
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        stateMachine.transition(to: .connecting)
        let context = BLEConnectionContext(peripheral: peripheral)
        self.activeContext = context
        peripheral.delegate = self
        
        // Cắm Service riêng cho từng Xe
        self.commandDispatcher = BLECommandDispatcher(context: context)
        
        peripheral.discoverServices(nil)
    }
}

extension DatBikeCore: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics, let ctx = activeContext else { return }
        for char in chars {
            ctx.register(characteristic: char)
            // Kích hoạt luồng Authenticator ngay khi thấy đủ characteristic c8eaf27b...
        }
    }
    
    // Hướng tín hiệu trả về cho IO Controller
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task {
            await activeContext?.io.didReceiveReadResponse(for: characteristic, error: error)
        }
        // Song song đó, nếu là dữ liệu Notify (Telemetry), chuyển cho BLETelemetryParser
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task {
            await activeContext?.io.didReceiveWriteResponse(for: characteristic, error: error)
        }
    }
}
