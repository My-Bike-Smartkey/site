import Foundation
import CoreBluetooth
import Combine

/// LỚP BỌC TỐI THƯỢNG (FACADE) - MANAGER MỚI (V2)
class DatBikeCore: NSObject, IoTCoordinatorProtocol, @unchecked Sendable {
    
    private let stateMachine = BLEStateMachine()
    var connectionState: AnyPublisher<IoTConnectionState, Never> { stateMachine.statePublisher }
    
    @Published private(set) var currentTelemetry = IoTTelemetryData()
    var telemetryData: AnyPublisher<IoTTelemetryData, Never> { $currentTelemetry.eraseToAnyPublisher() }
    
    @Published private(set) var currentLockState: IoTLockState = .unknown(Data())
    var lockState: AnyPublisher<IoTLockState, Never> { $currentLockState.eraseToAnyPublisher() }
    
    @Published private(set) var currentVehicleInfo = IoTVehicleInfo()
    
    @Published private(set) var currentBatteryTelemetry: BatteryTelemetry?
    
    @Published private(set) var currentRSSI: Int = 0
    
    /// Danh sách xe tìm thấy trong quá trình scan
    @Published private(set) var discoveredBikes: [DiscoveredBike] = []
    
    private var centralManager: CBCentralManager!
    private var activeContext: BLEConnectionContext?
    
    private var commandDispatcher: BLECommandDispatcher?
    private var pollingEngine: BLEPollingEngine?
    private let preferences: PreferencesManager
    private var cancellables = Set<AnyCancellable>()
    
    private var isAuthenticating: Bool = false
    private var pendingASKUUID: UUID?
    
    /// Cờ phát hiện Bluetooth đã trải qua poweredOff → poweredOn.
    /// Khi cờ này bật, PHẢI scan mới thay vì dùng cache (tránh MIC failure).
    private var btWasPoweredOff: Bool = false
    
    // Scan timeout & retry
    private var scanTimer: DispatchWorkItem?
    private var scanRetryCount = 0
    private let maxScanRetries = 3
    private let scanTimeoutSeconds: TimeInterval = 6
    
    init(preferences: PreferencesManager = .shared) {
        self.preferences = preferences
        super.init()
        PersistentLogger.shared.markSessionStart()
        setupLogging()
    }
    
    /// Được gọi bởi UI sau khi user đã đọc và đồng ý Disclaimer
    func initializeBluetoothHardware() {
        guard centralManager == nil else { return }
        let queue = DispatchQueue(label: "datbike.core.ble", qos: .userInitiated)
        self.centralManager = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "datbike.core.central",
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }
    
    private func setupLogging() {
        stateMachine.statePublisher
            .sink { state in
                let entry = BLELogEntry(timestamp: Date(), level: .ble, message: "Trạng thái mới: \(state.displayText)")
                PersistentLogger.shared.append(entry)
            }
            .store(in: &cancellables)
            
        $currentLockState
            .dropFirst()
            .sink { lockState in
                let entry = BLELogEntry(timestamp: Date(), level: .info, message: "Trang thái xe: \(lockState.description)")
                PersistentLogger.shared.append(entry)
            }
            .store(in: &cancellables)
    }
    
    func connect() {
        guard let central = centralManager else {
            initializeBluetoothHardware()
            stateMachine.transition(to: .scanning)
            return
        }
        
        let state = central.state
        
        switch state {
        case .poweredOn:
            break
        case .unknown, .resetting:
            stateMachine.transition(to: .scanning)
            return
        case .poweredOff:
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self else { return }
                if self.centralManager.state == .poweredOff {
                    self.stateMachine.transition(to: .error("Bluetooth đang bị tắt. Hãy bật Bluetooth."))
                } else if self.centralManager.state == .poweredOn {
                    self.connect()
                }
            }
            stateMachine.transition(to: .scanning)
            return
        case .unauthorized:
            stateMachine.transition(to: .error("Ứng dụng chưa được cấp quyền Bluetooth."))
            return
        case .unsupported:
            stateMachine.transition(to: .error("Thiết bị không hỗ trợ Bluetooth."))
            return
        @unknown default:
            return
        }
        
        // Reset state cho lần scan mới
        DispatchQueue.main.async {
            self.discoveredBikes = []
        }
        scanRetryCount = 0
        
