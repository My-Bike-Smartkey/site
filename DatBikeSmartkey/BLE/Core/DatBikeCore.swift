import Foundation
import CoreBluetooth
import Combine
import UIKit
import WidgetKit
import os.log

private let widgetLogger = Logger(subsystem: "app.mybike.smartkey", category: "WidgetSync")

/// LỚP BỌC TỐI THƯỢNG (FACADE) - MANAGER MỚI (V2)
class DatBikeCore: NSObject, IoTCoordinatorProtocol, @unchecked Sendable {
    
    /// Singleton — đảm bảo CBCentralManager tồn tại xuyên suốt lifecycle (kể cả background relaunch)
    static let shared = DatBikeCore()
    
    private let stateMachine = BLEStateMachine()
    var connectionState: AnyPublisher<IoTConnectionState, Never> { stateMachine.statePublisher }
    
    @Published private(set) var currentTelemetry = IoTTelemetryData()
    var telemetryData: AnyPublisher<IoTTelemetryData, Never> { $currentTelemetry.eraseToAnyPublisher() }
    
    @Published private(set) var currentLockState: IoTLockState = .unknown(Data())
    var lockState: AnyPublisher<IoTLockState, Never> { $currentLockState.eraseToAnyPublisher() }
    
    @Published private(set) var currentVehicleInfo = IoTVehicleInfo()
    
    @Published private(set) var currentBatteryTelemetry: BatteryTelemetry?
    private var previousBatteryTelemetry: BatteryTelemetry?
    
    @Published private(set) var currentRSSI: Int = 0
    
    /// Danh sách xe tìm thấy trong quá trình scan
    @Published private(set) var discoveredBikes: [DiscoveredBike] = []
    
    private var centralManager: CBCentralManager!
    private var activeContext: BLEConnectionContext?
    
    private var commandDispatcher: BLECommandDispatcher?
    private var pollingEngine: BLEPollingEngine?
    private let preferences: PreferencesManager
    private var cancellables = Set<AnyCancellable>()
    private var engineCancellables = Set<AnyCancellable>()
    private var lastLoggedVehicleString: String = ""
    
    var isAuthenticating = false
    private var pendingASKUUID: UUID?
    
    /// Cờ phát hiện Bluetooth đã trải qua poweredOff → poweredOn.
    /// Khi cờ này bật, PHẢI scan mới thay vì dùng cache (tránh MIC failure).
    private var btWasPoweredOff: Bool = false
    
    /// Cờ riêng biệt: peripheral stale (disconnect sau State Restoration),
    /// buộc scan mới dù BT không bị power-cycle.
    private var forceFullScan: Bool = false
    
    // Proximity Standby Timer
    private var standbyTimer: Timer?
    private var lastRssiLogTime: Date?
    
    // Scan timeout & retry
    private var scanTimer: DispatchWorkItem?
    private var scanRetryCount = 0
    private let maxScanRetries = 2
    private let scanTimeoutSeconds: TimeInterval = 4
    
    // Connecting state timeout — phòng trường hợp discoverServices không phản hồi (phantom connection)
    private var connectingTimer: DispatchWorkItem?
    
    // Disconnect fallback timer — cancel khi didConnect để tránh double-scan
    private var disconnectFallbackTimer: DispatchWorkItem?
    
    // Auth task reference — cancel khi disconnect để tránh stale state transitions
    private var authTask: Task<Void, Never>?
    
    // MIC failure retry limit
    private var micRetryCount = 0
    private let maxMicRetries = 3
    
    // Guard chống downgradeToStandby chạy trùng lặp
    private var isDowngrading = false
    
    /// Guard chống SESSION_CHECK / tryRestoreActiveSession bị gọi 2 lần (race condition).
    private var isRestoringSession = false
    
    /// Đếm số lần Phantom Guard timeout liên tiếp — dùng cho exponential backoff.
    private var phantomGuardFailCount = 0
    private let maxPhantomGuardBackoffSeconds: TimeInterval = 30.0
    
    // Thời điểm lần cuối chuyển sang .active — chống auth-standby loop
    private var lastActiveTime: Date?
    
    // Background execution state
    private var isAppInBackground = false
    
    // Quản lý CPU nền
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    
    // Cờ kết thúc "Phiên Auto": Bất cứ tương tác thủ công nào (Force Connect, Bật/Tắt xe) sẽ đình chỉ tính năng Auto (bật, tắt, kết nối) cho đến khi Bluetooth mất kết nối vật lý (reset phiên).
    private(set) var isSessionAutoSuspended = false
    private var shouldTurnOnBikeAfterAuth = false
    
    func suspendAutoFeatures() {
        self.isSessionAutoSuspended = true
    }
    
