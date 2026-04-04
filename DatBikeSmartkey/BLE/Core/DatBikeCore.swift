import Foundation
import CoreBluetooth
import Combine

/// LỚP BỌC TỐI THƯỢNG (FACADE) - MANAGER MỚI (V2)
class DatBikeCore: NSObject, IoTCoordinatorProtocol {
    
    private let stateMachine = BLEStateMachine()
    var connectionState: AnyPublisher<IoTConnectionState, Never> { stateMachine.statePublisher }
    
    @Published private(set) var currentTelemetry = IoTTelemetryData()
    var telemetryData: AnyPublisher<IoTTelemetryData, Never> { $currentTelemetry.eraseToAnyPublisher() }
    
    @Published private(set) var currentLockState: IoTLockState = .unknown(Data())
    var lockState: AnyPublisher<IoTLockState, Never> { $currentLockState.eraseToAnyPublisher() }
    
    private var centralManager: CBCentralManager!
    private var activeContext: BLEConnectionContext?
    
    private var commandDispatcher: BLECommandDispatcher?
    private var pollingEngine: BLEPollingEngine?
    private let preferences: PreferencesManager
    private var cancellables = Set<AnyCancellable>()
    
    private var isAuthenticating = false
    
    init(preferences: PreferencesManager = .shared) {
        self.preferences = preferences
        super.init()
        let queue = DispatchQueue(label: "datbike.core.ble", qos: .userInitiated)
        self.centralManager = CBCentralManager(delegate: self, queue: queue)
    }
    
    func connect() {
        guard centralManager.state == .poweredOn else {
            stateMachine.transition(to: .error("Bluetooth chưa sẵn sàng"))
            return
        }
        stateMachine.transition(to: .scanning)
        // 1. Phục hồi Scanner: Quét các thiết bị quảng bá Service BLE của Dat Bike (nếu biết UUID, nếu không thì nil)
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    
    func disconnect() {
        stateMachine.transition(to: .idle)
        pollingEngine?.stopPolling()
        if let ctx = activeContext {
            centralManager.cancelPeripheralConnection(ctx.peripheral)
        }
        activeContext = nil
        commandDispatcher = nil
        pollingEngine = nil
        isAuthenticating = false
    }
    
    func getDispatcher() throws -> IoTCommandService {
        guard let d = commandDispatcher else { throw IoTError.notConnected }
        return d
    }
    
    // MARK: - Auto Unlock Wiring
    private func setupAutoUnlock(engine: BLEPollingEngine) {
        engine.$currentRSSI
            .combineLatest(preferences.$autoUnlockEnabled, preferences.$rssiThreshold)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main) // Chống dội
            .sink { [weak self] (rssi, isAutoUnlockOn, threshold) in
                guard let self = self, isAutoUnlockOn else { return }
                // Nếu RSSI vào vùng phủ sóng và xe đang tắt
                if rssi >= threshold, case .locked = self.currentLockState {
                    Task {
                        try? await self.commandDispatcher?.turnOnBike()
                    }
                }
            }
            .store(in: &cancellables)
    }
}

extension DatBikeCore: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            stateMachine.transition(to: .error("Bluetooth bị tắt trên điện thoại."))
        } else {
            // Tự quét nếu đang chờ
            if stateMachine.state == .scanning {
                connect()
            }
        }
    }
    
    // 2. Phục hồi didDiscover
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard let name = peripheral.name, name.contains("Dat Bike") else { return }
        
        centralManager.stopScan()
        stateMachine.transition(to: .connecting)
        
        let context = BLEConnectionContext(peripheral: peripheral)
        self.activeContext = context
        peripheral.delegate = self
        
        self.commandDispatcher = BLECommandDispatcher(context: context)
        self.pollingEngine = BLEPollingEngine(context: context)
        self.isAuthenticating = false // Reset cờ
        
        centralManager.connect(peripheral, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        disconnect()
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
        }
        
        // 3. Kích hoạt luồng Authenticator ngay khi thấy đủ characteristic c8eaf27b...
        if !isAuthenticating, (try? ctx.requireCharacteristic(BLECharacteristic.authChallenge)) != nil {
            isAuthenticating = true
            let authenticator = BLEAuthenticator(context: ctx, pin: "123456")
            
            Task {
                do {
                    stateMachine.transition(to: .authenticating)
                    try await authenticator.authenticate()
                    
                    // Thành công -> Bật engine Polling & Cắm cờ Auto Unlock
                    if let engine = self.pollingEngine {
                        engine.startPolling()
                        self.setupAutoUnlock(engine: engine)
                    }
                    
                    stateMachine.transition(to: .active)
                } catch {
                    print("Lỗi xác thực BLE: \(error)")
                    disconnect()
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { await activeContext?.io.didReceiveReadResponse(for: characteristic, error: error) }
        
        // Cập nhật trạng thái Khoá từ Notify Ping / IO
        if characteristic.uuid == BLECharacteristic.smartkeyEcho {
            if let data = characteristic.value {
                DispatchQueue.main.async {
                    // Cắt phân tích nhanh Lock State (01 = On, 00 = Off)
                    if data.count >= 2 {
                        let lockByte = data[1]
                        if lockByte == 0x01 {
                            self.currentLockState = .unlocked
                        } else if lockByte == 0x00 {
                            self.currentLockState = .locked
                        }
                    }
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { await activeContext?.io.didReceiveWriteResponse(for: characteristic, error: error) }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        pollingEngine?.didReadRSSI(value: RSSI.doubleValue)
    }
}