        // Đã pair trước đó → thử retrieve (giống 7c3227a tryReconnectKnown)
        if preferences.savedPin != nil,
           let savedUUIDStr = preferences.savedPeripheralUUID,
           let savedUUID = UUID(uuidString: savedUUIDStr) {
            
            // ═══ GUARD: Nếu BT vừa bị tắt/bật → BẮT BUỘC scan mới ═══
            // Lý do: iOS cache encryption keys cũ (LTK) cho peripheral UUID.
            // Sau khi BT reset, xe đã xóa keys nhưng iOS vẫn giữ → MIC failure.
            // Scan mới buộc iOS negotiate fresh link-layer encryption.
            if btWasPoweredOff {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "BT vừa power-cycle → bỏ qua cache, scan mới để tránh MIC failure"))
                btWasPoweredOff = false
                startScanWithTimeout(central: central)
                return
            }
            
            // Step 1: retrieveConnectedPeripherals — xe đang kết nối ở tầng iOS?
            let connected = central.retrieveConnectedPeripherals(withServices: BLEService.allServices)
            if let p = connected.first(where: { $0.identifier.uuidString == savedUUIDStr }) {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "Xe đang kết nối (live session): \(p.name ?? savedUUIDStr.prefix(8).description)"))
                connectPeripheral(p, central: central)
                return
            }
            
            // Step 2: retrievePeripherals — lấy từ iOS cache (giống 2e6ad99)
            // Với State Restoration, iOS duy trì encryption context → an toàn connect
            let known = central.retrievePeripherals(withIdentifiers: [savedUUID])
            if let p = known.first {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "Retrieve peripheral từ cache: \(p.name ?? savedUUIDStr.prefix(8).description)"))
                connectPeripheral(p, central: central)
                return
            }
            
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "Không tìm thấy xe trong cache — fallback sang scan"))
        }
        
        startScanWithTimeout(central: central)
    }
    
    func connect(to uuid: UUID) {
        guard let central = centralManager else { return }
        preferences.savedPeripheralUUID = uuid.uuidString
        
        guard central.state == .poweredOn else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "ASK connect: Hoãn gọi API vì Bluetooth chưa poweredOn (\(central.state.rawValue))"))
            self.pendingASKUUID = uuid
            return
        }
        
        let known = central.retrievePeripherals(withIdentifiers: [uuid])
        if let p = known.first {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK Retrieve peripheral thành công: \(p.name ?? uuid.uuidString.prefix(8).description)"))
            connectPeripheral(p, central: central)
        } else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "ASK UUID không tìm thấy trong cache, kích hoạt fallback scan"))
            startScanWithTimeout(central: central)
        }
    }
    
    /// Thiết lập context + kết nối peripheral (dùng chung cho retrieve và scan)
    private func connectPeripheral(_ p: CBPeripheral, central: CBCentralManager) {
        stateMachine.transition(to: .connecting)
        
        let context = BLEConnectionContext(peripheral: p)
        self.activeContext = context
        p.delegate = self
        self.commandDispatcher = BLECommandDispatcher(context: context)
        self.pollingEngine = BLEPollingEngine(context: context)
        self.isAuthenticating = false
        
        central.connect(p, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }
    
    /// Bắt đầu quét BLE với timeout
    private func startScanWithTimeout(central: CBCentralManager) {
        cancelScanTimer()
        
        stateMachine.transition(to: .scanning)
        
        let allowDupes = scanRetryCount > 0
        central.scanForPeripherals(withServices: BLEService.scanUUIDs, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: allowDupes
        ])
        
        // Timer: Hết thời gian quét → kiểm tra kết quả
        let timer = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            central.stopScan()
            
            // Nếu đã tìm thấy xe → dừng, chờ user chọn
            if !self.discoveredBikes.isEmpty {
                return
            }
            
            // Chưa tìm thấy → retry hoặc báo lỗi
            self.scanRetryCount += 1
            if self.scanRetryCount < self.maxScanRetries {
                self.startScanWithTimeout(central: central)
            } else {
                // Hết quota scan -> Không báo chết ngay. 
                // Cắm lệnh kết nối chờ (pending connect) của iOS để nó tự bắt nếu tới gần.
                if let savedUUIDStr = self.preferences.savedPeripheralUUID,
                   let savedUUID = UUID(uuidString: savedUUIDStr) {
                    let known = central.retrievePeripherals(withIdentifiers: [savedUUID])
                    if let p = known.first {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                            message: "Hết hạn quét xe — chuyển sang bám sóng nền (pending connect)"))
                        self.connectPeripheral(p, central: central)
                        return
                    }
                }
                
                self.stateMachine.transition(to: .error("Không tìm thấy xe. Hãy kiểm tra xe đã bật chưa."))
            }
        }
        self.scanTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + scanTimeoutSeconds, execute: timer)
    }
    
    private func cancelScanTimer() {
        scanTimer?.cancel()
        scanTimer = nil
    }
    
    /// User chọn xe từ danh sách → kết nối
    func selectBike(_ bikeId: String) {
        guard let bike = discoveredBikes.first(where: { $0.id == bikeId }),
              let central = centralManager else { return }
        
        cancelScanTimer()
        central.stopScan()
        stateMachine.transition(to: .connecting)
        
        let peripheral = bike.peripheral
        let context = BLEConnectionContext(peripheral: peripheral)
        self.activeContext = context
        peripheral.delegate = self
        
        self.commandDispatcher = BLECommandDispatcher(context: context)
        self.pollingEngine = BLEPollingEngine(context: context)
        self.isAuthenticating = false
        
        central.connect(peripheral, options: nil)
    }
    
    func disconnect() {
        cancelScanTimer()
        centralManager?.stopScan()
        stateMachine.transition(to: .idle)
        pollingEngine?.stopPolling()
        if let ctx = activeContext {
            centralManager?.cancelPeripheralConnection(ctx.peripheral)
        }
        activeContext = nil
        commandDispatcher = nil
        pollingEngine = nil
        isAuthenticating = false
        DispatchQueue.main.async {
            self.discoveredBikes = []
        }
    }
    
    func getDispatcher() throws -> IoTCommandService {
        guard let d = commandDispatcher else { throw IoTError.notConnected }
        return d
    }
    
    /// Đọc telemetry + lock state từ xe
    func queryTelemetry() {
        guard let ctx = activeContext else { return }
        Task {
            do {
                // Đọc Dashboard Telemetry
                if let dashChar = try? ctx.requireCharacteristic(BLECharacteristic.dashboardData) {
                    let data = try await ctx.queue.enqueue {
                        try await ctx.io.readValue(from: dashChar)
                    }
                    let tele = DashboardTelemetry(from: data)
                    DispatchQueue.main.async {
                        self.currentTelemetry.motorTemp = tele.motorTemp
                        self.currentTelemetry.controllerTemp = tele.controllerTemp
                        self.currentTelemetry.odometerKm = tele.odometerKm
                        self.currentTelemetry.speedKmh = tele.speedKmh
                    }
                }
                
                // Đọc Battery SOC (JSON) — cũng cập nhật BMS detail
                await readBatteryJSON(ctx: ctx)
                
                // Đọc Lock State (smartkeyEcho)
                if let echoChar = try? ctx.requireCharacteristic(BLECharacteristic.smartkeyEcho) {
                    let data = try await ctx.queue.enqueue {
                        try await ctx.io.readValue(from: echoChar)
                    }
                    let status = IoTLockState.parse(from: data)
                    DispatchQueue.main.async { self.currentLockState = status }
                }
            } catch {
                PersistentLogger.shared.append(BLELogEntry(
                    timestamp: Date(), level: .warning,
                    message: "Query telemetry lỗi: \(error.localizedDescription)"
                ))
            }
        }
    }
    
    /// Đọc chi tiết BMS — gọi được độc lập từ BatteryViewModel
    func queryBatteryDetail() {
        guard let ctx = activeContext else { return }
        Task {
            await readBatteryJSON(ctx: ctx)
        }
    }
    
    /// Logic chung đọc Battery JSON từ BLE characteristic
    private func readBatteryJSON(ctx: BLEConnectionContext) async {
        do {
            guard let batChar = try? ctx.requireCharacteristic(BLECharacteristic.batteryData) else { return }
            let data = try await ctx.queue.enqueue {
                try await ctx.io.readValue(from: batChar)
            }
            if let json = String(bytes: data, encoding: .utf8) {
                // Log RAW toàn bộ JSON (không truncate) để debug
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "BMS RAW JSON (\(data.count) bytes): \(json)"))
                
                if let jsonData = json.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(BatteryTelemetry.self, from: jsonData) {
                    if let socValue = decoded.soc?.soc {
                        let percent = Int(socValue * 100)
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "Battery SOC: \(socValue) → \(percent)%"))
                        DispatchQueue.main.async {
                            self.currentTelemetry.soc = Float(percent)
                        }
                    }
                    
                    // Log cell voltages nếu có
                    if let cells = decoded.cells {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "BMS Cells: \(cells.count) cells — \(cells.map { String(format: "%.3f", $0) }.joined(separator: ", "))"))
                    }
                    
                    // Log BMS Diagnostics & Core Metrics
                    var diagInfo: [String] = []
                    if let v = decoded.voltage { diagInfo.append("Voltage: \(String(format: "%.1f", v))V") }
                    if let c = decoded.current { diagInfo.append("Current: \(String(format: "%.2f", c))A") }
                    if let fet = decoded.fet { diagInfo.append("FET: \(fet)") }
                    if let err = decoded.error { diagInfo.append("Error: \(err)") }
                    if let bal = decoded.balancing { diagInfo.append("Balancing: \(bal)") }
                    if let prot = decoded.protection { diagInfo.append("Protection: \(prot)") }
                    if let prots = decoded.protections { diagInfo.append("Protections: \(prots)") }
                    if let res = decoded.resistor { diagInfo.append("Resistor: \(res)") }
                    if let dis = decoded.discharge { diagInfo.append("Discharge: \(dis)") }
                    if let chg = decoded.charge { diagInfo.append("Charge: \(chg)") }
                    
                    if !diagInfo.isEmpty {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "BMS Diagnostics: \(diagInfo.joined(separator: " | "))"))
                    }
                    
                    // Log extra keys chưa decode được (giúp discover thêm data)
                    if let extra = decoded.rawExtraKeys, !extra.isEmpty {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                            message: "BMS JSON keys chưa decode: \(extra.joined(separator: ", ")) — cần bổ sung model!"))
                    }
                    
                    DispatchQueue.main.async {
                        self.currentBatteryTelemetry = decoded
                    }
                }
            }
        } catch {
            PersistentLogger.shared.append(BLELogEntry(
                timestamp: Date(), level: .warning,
                message: "Đọc BMS lỗi: \(error.localizedDescription)"
            ))
        }
    }
    
    // MARK: - Auto Unlock Wiring
    private func setupAutoUnlock(engine: BLEPollingEngine) {
        // Forward RSSI to published property for UI
        engine.$currentRSSI
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rssi in
                self?.currentRSSI = Int(rssi)
            }
            .store(in: &cancellables)
        
        engine.$currentRSSI
            .combineLatest(preferences.$autoUnlockEnabled, preferences.$rssiThreshold)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] (rssi, isAutoUnlockOn, threshold) in
                guard let self = self, isAutoUnlockOn else { return }
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
    
    /// State Restoration: iOS khôi phục peripheral khi app bị kill + relaunch
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "State Restoration: khôi phục \(restored.name ?? "unknown") (state: \(restored.state.rawValue))"))
            
            // Lưu UUID để connect() dùng scan nếu cần
            preferences.savedPeripheralUUID = restored.identifier.uuidString
            
            // ═══ CHỈ TIN TƯỞNG peripheral ĐANG CONNECTED ═══
            // state == .connected (2): encryption keys vẫn sống → an toàn dùng tiếp
            // state != .connected (0, 1): kết nối đã đứt → encryption keys CÓ THỂ stale
            //   → KHÔNG dùng làm activeContext, để connect() scan mới tránh MIC failure
            if restored.state == .connected {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "Xe đang kết nối (live session): \(restored.name ?? "unknown")"))
                restored.delegate = self
                let ctx = BLEConnectionContext(peripheral: restored)
                activeContext = ctx
                commandDispatcher = BLECommandDispatcher(context: ctx)
                pollingEngine = BLEPollingEngine(context: ctx)
                stateMachine.transition(to: .connecting)
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "Peripheral restore nhưng đã disconnect (state: \(restored.state.rawValue)) → bỏ qua, sẽ scan mới"))
                // Đánh dấu để connect() biết PHẢI scan mới, không dùng cache
                btWasPoweredOff = true
            }
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // ═══ PHÁT HIỆN power-cycle: nếu BT vừa tắt → xóa sạch context cũ ═══
            if btWasPoweredOff {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "BT poweredOn sau power-cycle → xóa context cũ, chuẩn bị scan mới"))
                // Hủy kết nối cũ nếu có — buộc iOS xóa encryption cache
                if let ctx = activeContext {
                    central.cancelPeripheralConnection(ctx.peripheral)
                }
                activeContext = nil
                commandDispatcher = nil
                pollingEngine = nil
                isAuthenticating = false
                // btWasPoweredOff vẫn giữ = true để connect() biết phải scan
            }
            
            // Nếu đã có activeContext từ willRestoreState VÀ KHÔNG qua power-cycle → discover services
            if let ctx = activeContext, case .connecting = stateMachine.state {
                if ctx.peripheral.state == .connected {
                    // Peripheral vẫn connected → discover ngay
                    ctx.peripheral.discoverServices(BLEService.allServices)
                } else {
                    // Peripheral đã disconnect → reconnect
                    central.connect(ctx.peripheral, options: [
                        CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
                    ])
                }
                return
            }
            
            if let uuid = pendingASKUUID {
                pendingASKUUID = nil
                connect(to: uuid)
                return
            }
            
            // Xử lý thông minh: Cứ có sóng lại, chưa ổn định và đã từng pair -> reconnect cưỡng chế
            if !stateMachine.state.isConnected && preferences.savedPin != nil {
                connect()
            } else if stateMachine.state == .scanning {
                connect()
            }
        case .poweredOff:
            // ═══ ĐÁNH DẤU: BT đã tắt → lần poweredOn tiếp theo phải scan mới ═══
            btWasPoweredOff = true
            if stateMachine.state != .idle {
                cancelScanTimer()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self = self else { return }
                    if self.centralManager.state == .poweredOff && self.stateMachine.state != .idle {
                        self.stateMachine.transition(to: .error("Bluetooth đang bị tắt. Hãy bật Bluetooth."))
                    } else if self.centralManager.state == .poweredOn && self.stateMachine.state == .scanning {
                        self.connect()
                    }
                }
            }
        case .unauthorized:
            if stateMachine.state != .idle {
                stateMachine.transition(to: .error("Ứng dụng chưa được cấp quyền Bluetooth."))
            }
        case .unsupported:
            if stateMachine.state != .idle {
                stateMachine.transition(to: .error("Thiết bị không hỗ trợ Bluetooth."))
            }
        default:
            break
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Scan đã filter theo datBikeService UUID → peripheral ở đây chắc chắn là xe Dat Bike
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let deviceName = peripheral.name ?? advName ?? "Dat Bike"
        
        // Đã pair trước đó (có savedPin) → auto-connect luôn, không cần chọn
        if preferences.savedPin != nil {
            if preferences.connectOnlyWhenNear && Double(RSSI.intValue) < preferences.rssiThreshold {
                return // Bỏ qua sóng yếu, không stopScan, chờ tới gần
            }
            cancelScanTimer()
            central.stopScan()
            connectPeripheral(peripheral, central: central)
            return
        }
        
        // Chưa pair → gom vào danh sách cho user chọn
        let bike = DiscoveredBike(
            peripheral: peripheral,
            name: deviceName,
            rssi: RSSI.intValue
        )
        
        DispatchQueue.main.async {
            if let idx = self.discoveredBikes.firstIndex(where: { $0.id == bike.id }) {
                self.discoveredBikes[idx] = bike
            } else {
                self.discoveredBikes.append(bike)
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(BLEService.allServices)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let errorMsg = error?.localizedDescription ?? "unknown"
        PersistentLogger.shared.append(BLELogEntry(
            timestamp: Date(), level: .error,
            message: "Kết nối thất bại: \(errorMsg)"
        ))
        
        activeContext = nil
        commandDispatcher = nil
        pollingEngine = nil
        isAuthenticating = false
        
        // MIC failure hoặc "Failed to encrypt" = encryption cache lệch
        let isMICFailure = errorMsg.contains("MIC failure")
            || (error as NSError?)?.code == 31
        let isEncryptionFailure = errorMsg.contains("Failed to encrypt")
        
        // Error 14: Peer removed pairing
        if let cbError = error as? CBError, cbError.code == .peerRemovedPairingInformation {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "Xe đã xóa bonding (code 14). Cần ghép đôi lại."))
            preferences.savedPeripheralUUID = nil
            stateMachine.transition(to: .error(
                "Xe đã xóa kết nối BLE.\n" +
                "Vào Cài đặt → Bluetooth → chọn xe → Quên thiết bị này.\n" +
                "Sau đó quay lại app để ghép đôi lại."
            ))
            return
        }
        
        if isMICFailure || isEncryptionFailure {
            PersistentLogger.shared.append(BLELogEntry(
                timestamp: Date(), level: .warning,
                message: "\(isMICFailure ? "MIC failure" : "Encryption failure") → scan mới ngay (không retry cache)"
            ))
            btWasPoweredOff = true // Đánh dấu để connect() biết bỏ qua retrievePeripherals
            stateMachine.transition(to: .scanning)
            if let central = self.centralManager, central.state == .poweredOn {
                self.startScanWithTimeout(central: central)
            }
        } else if scanRetryCount < maxScanRetries {
            scanRetryCount += 1
            startScanWithTimeout(central: central)
        } else {
            stateMachine.transition(to: .error("Kết nối thất bại. Hãy thử lại."))
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        pollingEngine?.stopPolling()
        isAuthenticating = false
        
        guard let error = error else {
            // User-initiated disconnect → dọn dẹp hoàn toàn
            disconnect()
            return
        }
        
        let errorMsg = error.localizedDescription
        let nsError = error as NSError
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
            message: "Ngắt kết nối: \(errorMsg) (code \(nsError.code))"))
        
        // MIC failure từ didDisconnect (iOS có thể fire ở đây thay vì didFailToConnect)
        let isMICFailure = errorMsg.contains("MIC failure") || nsError.code == 31
        if isMICFailure {
            // Delegate lên cùng handler
            activeContext = nil
            commandDispatcher = nil
            pollingEngine = nil
            centralManager(central, didFailToConnect: peripheral, error: error)
            return
        }
        
        // Error 14: Peer removed pairing — xe đã xóa bond, cần ghép lại
        if let cbError = error as? CBError, cbError.code.rawValue == 14 {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "Xe đã xóa bonding (code 14). Cần ghép đôi lại."))
            preferences.savedPeripheralUUID = nil
            activeContext = nil
            commandDispatcher = nil
            pollingEngine = nil
            stateMachine.transition(to: .error(
                "Xe đã xóa kết nối BLE.\n" +
                "Vào Cài đặt → Bluetooth → chọn xe → Quên thiết bị này.\n" +
                "Sau đó quay lại app để ghép đôi lại."
            ))
            return
        }
        
        // Disconnect thông thường → pending reconnect
        stateMachine.transition(to: .scanning)
        central.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
        
        // Fallback: connect() sau 3s
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            if case .scanning = self.stateMachine.state {
                self.connect()
            }
        }
    }
}