    private override init() {
        self.preferences = PreferencesManager.shared
        super.init()
        PersistentLogger.shared.markSessionStart()
        setupLogging()
        setupBatteryMonitoring()
        
        // ═══ KHÔNG gọi initializeBluetoothHardware() ở đây ═══
        // AppDelegate.didFinishLaunchingWithOptions sẽ gọi — đảm bảo hoạt động
        // cả khi iOS relaunch app trong background (State Restoration).
        
        if #available(iOS 18.0, *) {
            ASKManager.shared.onAccessorySelected = { [weak self] uuid in
                DispatchQueue.main.async {
                    self?.initializeBluetoothHardware()
                    self?.connect(to: uuid)
                }
            }
        }
    }
    
    private func extendBackgroundExecutionTime() {
        if bgTask != .invalid { return }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .verbose, message: "[SYSTEM] Xin cấp thêm thời gian CPU chạy ngầm (Begin Background Task)"))
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "DatBikeBLE") { [weak self] in
            guard let self = self else { return }
            UIApplication.shared.endBackgroundTask(self.bgTask)
            self.bgTask = .invalid
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning, message: "[SYSTEM] Bị hệ điều hành thu hồi CPU nền (Background Task Expired). App có thể bị suspend ngay lập tức."))
        }
    }
    
    private func stopBackgroundExecutionTime() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .verbose, message: "[SYSTEM] Trả lại CPU nền cho hệ thống (End Background Task)"))
        }
    }
    
    /// Được gọi bởi UI sau khi user đã đọc và đồng ý Disclaimer
    func initializeBluetoothHardware() {
        guard centralManager == nil else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[INIT] initializeBluetoothHardware() bỏ qua — centralManager đã tồn tại"))
            return
        }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[INIT] Khởi tạo CBCentralManager | savedUUID=\(preferences.savedPeripheralUUID?.prefix(8).description ?? "nil") | savedPin=\(preferences.savedPin != nil ? "có" : "nil") | connectOnlyWhenNear=\(preferences.connectOnlyWhenNear)"))
        let queue = DispatchQueue(label: "datbike.core.ble", qos: .userInitiated)
        self.centralManager = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "DatBikeCentralManagerRestoreID",
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
        
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        standbyTimer?.invalidate()
    }
    
    private func setupLogging() {
        stateMachine.statePublisher
            .sink { state in
                let entry = BLELogEntry(timestamp: Date(), level: .info, message: "State transitioned to: \(state.displayText)")
                PersistentLogger.shared.append(entry)
            }
            .store(in: &cancellables)
            
        $currentLockState
            .dropFirst()
            .removeDuplicates()
            .sink { _ in
                // Log trang thai xe CHINH THUC chi thuc hien trong readLockStatus() (co raw:)
                // de tranh log trung lap khi set tu nhieu luong khac nhau.
            }
            .store(in: &cancellables)
            
        setupWidgetSync()
    }
    
    private func setupWidgetSync() {
        // Pipeline duy nhất: Ghi data VÀ báo reload Widget ngay trong cùng 1 sink.
        // Tránh race condition khi dùng 2 pipeline riêng (ghi và reload có thể lệch nhịp).
        Publishers.CombineLatest4(stateMachine.statePublisher, $currentLockState, $currentTelemetry, $currentVehicleInfo)
            // Bỏ qua những thay đổi quá nhanh liên tiếp (VD: nhiều transition BLE)
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            // So sánh toàn bộ tuple để tránh reload thừa khi không có gì thay đổi thực chất
            .sink { [weak self] (connState, lock, telemetry, vehicleInfo) in
                guard let self = self else { return }
                
                // Suy ra chuỗi trạng thái cho Widget ĐỒNG BỘ với logic của DashboardView.statusText
                let stateString: String = {
                    if self.isSessionAutoSuspended && (connState == .connecting || connState == .scanning) {
                        return IoTConnectionState.standby.displayText
                    }
                    // Ưu tiên lockState khi đã kết nối (giống Dashboard)
                    if connState == .active || connState == .standby {
                        switch lock {
                        case .unlocked: return "Xe đang bật"
                        case .armed:    return "Xe đã bật chống trộm"
                        case .locked:   return connState == .standby ? "Kết nối chờ (Chờ gần)" : "Xe đang tắt"
                        default:        return connState.displayText
                        }
                    }
                    return connState.displayText
                }()
                
                let battery = Int(telemetry.soc)
                let realBikeName = vehicleInfo.name.isEmpty || vehicleInfo.name == "Dat Bike" ? nil : vehicleInfo.name
                
                // Ghi vào shared UserDefaults
                self.preferences.widgetCurrentState = stateString
                self.preferences.widgetBatteryLevel = battery
                if let name = realBikeName {
                    self.preferences.sharedDefaults.set(name, forKey: "widgetBikeName")
                }
                
                var shared = SharedBikeState()
                shared.isConnected = (connState == .active || connState == .standby)
                shared.connectionPhase = connState == .active ? "ready" : (connState == .standby ? "standby" : "disconnected")
                shared.lockStatusRaw = lock == .unlocked ? "unlocked" : (lock == .armed ? "armed" : "locked")
                shared.bikeName = realBikeName ?? "Dat Bike"
                shared.batteryPercent = battery
                shared.odometerKm = telemetry.odometerKm
                shared.motorTemp = telemetry.motorTemp
                shared.lastUpdated = Date()
                shared.save()

                // KHÔNG gọi synchronize() — trên iOS 12+ App Group UserDefaults tự đồng bộ.
                // Gọi synchronize() sẽ gây "detaching from cfprefsd" làm Widget Extension không đọc được data.

                // Báo Widget reload NGAY SAU KHI data đã được ghi
                widgetLogger.info("[App→Widget] Ghi xong. state='\(stateString)' lock='\(shared.lockStatusRaw)' battery=\(battery) → gọi reloadAllTimelines()")
                WidgetCenter.shared.reloadAllTimelines()
                
                if #available(iOS 16.1, *) {
                    // ═══ GUARD: Không gọi Live Activity khi app ở background ═══
                    // iOS trả lỗi "Target is not foreground" mỗi lần → spam log vô nghĩa.
                    if !self.isAppInBackground {
                        if connState == .active || connState == .authenticating || connState == .connecting {
                            LiveActivityManager.shared.startActivity(
                                bikeName: realBikeName ?? "Dat Bike",
                                lockState: lock.description,
                                connectionState: stateString,
                                batteryLevel: battery
                            )
                        } else {
                            LiveActivityManager.shared.endActivity()
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    func connect() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[CONNECT] Bắt đầu | central=\(centralManager == nil ? "nil" : "có") | activeCtx=\(activeContext == nil ? "nil" : activeContext!.peripheral.identifier.uuidString.prefix(8).description) | peripheralState=\(activeContext?.peripheral.state.rawValue ?? -1) | smState=\(stateMachine.state.displayText) | btPowerOff=\(btWasPoweredOff) | forceScan=\(forceFullScan) | isAuth=\(isAuthenticating) | isBackground=\(isAppInBackground) | autoSuspended=\(isSessionAutoSuspended)"))
        guard let central = centralManager else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[CONNECT] centralManager==nil → gọi initializeBluetoothHardware()"))
            initializeBluetoothHardware()
            if activeContext == nil {
                stateMachine.transition(to: .scanning)
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[CONNECT] willRestoreState đã set activeContext → giữ nguyên state (\(stateMachine.state.displayText))"))
            }
            return
        }
        
        // ═══ GUARD: Kiểm tra peripheral.state (không dùng stateMachine.state) ═══
        // Lý do: stateMachine.state có thể bị override về .scanning sau khi willRestoreState
        // đã set chính xác .connecting (do thứ tự bất định của CBCentralManager init).
        // peripheral.state là giá trị vật lý từ iOS — tin cậy hơn.
        if let ctx = activeContext,
           ctx.peripheral.state == .connected || ctx.peripheral.state == .connecting {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "connect() bỏ qua: peripheral đang kết nối (state=\(ctx.peripheral.state.rawValue))"))
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
                    self.stateMachine.transition(to: .error("Bluetooth đang tắt. Xin bật lại."))
                } else if self.centralManager.state == .poweredOn {
                    self.connect()
                }
            }
            stateMachine.transition(to: .scanning)
            return
        case .unauthorized:
            stateMachine.transition(to: .error("Chưa cấp quyền Bluetooth cho ứng dụng."))
            return
        case .unsupported:
            stateMachine.transition(to: .error("Thiết bị không hỗ trợ Bluetooth LE."))
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
            
            // ═══ GUARD: Nếu BT vừa tắt/bật HOẶC peripheral stale → BẮT BUỘC scan mới ═══
            // btWasPoweredOff: BT power-cycle → iOS cache encryption keys cũ → MIC failure
            // forceFullScan:   Peripheral stale (State Restoration disconnect)
            // Cả 2 đều yêu cầu scan mới để iOS negotiate fresh link-layer encryption.
            if btWasPoweredOff || forceFullScan {
                let reason = btWasPoweredOff ? "BT power-cycle" : "peripheral stale (State Restoration)"
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "\(reason) → bỏ qua cache, scan mới để tránh MIC failure"))
                btWasPoweredOff = false
                forceFullScan = false
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
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[ASK_CONNECT] uuid=\(uuid.uuidString.prefix(8)) | central=\(centralManager == nil ? "nil" : "state=\(centralManager!.state.rawValue)") | btPowerOff=\(btWasPoweredOff)"))
        guard let central = centralManager else { return }
        preferences.savedPeripheralUUID = uuid.uuidString
        
        if let ctx = activeContext,
           ctx.peripheral.state == .connected || ctx.peripheral.state == .connecting {
            // B7 FIX: Hủy Phantom Guard nếu đang chạy — ASK sẽ tự quản lý connection lifecycle
            // App đã bắt đầu connect() nhưng ASK Session Activated mới fire — tin tưởng ASK hơn
            let wasTimerActive = connectingTimer != nil
            cancelConnectingTimeout()
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[ASK_CONNECT] Bỏ qua: peripheral đang kết nối (state=\(ctx.peripheral.state.rawValue)) | phantomGuardCancelled=\(wasTimerActive) | smState=\(stateMachine.state.displayText)"))
            return
        }
        
        guard central.state == .poweredOn else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[ASK_CONNECT] BT chưa poweredOn (state=\(central.state.rawValue)) → lưu pendingASKUUID"))
            self.pendingASKUUID = uuid
            return
        }
        
        // ═══ GUARD: Nếu BT vừa power-cycle → PHẢI scan mới, không dùng retrieved cache ═══
        // Lý do: iOS giữ encryption keys cũ trong retrieved peripheral nhưng xe đã xóa → MIC failure.
        // (Giống guard tương tự trong connect() không tham số.)
        if btWasPoweredOff {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK connect: BT power-cycle → bỏ qua cache, scan mới để tránh encryption failure"))
            btWasPoweredOff = false
            startScanWithTimeout(central: central)
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
        cancelScanTimer()
        
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[CONNECT_PERIPHERAL] name=\(p.name ?? "nil") | uuid=\(p.identifier.uuidString.prefix(8)) | peripheralState=\(p.state.rawValue) | centralState=\(central.state.rawValue)"))
        
        // ═══ GUARD: Tránh connect khi peripheral đang trong quá trình .disconnecting ═══
        // iOS chưa dọn xong link-layer → connect ngay sẽ gây phantom connection + MIC failure.
        // Chờ 1.5s để iOS hoàn tất ngắt kết nối rồi mới connect lại.
        if p.state == .disconnecting {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[CONNECT_PERIPHERAL] Peripheral đang .disconnecting → chờ 1.5s rồi connect lại"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let central = self.centralManager, central.state == .poweredOn else { return }
                self.connectPeripheral(p, central: central)
            }
            return
        }
        
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
        
        startConnectingTimeout()
    }
    
    /// Bắt đầu quét BLE với timeout
    private func startScanWithTimeout(central: CBCentralManager) {
        cancelScanTimer()
        
        // B3 FIX: Reset btWasPoweredOff ngay khi bắt đầu scan để tránh stale flag
        let wasPowerCycle = btWasPoweredOff
        btWasPoweredOff = false
        
        let allowDupes = scanRetryCount > 0
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[SCAN] Bắt đầu quét | retry=\(scanRetryCount)/\(maxScanRetries) | allowDupes=\(allowDupes) | timeout=\(scanTimeoutSeconds)s | wasPowerCycle=\(wasPowerCycle) | isBackground=\(isAppInBackground) | phantomFails=\(phantomGuardFailCount)"))
        stateMachine.transition(to: .scanning)
        
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
                // Hết quota scan -> Cắm lệnh kết nối chờ (pending connect) của iOS.
                // ═══ GUARD: Nếu đang trong trạng thái power-cycle, KHÔNG dùng cache ═══
                // Dùng cache sau power-cycle sẽ gây encryption failure / MIC failure.
                if self.btWasPoweredOff {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "Hết hạn quét xe (power-cycle) — tiếp tục scan, không dùng cache"))
                    self.scanRetryCount = 0
                    self.startScanWithTimeout(central: central)
                    return
                }
                
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
    
    /// Timeout guard cho trạng thái .connecting trong State Restoration
    /// Nếu 5.0s mà không chuyển sang .standby/.active → là kết nối phantom, hủy và reconnect
    private func startConnectingTimeout() {
        cancelConnectingTimeout()
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[PHANTOM_GUARD] Bắt đầu connecting timeout 5.0s | peripheral=\(activeContext?.peripheral.identifier.uuidString.prefix(8).description ?? "nil") | peripheralState=\(activeContext?.peripheral.state.rawValue ?? -1) | failCount=\(phantomGuardFailCount)"))
        let timer = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard case .connecting = self.stateMachine.state else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .verbose,
                    message: "[PHANTOM_GUARD] Timeout fire nhưng state=\(self.stateMachine.state.displayText) → bỏ qua"))
                return
            }
            
            // B5 FIX: Exponential backoff — chờ lâu dần mỗi lần thất bại liên tiếp
            self.phantomGuardFailCount += 1
            let backoffDelay = min(Double(self.phantomGuardFailCount) * 2.0, self.maxPhantomGuardBackoffSeconds)
            
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[PHANTOM_GUARD] Timeout 5.0s! | uuid=\(self.activeContext?.peripheral.identifier.uuidString.prefix(8).description ?? "nil") | peripheralState=\(self.activeContext?.peripheral.state.rawValue ?? -1) | failCount=\(self.phantomGuardFailCount) | backoffDelay=\(backoffDelay)s"))
            
            if let ctx = self.activeContext, let central = self.centralManager {
                central.cancelPeripheralConnection(ctx.peripheral)
            }
            self.activeContext = nil
            self.commandDispatcher = nil
            self.pollingEngine = nil
            self.isAuthenticating = false
            self.forceFullScan = true
            
            if backoffDelay > 0 {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[PHANTOM_GUARD] Backoff \(backoffDelay)s trước khi scan lại (lần thất bại thứ \(self.phantomGuardFailCount))"))
                DispatchQueue.main.asyncAfter(deadline: .now() + backoffDelay) { [weak self] in
                    self?.connect()
                }
            } else {
                self.connect()
            }
        }
        self.connectingTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timer)
    }
    
    private func cancelConnectingTimeout() {
        connectingTimer?.cancel()
        connectingTimer = nil
    }
    
    /// User chọn xe từ danh sách → kết nối
    func selectBike(_ bikeId: String) {
        guard let bike = discoveredBikes.first(where: { $0.id == bikeId }),
              let central = centralManager else { return }
        
        cancelScanTimer()
        central.stopScan()
        
        // Cleanup context cũ để tránh orphan BLETaskQueue/BLECharacteristicIO
        pollingEngine?.stopPolling()
        if let oldCtx = activeContext {
            central.cancelPeripheralConnection(oldCtx.peripheral)
            oldCtx.clearState()
        }
        
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
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[DISCONNECT] Gọi disconnect() | smState=\(stateMachine.state.displayText) | activeCtx=\(activeContext?.peripheral.identifier.uuidString.prefix(8).description ?? "nil") | authTask=\(authTask != nil ? "đang chạy" : "nil") | isAuth=\(isAuthenticating)"))
        cancelScanTimer()
        cancelConnectingTimeout()
        disconnectFallbackTimer?.cancel()
        disconnectFallbackTimer = nil
        centralManager?.stopScan()
        stateMachine.transition(to: .idle)
        pollingEngine?.stopPolling()
        authTask?.cancel()
        authTask = nil
        if let ctx = activeContext {
            centralManager?.cancelPeripheralConnection(ctx.peripheral)
        }
        activeContext = nil
        commandDispatcher = nil
        pollingEngine = nil
        isAuthenticating = false
        standbyTimer?.invalidate()
        standbyTimer = nil
        DispatchQueue.main.async {
            self.discoveredBikes = []
        }
    }
    
    func forceAuthenticate(turnOn: Bool = false) {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[FORCE_AUTH] turnOn=\(turnOn) | smState=\(stateMachine.state.displayText) | activeCtx=\(activeContext != nil) | savedPin=\(preferences.savedPin != nil ? "có" : "nil")"))
        self.isSessionAutoSuspended = true
        if turnOn {
            self.shouldTurnOnBikeAfterAuth = true
        }
        
        if stateMachine.state == .standby {
            standbyTimer?.invalidate()
            standbyTimer = nil
            isAuthenticating = true
            if let ctx = self.activeContext, let pin = self.preferences.savedPin {
                self.executeAuthProtocol(ctx: ctx, pin: pin)
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "[FORCE_AUTH] Không thể auth: ctx=\(activeContext != nil) pin=\(preferences.savedPin != nil)"))
            }
        }
    }
    
    func wakeUpFromStandby() {
        self.isSessionAutoSuspended = true
        if stateMachine.state == .standby {
            forceAuthenticate(turnOn: true)
        } else {
            shouldTurnOnBikeAfterAuth = true
            connect()
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
                    
                    if data.count >= 40 {
                        let tele = DashboardTelemetry(from: data)
                        DispatchQueue.main.async {
                            self.currentTelemetry.motorTemp = tele.motorTemp
                            self.currentTelemetry.controllerTemp = tele.controllerTemp
                            self.currentTelemetry.odometerKm = tele.odometerKm
                            self.currentTelemetry.speedKmh = tele.speedKmh
                        }
                    } else if data.count >= 13 {
                        let tele = BLETelemetryParser.parseTelemetry(from: data)
                        DispatchQueue.main.async {
                            self.currentTelemetry.motorTemp = tele.motorTemp
                            self.currentTelemetry.controllerTemp = tele.controllerTemp
                            self.currentTelemetry.odometerKm = tele.odometerKm
                            self.currentTelemetry.speedKmh = tele.speedKmh
                        }
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
                // Parse JSON
                if let jsonData = json.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(BatteryTelemetry.self, from: jsonData) {
                    if let socValue = decoded.soc?.soc {
                        let percent = Int(socValue * 100)
                        DispatchQueue.main.async {
                            self.currentTelemetry.soc = Float(percent)
                        }
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
        engineCancellables.removeAll()
        
        // Forward RSSI to published property for UI
        engine.$currentRSSI
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rssi in
                self?.currentRSSI = Int(rssi)
            }
            .store(in: &engineCancellables)
        
        engine.$currentRSSI
            .combineLatest($currentLockState, preferences.$autoUnlockEnabled, preferences.$autoTurnOnThreshold)
            .sink { [weak self] (rssi, lockState, isAutoUnlockOn, threshold) in
                // Yêu cầu: Tính năng này chỉ cho phép dùng khi sử dụng ngưỡng kết nối (connectOnlyWhenNear = true)
                guard let self = self, isAutoUnlockOn, self.preferences.connectOnlyWhenNear else { return }
                guard !self.isSessionAutoSuspended else { return } // Nếu user đã can thiệp thủ công (nhấn nút), đình chỉ auto-turn on
                
                // Yêu cầu: Tính năng này chỉ hoạt động khi thoả ngưỡng
                if rssi >= threshold, lockState == .locked {
                    self.isSessionAutoSuspended = true // Khi đã auto-turn on rồi, xem như khoá auto các tác vụ tiếp theo (vào trạng thái manual riding)
                    Task {
                        try? await self.commandDispatcher?.turnOnBike()
                        NotificationManager.shared.sendNotification(
                            title: "Trạng thái xe",
                            body: "Gần xe, tự động bật xe",
                            identifier: "AutoTurnOn"
                        )
                    }
                }
            }
            .store(in: &engineCancellables)
            
        // Logic downgrading từ Active về Standby khi rời khỏi xe
        // ═══ FIX: dropFirst(3) + debounce để tránh fire trên giá trị khởi tạo ═══
        // Khi subscribe, Combine fire giá trị hiện tại ngay → RSSI = 0 (khởi tạo)
        // → trigger downgrade ngay lập tức → auth-standby loop vô hạn.
        // dropFirst bỏ qua 3 giá trị đầu (subscribe init + ~1s warm-up).
        // debounce đợi 2s ổn định trước khi hành động.
        engine.$currentRSSI
            .dropFirst(3)
            .combineLatest($currentLockState, preferences.$rssiThreshold, preferences.$connectOnlyWhenNear)
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] (rssi, lockState, threshold, connectOnlyWhenNear) in
                guard let self = self, connectOnlyWhenNear else { return }
                guard !self.isSessionAutoSuspended else { return } // Đình chỉ auto-downgrade nếu user đã can thiệp
                
                if lockState == .locked || lockState == .armed {
                    let farThreshold = threshold - 3.0 // Vừa bước ra khỏi vùng kết nối 3dBm sẽ ngắt
                    if rssi < farThreshold && self.stateMachine.state == .active {
                        self.downgradeToStandby()
                    }
                }
            }
            .store(in: &engineCancellables)
    }
    
    // MARK: - Battery Monitoring Wiring
    private func setupBatteryMonitoring() {
        $currentBatteryTelemetry
            .dropFirst() // Bỏ qua giá trị nil khởi tạo
            .sink { [weak self] current in
                guard let self = self, let current = current else { return }
                guard let previous = self.previousBatteryTelemetry else {
                    self.previousBatteryTelemetry = current
                    return
                }
                
                // 1. Cảnh báo sạc đầy
                if self.preferences.notifyOnBatteryFull {
                    if previous.socPercent < 100 && current.socPercent == 100 {
                        NotificationManager.shared.sendNotification(
                            title: "Pin đã đầy",
                            body: "Xe Datbike của bạn đã sạc đầy 100%.",
                            identifier: NotificationCategory.batteryFull.rawValue
                        )
                    }
                }
                
                // 2. Cảnh báo pin chạm ngưỡng
                if self.preferences.notifyOnBatteryThreshold {
                    let threshold = self.preferences.batteryLowThreshold
                    if previous.socPercent > threshold && current.socPercent <= threshold {
                        NotificationManager.shared.sendNotification(
                            title: "Pin yếu",
                            body: "Dung lượng pin xe đã giảm xuống \(current.socPercent)%. Vui lòng sạc xe sớm.",
                            identifier: NotificationCategory.batteryLow.rawValue
                        )
                    }
                }
                
                // 3. Báo động mất sạc (Chuyển trạng thái từ Đang sạc sang trạng thái khác khi xe đang tắt)
                if self.preferences.notifyOnChargeDisconnect {
                    if previous.chargingState == .charging && current.chargingState != .charging {
                        if self.currentLockState == .locked || self.currentLockState == .armed {
                            NotificationManager.shared.sendNotification(
                                title: "Cảnh báo ngắt sạc!",
                                body: "Nguồn sạc của xe đã bị ngắt bất ngờ trong khi xe đang tắt.",
                                identifier: NotificationCategory.chargeDisconnect.rawValue
                            )
                        }
                    }
                }
                
                self.previousBatteryTelemetry = current
            }
            .store(in: &cancellables)
    }
    
    func forceStandbyOverride() {
        guard stateMachine.state == .active else { return }
        isSessionAutoSuspended = true
        downgradeToStandby(force: true)
    }
    
    private func downgradeToStandby(force: Bool = false) {
        guard !isDowngrading else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[DOWNGRADE] Bỏ qua — isDowngrading=true (chống chồng chéo)"))
            return
        }
        
        let activeDuration = lastActiveTime.map { Date().timeIntervalSince($0) }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[DOWNGRADE] force=\(force) | smState=\(stateMachine.state.displayText) | RSSI=\(currentRSSI) | threshold=\(preferences.rssiThreshold) | activeDuration=\(String(format: "%.1f", activeDuration ?? -1))s | isBackground=\(isAppInBackground) | autoSuspended=\(isSessionAutoSuspended)"))
        
        if !force {
            guard let lastActive = self.lastActiveTime,
                  Date().timeIntervalSince(lastActive) > 5.0 else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[DOWNGRADE] Bỏ qua — cooldown 5s chưa hết (\(String(format: "%.1f", activeDuration ?? 0))s)"))
                return
            }
        }
        
        isDowngrading = true
        defer { isDowngrading = false }
        
        pollingEngine?.stopPolling()
        isAuthenticating = false
        
        NotificationManager.shared.sendNotification(
            title: "Trạng thái kết nối",
            body: "Phát hiện di chuyển ra xa, chuyển trạng thái chờ",
            identifier: "DowngradeToStandby"
        )
        
        if isAppInBackground {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[DOWNGRADE/BG] Background path → pending connect | peripheral=\(activeContext?.peripheral.identifier.uuidString.prefix(8).description ?? "nil") | peripheralState=\(activeContext?.peripheral.state.rawValue ?? -1)"))
            if let ctx = activeContext, let central = centralManager {
                let peripheral = ctx.peripheral
                central.cancelPeripheralConnection(peripheral)
                activeContext = nil
                commandDispatcher = nil
                pollingEngine = nil
                stateMachine.transition(to: .scanning)
                central.connect(peripheral, options: [
                    CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
                ])
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "[DOWNGRADE/BG] Không có activeContext → fallback connect()"))
                connect()
            }
            return
        }
        
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "Hạ kết nối về Standby (Xoá phiên xác thực nội bộ)..."))
            
        if let ctx = activeContext {
            // Huỷ phiên xác thực bằng cách ghi rác
            let authenticator = BLEAuthenticator(context: ctx, pin: preferences.savedPin ?? "", isKnownDevice: true)
            Task {
                try? await authenticator.invalidateSession()
            }
            
            stateMachine.transition(to: .standby)
            DispatchQueue.main.async {
                self.standbyTimer?.invalidate()
                self.standbyTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak ctx] _ in
                    ctx?.peripheral.readRSSI()
                }
            }
        } else {
            connect()
        }
    }
}

extension DatBikeCore: CBCentralManagerDelegate {
    
    /// State Restoration: iOS khôi phục peripheral khi app bị kill + relaunch
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripheralCount = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.count ?? 0
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[RESTORE] willRestoreState | peripheralCount=\(peripheralCount) | centralState=\(central.state.rawValue)"))
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[RESTORE] Peripheral: name=\(restored.name ?? "nil") | uuid=\(restored.identifier.uuidString.prefix(8)) | state=\(restored.state.rawValue) | services=\(restored.services?.count ?? 0)"))
            
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
                // Dùng forceFullScan (không phải btWasPoweredOff) vì BT không bị tắt/bật —
                // chỉ peripheral bị disconnect. btWasPoweredOff dành riêng cho BT power-cycle.
                forceFullScan = true
            }
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[CB_STATE] centralManagerDidUpdateState=\(central.state.rawValue) | smState=\(stateMachine.state.displayText) | activeCtx=\(activeContext?.peripheral.identifier.uuidString.prefix(8).description ?? "nil") | btPowerOff=\(btWasPoweredOff) | pendingASK=\(pendingASKUUID?.uuidString.prefix(8).description ?? "nil") | savedPin=\(preferences.savedPin != nil)"))
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
            
            // ═══ Kiểm tra activeContext từ willRestoreState (dùng peripheral.state, KHÔNG dùng stateMachine.state) ═══
            // stateMachine.state có thể bị override về .scanning bởi connect() nếu willRestoreState chạy
            // synchronously bên trong CBCentralManager constructor và connect() chưa biết.
            // peripheral.state là sự thật vật lý từ iOS — đáng tin hơn stateMachine.
            if let ctx = activeContext, ctx.peripheral.state == .connected {
                if case .connecting = stateMachine.state {} else {
                    stateMachine.transition(to: .connecting)
                }
                
                // ASK-AWARE: Tận dụng cached GATT nếu có
                if let cachedServices = ctx.peripheral.services, !cachedServices.isEmpty {
                    var missingChars = false
                    for service in cachedServices {
                        if let chars = service.characteristics, !chars.isEmpty {
                            for char in chars { ctx.register(characteristic: char) }
                        } else {
                            missingChars = true
                            ctx.peripheral.discoverCharacteristics(nil, for: service)
                        }
                    }
                    
                    if missingChars {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "[RESTORE] Có cached services nhưng thiếu chars → đang discover chars..."))
                        startConnectingTimeout()
                    } else {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "[RESTORE] GATT cached đầy đủ (services + chars) → skip discover"))
                        tryRestoreActiveSession(ctx: ctx)
                    }
                } else {
                    // Không có cache → discover từ đầu
                    ctx.peripheral.discoverServices(BLEService.allServices)
                    startConnectingTimeout()
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
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let deviceName = peripheral.name ?? advName ?? "Dat Bike"
        let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[DISCOVER] name=\(deviceName) | uuid=\(peripheral.identifier.uuidString.prefix(8)) | RSSI=\(RSSI.intValue) | connectable=\(connectable ?? true) | smState=\(stateMachine.state.displayText) | savedUUID=\(preferences.savedPeripheralUUID?.prefix(8).description ?? "nil") | isBackground=\(isAppInBackground)"))
        
        // ═══ GUARD: Đã đang trong quá trình kết nối → bỏ qua callback trùng ═══
        // Phòng trường hợp 2 xe DatBike gần nhau gửi 2 callback liên tiếp vào queue CoreBluetooth
        // → connectPeripheral() bị gọi 2 lần → activeContext bị ghi đè → cả 2 kết nối fail
        if activeContext != nil, case .connecting = stateMachine.state {
            return
        }
        
        // Đã pair trước đó (có savedPin) → auto-connect luôn, không cần chọn
        if preferences.savedPin != nil {
            if isAppInBackground {
                // Background: BẮT BUỘC bỏ qua các sóng yếu và tiếp tục Scan bằng hạ tầng hệ điều hành.
                // Nếu kết nối ở xa trong Background, Timer bị đóng băng -> App không bao giờ xác thực được!
                if Double(RSSI.intValue) < preferences.rssiThreshold {
                    return
                }
            }
            
            // ═══ UUID FILTER: Khi có 2 xe DatBike gần nhau, chỉ kết nối xe đã ghép đôi ═══
            // Nếu UUID khớp → connect ngay
            if let savedUUIDStr = preferences.savedPeripheralUUID,
               peripheral.identifier.uuidString == savedUUIDStr {
                cancelScanTimer()
                central.stopScan()
                connectPeripheral(peripheral, central: central)
                return
            }
            
            // UUID không khớp → tiếp tục scan (chờ đúng xe)
            // Nếu không có savedPeripheralUUID (user cũ chưa có), dùng xe đầu tiên tìm thấy
            if preferences.savedPeripheralUUID == nil {
                cancelScanTimer()
                central.stopScan()
                connectPeripheral(peripheral, central: central)
                return
            }
            
            // Có savedUUID nhưng xe này không phải → bỏ qua
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "Tìm thấy xe DatBike khác (\(peripheral.identifier.uuidString.prefix(8))) — bỏ qua, đang chờ đúng xe"))
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
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
            message: "[DID_CONNECT] name=\(peripheral.name ?? "nil") | uuid=\(peripheral.identifier.uuidString.prefix(8)) | peripheralState=\(peripheral.state.rawValue) | smState=\(stateMachine.state.displayText) | activeCtx=\(activeContext == nil ? "nil" : "có") | ctxMatch=\(activeContext?.peripheral === peripheral) | isBackground=\(isAppInBackground)"))
        btWasPoweredOff = false
        forceFullScan = false
        micRetryCount = 0
        
        // ═══ CANCEL TIMERS: tránh double-scan từ fallback timer hoặc phantom timeout ═══
        cancelConnectingTimeout()
        disconnectFallbackTimer?.cancel()
        disconnectFallbackTimer = nil
        
        // ═══ GUARD: Đảm bảo activeContext + delegate luôn tồn tại khi kết nối ═══
        // Khi background pending connect reconnect (downgradeToStandby background path),
        // activeContext đã bị xóa → peripheral.delegate == nil → GATT callbacks bị mất.
        // Phải tạo lại context trước khi discover services.
        if activeContext == nil || activeContext?.peripheral !== peripheral {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "didConnect: Tạo lại context (background pending reconnect hoặc peripheral mới)"))
            let ctx = BLEConnectionContext(peripheral: peripheral)
            self.activeContext = ctx
            peripheral.delegate = self
            self.commandDispatcher = BLECommandDispatcher(context: ctx)
            self.pollingEngine = BLEPollingEngine(context: ctx)
            self.isAuthenticating = false
            stateMachine.transition(to: .connecting)
        }
        
        // Xin iOS cấp cho 30s CPU để xử lý Auto-turn-on và các tác vụ khác khi app lỡ bị rơi vào trạng thái ngủ đông
        extendBackgroundExecutionTime()
        
        peripheral.discoverServices(BLEService.allServices)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let errorMsg = error?.localizedDescription ?? "unknown"
        let nsError = error as NSError?
        PersistentLogger.shared.append(BLELogEntry(
            timestamp: Date(), level: .error,
            message: "[DID_FAIL_CONNECT] name=\(peripheral.name ?? "nil") | uuid=\(peripheral.identifier.uuidString.prefix(8)) | error=\(errorMsg) | code=\(nsError?.code ?? -1) | domain=\(nsError?.domain ?? "nil") | micRetry=\(micRetryCount)/\(maxMicRetries) | scanRetry=\(scanRetryCount)/\(maxScanRetries)"
        ))
        
        activeContext = nil
        commandDispatcher = nil
        pollingEngine = nil
        isAuthenticating = false
        standbyTimer?.invalidate()
        standbyTimer = nil
        
        // MIC failure hoặc "Failed to encrypt" = encryption cache lệch
        let isMICFailure = errorMsg.contains("MIC failure")
            || (error as NSError?)?.code == 31
        let isEncryptionFailure = errorMsg.contains("Failed to encrypt")
        // Connection timeout (code 6) cũng có thể do stale encryption
        let isConnectionTimeout = errorMsg.contains("timed out") || (error as NSError?)?.code == 6
        
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
        
        if isMICFailure || isEncryptionFailure || isConnectionTimeout {
            micRetryCount += 1
            let failureType = isMICFailure ? "MIC failure" : isEncryptionFailure ? "Encryption failure" : "Connection timeout"
            
            // Giới hạn số lần retry MIC failure để tránh loop vô hạn
            if micRetryCount > maxMicRetries {
                PersistentLogger.shared.append(BLELogEntry(
                    timestamp: Date(), level: .error,
                    message: "\(failureType) đã thử \(micRetryCount - 1) lần — chuyển sang pending connect nền"
                ))
                micRetryCount = 0
                btWasPoweredOff = true
                forceFullScan = true
                stateMachine.transition(to: .scanning)
                if let central = self.centralManager {
                    central.connect(peripheral, options: [
                        CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
                    ])
                }
                return
            }
            
            // Progressive backoff: 1s → 2s → 3s → 4s → 5s
            let delay = Double(micRetryCount) * 1.0
            PersistentLogger.shared.append(BLELogEntry(
                timestamp: Date(), level: .warning,
                message: "\(failureType) (lần \(micRetryCount)/\(maxMicRetries)) → delay \(String(format: "%.0f", delay))s rồi scan mới"
            ))
            btWasPoweredOff = true
            forceFullScan = true
            pendingASKUUID = nil
            scanRetryCount = 0
            stateMachine.transition(to: .scanning)
            if let central = self.centralManager, central.state == .poweredOn {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self else { return }
                    if self.centralManager?.state == .poweredOn {
                        self.startScanWithTimeout(central: central)
                    }
                }
            }
        } else if scanRetryCount < maxScanRetries {
            scanRetryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                if let central = self.centralManager, central.state == .poweredOn {
                    self.startScanWithTimeout(central: central)
                }
            }
        } else {
            // Hết quota retry scan → pending connect thay vì chết cứng
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "Hết quota retry — chuyển sang pending connect nền"))
            stateMachine.transition(to: .scanning)
            central.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
            ])
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let errorMsg = error?.localizedDescription ?? "none"
        let nsError = error as NSError?
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
            message: "[DID_DISCONNECT] name=\(peripheral.name ?? "nil") | uuid=\(peripheral.identifier.uuidString.prefix(8)) | error=\(errorMsg) | code=\(nsError?.code ?? 0) | smState=\(stateMachine.state.displayText) | isBackground=\(isAppInBackground) | wasConnected=\(stateMachine.state.isConnected) | autoSuspended=\(isSessionAutoSuspended)"))
        
        stopBackgroundExecutionTime()
        
        pollingEngine?.stopPolling()
        isAuthenticating = false
        isSessionAutoSuspended = false
        standbyTimer?.invalidate()
        standbyTimer = nil
        authTask?.cancel()
        authTask = nil
        
        guard let error = error else {
            // User-initiated disconnect (hoặc lệnh reset nội bộ)
            // Lệnh cancelPeripheralConnection có thể trả về didDisconnect mất đến > 1s.
            // Nếu state đang tiến hành scan/connect mới, sự kiện này là "dội lại" từ quá khứ → KHÔNG NGẮT KẾT NỐI MỚI.
            if stateMachine.state == .idle {
                disconnect()
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "Bỏ qua sự kiện ngắt kết nối không lỗi vì đang trong luồng mới (\(stateMachine.state.displayText))"))
            }
            return
        }
        
        // MIC failure từ didDisconnect (iOS có thể fire ở đây thay vì didFailToConnect)
        let isMICFailure = errorMsg.contains("MIC failure") || (nsError?.code ?? 0) == 31
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
        let wasConnected = stateMachine.state.isConnected || stateMachine.state == .standby
        stateMachine.transition(to: .scanning)
        
        if wasConnected && preferences.connectOnlyWhenNear {
            NotificationManager.shared.sendNotification(
                title: "Trạng thái kết nối",
                body: "Phát hiện di chuyển ra xa, chuyển trạng thái chờ",
                identifier: "DowngradeToStandby"
            )
        }
        
        central.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
        
        // Fallback: connect() sau 5s nếu pending connect của iOS không phản hồi
        // ═══ QUAN TRỌNG: Phải hủy pending connect TRƯỚC khi gọi connect() (scan mới) ═══
        // Lý do: gọi connect() trong khi central.connect() đang pending → iOS có cả
        // scan VÀ pending connect active → xung đột → connection không bao giờ hoàn thành.
        disconnectFallbackTimer?.cancel()
        let fallbackTimer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .scanning = self.stateMachine.state {
                // Hủy pending connect trước
                self.centralManager?.cancelPeripheralConnection(peripheral)
                // Sau đó mới bắt đầu scan/retrieve mới
                self.connect()
            }
        }
        disconnectFallbackTimer = fallbackTimer
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: fallbackTimer)
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
        let serviceCount = peripheral.services?.count ?? 0
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[GATT] didDiscoverServices | count=\(serviceCount) | error=\(error?.localizedDescription ?? "none") | peripheral=\(peripheral.identifier.uuidString.prefix(8))"))
        guard error == nil, let services = peripheral.services else { return }
        for service in services {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[GATT]   Service: \(service.uuid.uuidString.prefix(8))"))
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let charCount = service.characteristics?.count ?? 0
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[GATT] didDiscoverCharacteristics | service=\(service.uuid.uuidString.prefix(8)) | charCount=\(charCount) | error=\(error?.localizedDescription ?? "none")"))
        guard let chars = service.characteristics, let ctx = activeContext else { return }
        for char in chars {
            ctx.register(characteristic: char)
        }
        
        // Kích hoạt auth CHỈ KHI ĐỦ cả 3 characteristic cần thiết (có thể nằm ở nhiều service khác nhau)
        // Lưu ý: stateMachine.state == .connecting đảm bảo chỉ kích hoạt 1 lần duy nhất (vì sau đó sẽ chuyển sang .standby hoặc .pairingRequired)
        if !isAuthenticating, stateMachine.state == .connecting,
           (try? ctx.requireCharacteristic(BLECharacteristic.authChallenge)) != nil,
           (try? ctx.requireCharacteristic(BLECharacteristic.timeSync)) != nil,
           (try? ctx.requireCharacteristic(BLECharacteristic.autoUnlock)) != nil {
            
            cancelConnectingTimeout()
            if let savedPin = PreferencesManager.shared.savedPin, !savedPin.isEmpty {
                tryRestoreActiveSession(ctx: ctx)
            } else {
                isAuthenticating = true
                stateMachine.transition(to: .pairingRequired)
            }
        }
    }
    
    private func tryRestoreActiveSession(ctx: BLEConnectionContext) {
        guard let pin = preferences.savedPin, !pin.isEmpty else {
            stateMachine.transition(to: .pairingRequired)
            return
        }
        
        // B1 FIX: Guard chống SESSION_CHECK race condition
        // didDiscoverCharacteristics có thể fire 2 lần khi iOS GATT stack retry
        guard !isRestoringSession else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[SESSION_CHECK] Bỏ qua duplicate trigger (isRestoringSession=true) | uuid=\(ctx.peripheral.identifier.uuidString.prefix(8))"))
            return
        }
        isRestoringSession = true
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[SESSION_CHECK] Bắt đầu kiểm tra phiên | uuid=\(ctx.peripheral.identifier.uuidString.prefix(8)) | peripheralState=\(ctx.peripheral.state.rawValue)"))
        
        Task {
            let isActive = await BLEAuthenticator.isSessionActive(context: ctx)
            
            if isActive {
                // Counter LẺ → phiên auth vẫn sống → restore .active TRỰC TIẾP
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                    message: "[RESTORE] Phiên auth vẫn active (counter lẻ) → skip auth, vào .active trực tiếp"))
                
                DispatchQueue.main.async {
                    self.isRestoringSession = false
                    self.isAuthenticating = false
                    
                    // Lấy dữ liệu khởi tạo ngay lập tức vì ta đã bỏ qua standby phase
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[RESTORE] Fetching initial data (Lock, Device Info, Telemetry)..."))
                    self.readLockStatus()
                    self.readDeviceInfo()
                    self.queryTelemetry()
                    
                    if let engine = self.pollingEngine {
                        engine.startPolling()
                        self.setupAutoUnlock(engine: engine)
                    }
                    self.lastActiveTime = Date()
                    self.stateMachine.transition(to: .active)
                    self.extendBackgroundExecutionTime()
                }
                
                // User requirement: 1 ngày chỉ sync time 1 lần, skip proximity token
                if self.preferences.needsTimeSyncToday {
                    if let syncChar = try? ctx.requireCharacteristic(BLECharacteristic.timeSync) {
                        let vnTZ = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
                        var cal = Calendar(identifier: .gregorian)
                        cal.timeZone = vnTZ
                        let comps = cal.dateComponents([.hour, .minute, .second], from: Date())
                        let secs = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
                        let timeSyncValue = String(secs)
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "[RESTORE] Syncing time (1 lần/ngày) = \(timeSyncValue)"))
                        try? await ctx.io.writeValue(Data(timeSyncValue.utf8), to: syncChar, type: .withResponse)
                        DispatchQueue.main.async {
                            self.preferences.lastTimeSyncDate = Date()
                        }
                    }
                }
            } else {
                // Counter CHẴN → cần auth lại
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[RESTORE] Phiên auth đã hết (counter chẵn) → vào standby + auth lại"))
                DispatchQueue.main.async {
                    self.isRestoringSession = false
                    self.startStandbyProximityChecks(ctx: ctx, pin: pin)
                }
            }
        }
    }
    
    private func startStandbyProximityChecks(ctx: BLEConnectionContext, pin: String) {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .verbose,
            message: "[STANDBY_CHECK] Bắt đầu | peripheral=\(ctx.peripheral.identifier.uuidString.prefix(8)) | connectOnlyWhenNear=\(preferences.connectOnlyWhenNear) | rssiThreshold=\(preferences.rssiThreshold) | autoUnlock=\(preferences.autoUnlockEnabled) | shouldTurnOn=\(shouldTurnOnBikeAfterAuth) | autoSuspended=\(isSessionAutoSuspended)"))
        stateMachine.transition(to: .standby)
        isAuthenticating = false
        isSessionAutoSuspended = false
        
        // Bỏ qua chờ khoảng cách nếu user chủ động bấm Đánh Thức trên Widget
        if self.shouldTurnOnBikeAfterAuth {
            self.forceAuthenticate(turnOn: true)
            return
        }
        
        // ═══ FAST PATH: Nếu không dùng chế độ "Chỉ kết nối khi gần" ═══
        // Không cần poll RSSI → auth ngay, không qua standby waiting.
        if !preferences.connectOnlyWhenNear {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "connectOnlyWhenNear=false → bỏ qua standby, auth ngay"))
            isAuthenticating = true
            executeAuthProtocol(ctx: ctx, pin: pin)
            return
        } else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .verbose,
                message: "Chế độ 'Chỉ kết nối khi gần' ĐANG BẬT. RssiThreshold = \(preferences.rssiThreshold)"))
        }
        
        NotificationManager.shared.sendNotification(
            title: "Trạng thái kết nối",
            body: "Phát hiện di chuyển gần xe, kết nối ở trạng thái chờ",
            identifier: "StandbyProximity"
        )
        
        // Vẫn đọc dữ liệu qua BLE (không cần chờ Authentication Protocol)
        self.readLockStatus()
        self.readDeviceInfo()
        self.queryTelemetry()
        
        DispatchQueue.main.async {
            self.standbyTimer?.invalidate()
            
            // ═══ INSTANT RSSI CHECK ═══
            // Đọc RSSI ngay lập tức (không chờ tick đầu tiên của timer).
            // Nếu người dùng đang đứng gần xe, auth sẽ trigger ngay thay vì sau 0.5s.
            ctx.peripheral.readRSSI()
            
            // Poll RSSI mỗi 0.5s để phát hiện ngưỡng gần xe nhanh hơn ~50% so với 1s cũ
            self.standbyTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak ctx] _ in
                ctx?.peripheral.readRSSI()
            }
        }
    }
    
    func submitPairingPin(_ pin: String) {
        guard stateMachine.state == .pairingRequired, let ctx = activeContext else { return }
        PreferencesManager.shared.savedPin = pin
        executeAuthProtocol(ctx: ctx, pin: pin, isKnownDevice: false)
    }
    
    private func executeAuthProtocol(ctx: BLEConnectionContext, pin: String, isKnownDevice: Bool = true) {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[AUTH] Bắt đầu | peripheral=\(ctx.peripheral.identifier.uuidString.prefix(8)) | isKnown=\(isKnownDevice) | pinLen=\(pin.count) | smState=\(stateMachine.state.displayText) | prevAuthTask=\(authTask != nil ? "có (cancel)" : "nil")"))
        let authenticator = BLEAuthenticator(context: ctx, pin: pin, isKnownDevice: isKnownDevice)
        
        authTask?.cancel()
        authTask = Task {
            do {
                stateMachine.transition(to: .authenticating)
                _ = try await authenticator.authenticate()
                
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                    message: "[AUTH] Thành công ✅ | peripheral=\(ctx.peripheral.identifier.uuidString.prefix(8)) | peripheralState=\(ctx.peripheral.state.rawValue)"))
                
                if let engine = self.pollingEngine {
                    engine.startPolling()
                    self.setupAutoUnlock(engine: engine)
                }
                
                // Session auto state đã được quản lý bởi isSessionAutoSuspended
                
                self.lastActiveTime = Date() // Ghi nhận thời điểm active để cooldown downgrade
                stateMachine.transition(to: .active)
                self.micRetryCount = 0 // Reset MIC retry counter khi kết nối thành công
                NotificationManager.shared.sendNotification(
                    title: "Trạng thái kết nối",
                    body: "Đã kết nối thành công",
                    identifier: "Connected"
                )
                
                // Lưu UUID để lần sau dùng retrievePeripherals (tránh MIC failure)
                if let ctx = self.activeContext {
                    self.preferences.savedPeripheralUUID = ctx.peripheral.identifier.uuidString
                }
                
                // Post-auth: đọc lock status + device info + telemetry
                self.readLockStatus()
                self.readDeviceInfo()
                self.queryTelemetry()
                
                if self.shouldTurnOnBikeAfterAuth {
                    self.shouldTurnOnBikeAfterAuth = false
                    if let dispatcher = self.commandDispatcher {
                        Task { try? await dispatcher.turnOnBike() }
                    }
                }
                
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
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                    message: "[AUTH] SHA challenge thất bại — sẽ disconnect | peripheral=\(ctx.peripheral.identifier.uuidString.prefix(8))"))
                disconnect()
                stateMachine.transition(to: .error("Xác thực thất bại. Thử lại hoặc tắt/bật Bluetooth."))
            } catch {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                    message: "[AUTH] Lỗi khác: \(error.localizedDescription) | isCancelled=\(Task.isCancelled) | peripheral=\(ctx.peripheral.identifier.uuidString.prefix(8))"))
                if !Task.isCancelled {
                    disconnect()
                    stateMachine.transition(to: .error("Lỗi xác thực: \(error.localizedDescription)"))
                } else {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[AUTH] Task bị cancel (disconnect hoặc reconnect) — bỏ qua error"))
                }
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
            
            let vehicleString = "Xe: \(name) / \(model) / \(serial) / FW: \(fw)"
            if vehicleString != self.lastLoggedVehicleString {
                self.lastLoggedVehicleString = vehicleString
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                    message: vehicleString))
            }
            
            // Ưu tiên: name > model > peripheral.name (để ưu tiên tên riêng người dùng đặt như 'Ngựa sắt')
            let displayName: String = {
                if !name.isEmpty && name != "Dat Bike" { return name }
                if !model.isEmpty { return model }
                return ctx.peripheral.name ?? "Dat Bike"
            }()
            
            // Lưu tên xe thực ngay vào App Group cho Widget
            self.preferences.sharedDefaults.set(displayName, forKey: "widgetBikeName")
            
            DispatchQueue.main.async {
                self.currentVehicleInfo = IoTVehicleInfo(
                    name: displayName,
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
                let status = IoTLockState.parse(from: data)
                if case .unknown = status {
                    // Ignore unknown transitions to avoid overriding state with noise
                } else {
                    DispatchQueue.main.async {
                        // Notify BLE push: chi log khi status thuc su thay doi
                        if self.currentLockState != status {
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                                message: "[BLE Notify] Trang thai xe thay doi: \(status.description)"))
                        }
                        self.currentLockState = status
                    }
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { await activeContext?.io.didReceiveWriteResponse(for: characteristic, error: error) }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        let rssiValue = RSSI.intValue
        
        DispatchQueue.main.async {
            self.currentRSSI = rssiValue
            
            if self.stateMachine.state == .standby {
                let threshold = self.preferences.connectOnlyWhenNear ? self.preferences.rssiThreshold : -70.0
                
                // Rate limit log: chỉ in mỗi 2 giây
                let now = Date()
                if self.lastRssiLogTime == nil || now.timeIntervalSince(self.lastRssiLogTime!) >= 2.0 {
                    self.lastRssiLogTime = now
                    PersistentLogger.shared.append(BLELogEntry(timestamp: now, level: .verbose,
                        message: "[RSSI] Standby chờ gần: RSSI=\(rssiValue) / Ngưỡng=\(threshold)"))
                }
                
                // Nếu người dùng đã đi khỏi vùng phủ sóng (thấp hơn ngưỡng - 3dBm), hãy reset cờ Manual Standby
                if Double(rssiValue) < threshold - 3.0 {
                    // Do nothing for isSessionAutoSuspended. The drop is physical or session-based.
                }
                
                // Chỉ auto-authenticate khi vào vùng VÀ không bị đình chỉ trong phiên
                if Double(rssiValue) >= threshold {
                    if self.isSessionAutoSuspended {
                        return
                    }
                    
                    self.standbyTimer?.invalidate()
                    self.standbyTimer = nil
                    self.isAuthenticating = true
                    if let ctx = self.activeContext, let pin = self.preferences.savedPin {
                        self.executeAuthProtocol(ctx: ctx, pin: pin)
                    }
                }
            } else {
                self.pollingEngine?.didReadRSSI(value: RSSI.doubleValue)
            }
        }
    }
    
    @objc private func appDidEnterBackground() {
        isAppInBackground = true
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[LIFECYCLE] App → Background | smState=\(stateMachine.state.displayText) | activeCtx=\(activeContext?.peripheral.identifier.uuidString.prefix(8).description ?? "nil") | peripheralState=\(activeContext?.peripheral.state.rawValue ?? -1) | isAuth=\(isAuthenticating) | autoSuspended=\(isSessionAutoSuspended)"))
        extendBackgroundExecutionTime()
    }
    
    @objc private func appWillEnterForeground() {
        isAppInBackground = false
        stopBackgroundExecutionTime()
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[LIFECYCLE] App → Foreground | smState=\(stateMachine.state.displayText) | activeCtx=\(activeContext?.peripheral.identifier.uuidString.prefix(8).description ?? "nil") | peripheralState=\(activeContext?.peripheral.state.rawValue ?? -1) | btPowerOff=\(btWasPoweredOff) | forceScan=\(forceFullScan)"))
        if stateMachine.state == .scanning {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[LIFECYCLE] Đang scanning → gọi connect()"))
            connect()
        } else if stateMachine.state == .connecting, let timer = connectingTimer {
            // ═══ GUARD: Chỉ hủy nếu peripheral THỰC SỰ stale (không phải cold launch ASK) ═══
            // Cold launch với ASK: peripheral.state == .connected (connection hợp lệ)
            // → KHÔNG hủy, để GATT discovery tiếp tục bình thường.
            // Background phantom: peripheral.state != .connected (stale)
            // → Hủy và scan mới.
            if let ctx = self.activeContext, ctx.peripheral.state == .connected {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[LIFECYCLE] Đang connecting nhưng peripheral.state==connected → giữ nguyên (cold launch / ASK)"))
                // Chỉ cancel timer phantom, không hủy connection
                timer.cancel()
                self.connectingTimer = nil
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "[LIFECYCLE] Đang connecting + peripheral stale → force timeout + scan mới"))
                timer.cancel()
                self.connectingTimer = nil
                
                if let ctx = self.activeContext, let central = self.centralManager {
                    central.cancelPeripheralConnection(ctx.peripheral)
                }
                self.activeContext = nil
                self.commandDispatcher = nil
                self.pollingEngine = nil
                self.isAuthenticating = false
                self.forceFullScan = true
                self.connect()
            }
        }
    }
}

// MARK: - LIVE ACTIVITY SUPPORT

import ActivityKit


extension DatBikeCore {
    public func forceStopScan() {
        print("[BLE] Force stop scan on DatBikeCore")
        self.centralManager.stopScan()
    }
}