extension DatBikeCore: CBPeripheralDelegate {
    
    /// Xử lý khi xe thay đổi GATT table — xóa cache cũ + discover lại
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
            message: "GATT table thay đổi — discover lại services..."))
        // Xóa characteristic cache cũ
        if let ctx = activeContext {
            ctx.clearState()
        }
        isAuthenticating = false
        peripheral.discoverServices(BLEService.allServices)
    }
    
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
        
        // Kích hoạt auth CHỈ KHI ĐỦ cả 3 characteristic cần thiết (có thể nằm ở nhiều service khác nhau)
        if !isAuthenticating,
           (try? ctx.requireCharacteristic(BLECharacteristic.authChallenge)) != nil,
           (try? ctx.requireCharacteristic(BLECharacteristic.timeSync)) != nil,
           (try? ctx.requireCharacteristic(BLECharacteristic.autoUnlock)) != nil {
            isAuthenticating = true
            
            if let savedPin = PreferencesManager.shared.savedPin, !savedPin.isEmpty {
                executeAuthProtocol(ctx: ctx, pin: savedPin)
            } else {
                stateMachine.transition(to: .pairingRequired)
            }
        }
    }
    
    func submitPairingPin(_ pin: String) {
        guard stateMachine.state == .pairingRequired, let ctx = activeContext else { return }
        PreferencesManager.shared.savedPin = pin
        executeAuthProtocol(ctx: ctx, pin: pin, isKnownDevice: false)
    }
    
    private func executeAuthProtocol(ctx: BLEConnectionContext, pin: String, isKnownDevice: Bool = true) {
        let authenticator = BLEAuthenticator(context: ctx, pin: pin, isKnownDevice: isKnownDevice)
        
        Task {
            do {
                stateMachine.transition(to: .authenticating)
                _ = try await authenticator.authenticate()
                
                if let engine = self.pollingEngine {
                    engine.startPolling()
                    self.setupAutoUnlock(engine: engine)
                }
                
                stateMachine.transition(to: .active)
                NotificationManager.shared.sendConnectNotification(bikeName: ctx.peripheral.name ?? "Xe máy điện DATBIKE")
                
                // Lưu UUID để lần sau dùng retrievePeripherals (tránh MIC failure)
                if let ctx = self.activeContext {
                    self.preferences.savedPeripheralUUID = ctx.peripheral.identifier.uuidString
                }
                
                // Post-auth: đọc lock status + device info + telemetry
                self.readLockStatus()
                self.readDeviceInfo()
                self.queryTelemetry()
                
                // Auto sync time 1 lần/ngày
                if self.preferences.needsTimeSyncToday, let dispatcher = self.commandDispatcher {
                    Task {
                        do {
                            try await dispatcher.syncTime()
                            self.preferences.lastTimeSyncDate = Date()
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                                message: "Auto time sync hàng ngày ✅"))
                        } catch {
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                                message: "Auto time sync thất bại: \(error.localizedDescription)"))
                        }
                    }
                }
            } catch IoTError.shaChallengeFailed {
                disconnect()
                stateMachine.transition(to: .error("Xác thực thất bại. Thử lại hoặc tắt/bật Bluetooth."))
            } catch {
                disconnect()
                stateMachine.transition(to: .error("Lỗi xác thực: \(error.localizedDescription)"))
            }
        }
    }
    
    // MARK: - Post-Auth Data Reads
    
    /// Public — gọi từ ViewModel sau khi bật/tắt xe để cập nhật dashboard
    func refreshLockState() {
        readLockStatus()
    }
    
    private func readLockStatus() {
        guard let ctx = activeContext else { return }
        Task {
            if let char = try? ctx.requireCharacteristic(BLECharacteristic.smartkeyEcho) {
                do {
                    let data = try await ctx.queue.enqueue {
                        try await ctx.io.readValue(from: char)
                    }
                    let status = IoTLockState.parse(from: data)
                    DispatchQueue.main.async { self.currentLockState = status }
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "Trang thái xe: \(status.description) (raw: \(data.hexString))"))
                } catch {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "Đọc lock status lỗi: \(error.localizedDescription)"))
                }
            }
        }
    }
    
    private func readDeviceInfo() {
        guard let ctx = activeContext else { return }
        Task {
            var name = ""
            var serial = ""
            var model = ""
            var fw = ""
            
            // Device name (vehicleStatus)
            if let char = try? ctx.requireCharacteristic(BLECharacteristic.vehicleStatus),
               let data = try? await ctx.queue.enqueue(task: { try await ctx.io.readValue(from: char) }),
               let str = String(data: data, encoding: .utf8) {
                name = str.trimmingCharacters(in: .controlCharacters)
            }
            
            // Serial
            if let char = try? ctx.requireCharacteristic(BLECharacteristic.deviceSerialAlt),
               let data = try? await ctx.queue.enqueue(task: { try await ctx.io.readValue(from: char) }),
               let str = String(data: data, encoding: .utf8) {
                serial = str.trimmingCharacters(in: .controlCharacters)
            }
            
            // Model
            if let char = try? ctx.requireCharacteristic(BLECharacteristic.deviceModelAlt),
               let data = try? await ctx.queue.enqueue(task: { try await ctx.io.readValue(from: char) }),
               let str = String(data: data, encoding: .utf8) {
                model = str.trimmingCharacters(in: .controlCharacters)
            }
            
            // Firmware version
            if let char = try? ctx.requireCharacteristic(BLECharacteristic.fwVersion),
               let data = try? await ctx.queue.enqueue(task: { try await ctx.io.readValue(from: char) }),
               let str = String(data: data, encoding: .utf8) {
                fw = str.trimmingCharacters(in: .controlCharacters)
            }
            
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                message: "Xe: \(name) / \(model) / \(serial) / FW: \(fw)"))
            
            DispatchQueue.main.async {
                self.currentVehicleInfo = IoTVehicleInfo(
                    name: name.isEmpty ? "Dat Bike" : name,
                    serialNumber: serial,
                    modelNumber: model,
                    firmwareVersion: fw
                )
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { await activeContext?.io.didReceiveReadResponse(for: characteristic, error: error) }
        
        if characteristic.uuid == BLECharacteristic.smartkeyEcho {
            if let data = characteristic.value {
                DispatchQueue.main.async {
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
