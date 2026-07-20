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
    /// ═══ CHỈ RESET trong didConnect (L1260) — KHÔNG reset sớm trong connect()/startScanWithTimeout() ═══
    /// Lý do: ASK callback đến 30-50ms sau connect(), nếu reset sớm → ASK dùng cache → MIC failure.
    private var btWasPoweredOff: Bool = false
    
    /// Cờ riêng biệt: peripheral stale (disconnect sau State Restoration),
    /// buộc scan mới dù BT không bị power-cycle.
    private var forceFullScan: Bool = false
    
    /// Đếm số lần liên tiếp rơi vào Standby (RSSI quá yếu) mà không auth được.
    /// Dùng để detect "Standby Drain Loop" và chuyển sang pending connect tiết kiệm pin.
    private var consecutiveStandbyCount = 0
    private let maxConsecutiveStandbyBeforePending = 3
    
    /// Đếm số vòng scan khi btWasPoweredOff=true — giới hạn scan loop.
    /// Sau 3 vòng (6 retries) mà không tìm thấy xe → reset flag, fallback pending connect.
    private var btPowerCycleScanRounds = 0
    private let maxBtPowerCycleScanRounds = 3
    
    /// Đếm số lần RSSI liên tục yếu hơn ngưỡng trong quá trình standby polling.
    /// Sau 10 lần liên tục (≈5s ở tần suất poll 0.5s), chủ động disconnect + pending connect
    /// thay vì chờ iOS supervision timeout (~30-60s) gây lãng phí CPU và pin.
    private var weakRssiConsecutiveCount = 0
    private let maxWeakRssiBeforeDisconnect = 10
    
    // Proximity Standby Timer
    private var standbyTimer: Timer?
    private var lastRssiLogTime: Date?
    
    // Scan timeout & retry
    private var scanTimer: DispatchWorkItem?
    private var scanRetryCount = 0
    private let maxScanRetries = 2
    private var scanTimeoutSeconds: TimeInterval {
        isAppInBackground ? 4.0 : 2.5 // Foreground: scan nhanh hơn (xe thường phản hồi <2s)
    }
    
    // Connecting state timeout — phòng trường hợp discoverServices không phản hồi (phantom connection)
    private var connectingTimer: DispatchWorkItem?
    
    // Disconnect fallback timer — cancel khi didConnect để tránh double-scan
    private var disconnectFallbackTimer: DispatchWorkItem?
    
    // Auth task reference — cancel khi disconnect để tránh stale state transitions
    private var authTask: Task<Void, Never>?
    
    // MIC failure retry limit — persisted qua UserDefaults để xuyên phiên app relaunch
    private var micRetryCount: Int {
        get { UserDefaults.standard.integer(forKey: "ble_micRetryCount") }
        set { UserDefaults.standard.set(newValue, forKey: "ble_micRetryCount") }
    }
    private let maxMicRetries = 3
    
    /// Timestamp lần MIC failure cuối — dùng kèm micRetryCount để tạo TTL.
    /// Sau 60s không gặp MIC failure → reset counter (tránh "dính" vĩnh viễn).
    private var lastMicFailureTime: Date? {
        get {
            let interval = UserDefaults.standard.double(forKey: "ble_lastMicFailureTime")
            return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "ble_lastMicFailureTime") }
    }
    private let micRetryTTL: TimeInterval = 60 // Reset sau 60s không gặp MIC failure
    
    /// Guard chống connectPeripheral().disconnecting retry loop bị gọi đồng thời từ nhiều luồng
    /// (ví dụ: foreground connect() + didDiscover callback cùng fire một lúc).
    private var disconnectingRetryActive = false
    
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
                    guard let self else { return }
                    // ═══ GUARD: Nếu đã có saved UUID VÀ CB đang xử lý → bỏ qua ASK callback ═══
                    if self.preferences.savedPeripheralUUID != nil {
                        let cbHandling = self.activeContext?.peripheral.state == .connected
                            || self.activeContext?.peripheral.state == .connecting
                            || self.scanTimer != nil
                            || self.stateMachine.state == .authenticating
                            || self.stateMachine.state == .active
                            || self.stateMachine.state == .nearby
                        if cbHandling {
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                                message: "[ASK_CONNECT] Bỏ qua — CB path đang xử lý (smState=\(self.stateMachine.state.displayText))"))
                            return
                        }
                    }
                    self.initializeBluetoothHardware()
                    self.connect(to: uuid)
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
                message: "[INIT] initializeBluetoothHardware() bỏ qua — centralManager đã tồn tại | savedPin=\(preferences.savedPin ?? "nil")"))
            return
        }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[INIT] Khởi tạo CBCentralManager | savedUUID=\(preferences.savedPeripheralUUID?.prefix(8).description ?? "nil") | savedPin=\(preferences.savedPin ?? "nil") | connectOnlyWhenNear=\(preferences.connectOnlyWhenNear)"))
        let bundleId = Bundle.main.bundleIdentifier ?? "app.mybike.smartkey"
        let queue = DispatchQueue(label: "\(bundleId).core.ble", qos: .userInitiated)
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
                    // ═══ NEARBY: Hiển thị "Đang ở gần" + lock state trên Widget ═══
                    if case .nearby = connState {
                        switch lock {
                        case .unlocked: return "Đang ở gần • Xe bật"
                        case .armed:    return "Đang ở gần • Chống trộm"
                        case .locked:   return "Đang ở gần • Xe tắt"
                        default:        return "Đang ở gần xe"
                        }
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
                shared.isConnected = (connState == .active || connState == .standby || connState == .nearby)
                shared.connectionPhase = connState == .active ? "ready" : (connState == .standby ? "standby" : (connState == .nearby ? "nearby" : "disconnected"))
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
        
        // ═══ GUARD: Scan đang chạy → bỏ qua duplicate call ═══
        // Nguyên nhân MIC failure khi cold-launch:
        // 1. centralManagerDidUpdateState(.poweredOn) sau power-cycle → connect() → startScanWithTimeout() → reset btWasPoweredOff=false
        // 2. appWillEnterForeground / iOS 18 delay init → connect() được gọi lại ngay lập tức
        // 3. Lần gọi thứ 2 thấy btWasPoweredOff=false → dùng cache → MIC failure!
        // Fix: Nếu scan timer đang chạy, KHÔNG cho phép bất kỳ code path nào dùng cache.
        if scanTimer != nil {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[CONNECT] Scan timer đang chạy → bỏ qua duplicate call | smState=\(stateMachine.state.displayText)"))
            return
        }
        
        // Đã pair trước đó → thử retrieve (giống 7c3227a tryReconnectKnown)
        if preferences.savedPin != nil,
           let savedUUIDStr = preferences.savedPeripheralUUID,
           let savedUUID = UUID(uuidString: savedUUIDStr) {
            
            // ═══ GUARD: Nếu BT vừa tắt/bật HOẶC peripheral stale → BẮT BUỘC scan mới ═══
            // btWasPoweredOff: BT power-cycle → iOS cache encryption keys cũ → MIC failure
            // forceFullScan:   Peripheral stale (State Restoration disconnect)
            // Cả 2 đều yêu cầu scan mới để iOS negotiate fresh link-layer encryption.
            // ═══ KHÔNG reset btWasPoweredOff ở đây — chỉ reset trong didConnect ═══
            // Lý do: ASK callback đến 30-50ms sau → nếu reset ở đây, ASK thấy false → dùng cache → MIC failure.
            if btWasPoweredOff || forceFullScan {
                let reason = btWasPoweredOff ? "BT power-cycle" : "peripheral stale (State Restoration)"
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "\(reason) → bỏ qua cache, scan mới để tránh MIC failure"))
                // btWasPoweredOff giữ nguyên — sẽ reset trong didConnect (khi connection thành công)
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
                // ═══ GUARD: Peripheral stale (.disconnecting) → KHÔNG dùng cache ═══
                // Sau khi app bị suspend dài (>5 phút), iOS giữ peripheral ở .disconnecting.
                // Connect vào peripheral này sẽ kẹt retry loop vô hạn.
                // Fix: force fresh scan để iOS negotiate kết nối mới hoàn toàn.
                if p.state == .disconnecting {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "Peripheral cache đang .disconnecting (stale sau suspend) → force scan mới | state=\(p.state.rawValue)"))
                    forceFullScan = false
                    startScanWithTimeout(central: central)
                    return
                }
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "Retrieve peripheral từ cache: \(p.name ?? savedUUIDStr.prefix(8).description)"))
                connectPeripheral(p, central: central, isPendingConnect: true)
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
        
        let isMainBike = (uuid.uuidString == preferences.savedPeripheralUUID)
        
        if let ctx = activeContext,
           ctx.peripheral.state == .connected || ctx.peripheral.state == .connecting {
            
            if ctx.peripheral.identifier == uuid {
                // B7 FIX: Hủy Phantom Guard nếu đang chạy — ASK sẽ tự quản lý connection lifecycle
                // App đã bắt đầu connect() nhưng ASK Session Activated mới fire — tin tưởng ASK hơn
                let wasTimerActive = connectingTimer != nil
                cancelConnectingTimeout()
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[ASK_CONNECT] Bỏ qua: peripheral đang kết nối (state=\(ctx.peripheral.state.rawValue)) | phantomGuardCancelled=\(wasTimerActive) | smState=\(stateMachine.state.displayText)"))
                return
            } else {
                // Đang kết nối xe khác. Nếu xe đang kết nối là xe chính (saved UUID), KHÔNG cho phép thiết bị phụ ngắt ngang.
                if let savedStr = preferences.savedPeripheralUUID, ctx.peripheral.identifier.uuidString == savedStr {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "[ASK_CONNECT] Bỏ qua thiết bị phụ (\(uuid.uuidString.prefix(8))) vì đang giữ kết nối ưu tiên với xe chính (\(savedStr.prefix(8)))"))
                    return
                } else {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "[ASK_CONNECT] Đang kết nối xe khác (\(ctx.peripheral.identifier.uuidString.prefix(8))) → ngắt kết nối để ưu tiên xe mới (\(uuid.uuidString.prefix(8)))"))
                    central.cancelPeripheralConnection(ctx.peripheral)
                    self.activeContext = nil
                    self.cancelConnectingTimeout()
                }
            }
        }
        
        // CHỈ cập nhật savedPeripheralUUID nếu nó đang rỗng, hoặc thiết bị ASK này chính là xe mới người dùng vừa pick.
        // Tránh bị nhiễu do ASK tự động trả về các thiết bị phụ (ESP) lúc khởi động.
        if preferences.savedPeripheralUUID == nil || !isMainBike && activeContext == nil {
            preferences.savedPeripheralUUID = uuid.uuidString
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
        if btWasPoweredOff || forceFullScan {
            let reason = btWasPoweredOff ? "BT power-cycle" : "peripheral stale"
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK connect: \(reason) → bỏ qua cache, scan mới để tránh encryption failure"))
            // Flags giữ nguyên — sẽ reset trong didConnect
            startScanWithTimeout(central: central)
            return
        }
        
        // ═══ GUARD: Nếu scan đang chạy (do connect() trước đó), KHÔNG dùng cache ═══
        // Race condition: connect() bắt đầu scan → ASK callback đến 30-50ms sau.
        // Nếu dùng cache ở đây, peripheral có thể mang stale encryption keys → MIC failure.
        // Để scan hiện tại hoàn thành và tìm peripheral mới.
        if scanTimer != nil {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[ASK_CONNECT] Scan đang chạy → bỏ qua retrieve cache, chờ scan hoàn thành | smState=\(stateMachine.state.displayText)"))
            return
        }
        
        let known = central.retrievePeripherals(withIdentifiers: [uuid])
        if let p = known.first {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK Retrieve peripheral thành công: \(p.name ?? uuid.uuidString.prefix(8).description)"))
            connectPeripheral(p, central: central, isPendingConnect: true)
        } else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "ASK UUID không tìm thấy trong cache, kích hoạt fallback scan"))
            startScanWithTimeout(central: central)
        }
    }
    
    /// Thiết lập context + kết nối peripheral (dùng chung cho retrieve và scan)
    private func connectPeripheral(_ p: CBPeripheral, central: CBCentralManager, isPendingConnect: Bool = false, disconnectRetryCount: Int = 0) {
        cancelScanTimer()
        
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[CONNECT_PERIPHERAL] name=\(p.name ?? "nil") | uuid=\(p.identifier.uuidString.prefix(8)) | peripheralState=\(p.state.rawValue) | centralState=\(central.state.rawValue)"))
        
        // ═══ GUARD: Tránh connect khi peripheral đang trong quá trình .disconnecting ═══
        // iOS chưa dọn xong link-layer → connect ngay sẽ gây phantom connection + MIC failure.
        // Chờ 1.5s để iOS hoàn tất ngắt kết nối rồi mới connect lại.
        if p.state == .disconnecting {
            // ─── Guard: Chỉ cho phép 1 retry chain duy nhất chạy tại một thời điểm ───
            // Khi foreground + didDiscover cùng gọi connectPeripheral(), cả 2 đều thấy
            // .disconnecting và khởi chạy retry loop riêng → 2 chain song song gây rối.
            // Fix: nếu retry đã đang chạy (disconnectingRetryActive=true), bỏ qua call mới.
            if disconnectRetryCount == 0 {
                guard !disconnectingRetryActive else {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[CONNECT_PERIPHERAL] Bỏ qua — disconnectingRetry đã chạy | uuid=\(p.identifier.uuidString.prefix(8))"))
                    return
                }
                disconnectingRetryActive = true
                // Gọi cancelPeripheralConnection ngay để iOS dọn link-layer nhanh hơn
                // (đặc biệt sau khi app bị suspend dài — peripheral có thể kẹt .disconnecting hàng phút)
                central.cancelPeripheralConnection(p)
            }
            
            // Giảm threshold từ 5 → 3: Sau 3 lần retry (4.5s) mà vẫn .disconnecting là iOS kẹt
            if disconnectRetryCount >= 3 {
                disconnectingRetryActive = false
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                    message: "[CONNECT_PERIPHERAL] Peripheral kẹt ở .disconnecting quá lâu → force scan mới"))
                self.forceFullScan = true
                self.activeContext = nil
                central.cancelPeripheralConnection(p)
                self.startScanWithTimeout(central: central)
                return
            }
            
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[CONNECT_PERIPHERAL] Peripheral đang .disconnecting → chờ 1.5s rồi connect lại (retry: \(disconnectRetryCount))"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let central = self.centralManager, central.state == .poweredOn else {
                    self?.disconnectingRetryActive = false
                    return
                }
                self.connectPeripheral(p, central: central, isPendingConnect: isPendingConnect, disconnectRetryCount: disconnectRetryCount + 1)
            }
            return
        }
        
        // Đã thoát khỏi .disconnecting (hoặc không bao giờ vào) — reset guard
        disconnectingRetryActive = false
        
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
        
        if !isPendingConnect {
            startConnectingTimeout()
        } else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[PENDING_CONNECT] Bỏ qua Phantom Guard timeout vì đây là kết nối ngầm (Pending Connect)"))
        }
    }
    
    /// Bắt đầu quét BLE với timeout
    private func startScanWithTimeout(central: CBCentralManager) {
        cancelScanTimer()
        
        // Ghi nhận trạng thái power-cycle cho log, nhưng KHÔNG reset flag ở đây.
        // btWasPoweredOff chỉ reset trong didConnect — đảm bảo mọi code path
        // (connect(), connect(to:), ASK callback) đều thấy flag nếu chưa connect thành công.
        let wasPowerCycle = btWasPoweredOff
        
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
                // Giới hạn số vòng scan để tránh loop vô tận khi xe ở xa.
                if self.btWasPoweredOff {
                    self.btPowerCycleScanRounds += 1
                    if self.btPowerCycleScanRounds >= self.maxBtPowerCycleScanRounds {
                        // Đã scan 3 vòng (6 retries) mà không thấy xe
                        // → reset flag, chuyển sang pending connect tiết kiệm pin
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                            message: "Hết hạn quét xe (power-cycle) — đã scan \(self.btPowerCycleScanRounds) vòng mà không tìm thấy xe → reset btWasPoweredOff, chuyển pending connect"))
                        self.btWasPoweredOff = false
                        self.btPowerCycleScanRounds = 0
                        // Fallback sang pending connect
                        if let savedUUIDStr = self.preferences.savedPeripheralUUID,
                           let savedUUID = UUID(uuidString: savedUUIDStr) {
                            let known = central.retrievePeripherals(withIdentifiers: [savedUUID])
                            if let p = known.first {
                                self.connectPeripheral(p, central: central, isPendingConnect: true)
                                return
                            }
                        }
                        // Không tìm thấy trong cache → báo lỗi
                        self.stateMachine.transition(to: .error("Không tìm thấy xe. Hãy kiểm tra xe đã bật chưa."))
                        return
                    }
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "Hết hạn quét xe (power-cycle) — vòng \(self.btPowerCycleScanRounds)/\(self.maxBtPowerCycleScanRounds), tiếp tục scan"))
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
                        self.connectPeripheral(p, central: central, isPendingConnect: true)
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
    
    /// Escape hatch: User bấm nút "Kết nối lại" trên màn hình scanning.
    /// Reset TOÀN BỘ trạng thái BLE (flags, timers, context) rồi connect từ đầu.
    /// Giải quyết mọi trường hợp kẹt: scan loop, stale flags, phantom connections.
    func forceReconnect() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
            message: "[FORCE_RECONNECT] User yêu cầu kết nối lại | smState=\(stateMachine.state.displayText) | btPowerOff=\(btWasPoweredOff) | forceScan=\(forceFullScan) | micRetry=\(micRetryCount) | scanRetry=\(scanRetryCount)"))
        
        // 1. Hủy mọi kết nối/scan đang chạy
        cancelScanTimer()
        cancelConnectingTimeout()
        disconnectFallbackTimer?.cancel()
        disconnectFallbackTimer = nil
        centralManager?.stopScan()
        authTask?.cancel()
        authTask = nil
        standbyTimer?.invalidate()
        standbyTimer = nil
        pollingEngine?.stopPolling()
        
        // 2. Cancel peripheral connection nếu có
        if let ctx = activeContext {
            centralManager?.cancelPeripheralConnection(ctx.peripheral)
        }
        activeContext = nil
        commandDispatcher = nil
        pollingEngine = nil
        
        // 3. Reset TẤT CẢ flags về trạng thái sạch
        btWasPoweredOff = false
        forceFullScan = false
        btPowerCycleScanRounds = 0
        micRetryCount = 0
        scanRetryCount = 0
        consecutiveStandbyCount = 0
        weakRssiConsecutiveCount = 0
        phantomGuardFailCount = 0
        isAuthenticating = false
        isRestoringSession = false
        isSessionAutoSuspended = false
        isDowngrading = false
        disconnectingRetryActive = false
        
        // 4. Chuyển về scanning rồi connect mới
        stateMachine.transition(to: .scanning)
        DispatchQueue.main.async {
            self.discoveredBikes = []
        }
        
        // 5. Delay nhẹ 0.3s để iOS cleanup pending connections
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.centralManager?.state == .poweredOn else { return }
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[FORCE_RECONNECT] Bắt đầu kết nối mới (clean state)"))
            self.connect()
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
    
    /// Khi user đang ở .nearby và bấm "Kết nối" → auth ngay
    func connectFromNearby() {
        guard case .nearby = stateMachine.state,
              let ctx = activeContext,
              ctx.peripheral.state == .connected,
              let pin = preferences.savedPin else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[NEARBY→AUTH] Không thể auth — state=\(stateMachine.state.displayText) | peripheral=\(activeContext?.peripheral.state.rawValue ?? -1)"))
            // Fallback: connect lại từ đầu
            connect()
            return
        }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[NEARBY→AUTH] User bấm kết nối → auth ngay"))
        standbyTimer?.invalidate()
        standbyTimer = nil
        isAuthenticating = true
        executeAuthProtocol(ctx: ctx, pin: pin)
    }
    
    /// Chuyển từ active/standby → nearby (user bật chế độ gần xe)
    func activateNearbyMode() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[NEARBY] User kích hoạt chế độ 'Đang ở gần' từ state=\(stateMachine.state.displayText)"))
        preferences.nearbyModeEnabled = true
        
        // Nếu đang active → hạ xuống nearby (giữ BLE, bỏ polling)
        if stateMachine.state == .active || stateMachine.state == .standby {
            pollingEngine?.stopPolling()
            pollingEngine = nil
            commandDispatcher = nil
            isSessionAutoSuspended = false
            isAuthenticating = false
            stateMachine.transition(to: .nearby)
            
            // Poll RSSI nhẹ
            if let ctx = activeContext {
                standbyTimer?.invalidate()
                standbyTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak ctx] _ in
                    ctx?.peripheral.readRSSI()
                }
            }
        }
    }
    
    /// Tắt chế độ gần xe → auth ngay nếu có kết nối
    func deactivateNearbyMode() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[NEARBY] User tắt chế độ 'Đang ở gần' → auth ngay nếu có BLE"))
        preferences.nearbyModeEnabled = false
        connectFromNearby()
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
                    message: "Peripheral restore nhưng đã disconnect (state: \(restored.state.rawValue)) → cancel + scan mới"))
                // Cancel peripheral connection ngay để iOS flush stale encryption keys.
                // Nếu không cancel, peripheral ở state .connecting sẽ mang stale keys
                // → MIC failure liên tiếp khi vuốt tắt app rồi mở lại nhanh.
                central.cancelPeripheralConnection(restored)
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
                connect() // Bắt buộc kết nối lại sau power-cycle để tránh kẹt trạng thái
                return
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
                // Tăng delay lên 3.0s để tránh hiện lỗi ảo khi iOS đang khởi động lại Bluetooth daemon (đặc biệt khi vừa mở app)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
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
            if isAppInBackground && preferences.connectOnlyWhenNear {
                // Background + chế độ "Chỉ kết nối khi gần" BẬT:
                // Bỏ qua sóng yếu để tránh kết nối từ xa → timer standby bị iOS đóng băng → không bao giờ xác thực được.
                // KHÔNG áp dụng khi connectOnlyWhenNear=false: auth đi theo fast path (không timer),
                // nên an toàn kết nối bất kể khoảng cách.
                if Double(RSSI.intValue) < preferences.rssiThreshold {
                    return
                }
            }
            
            // ═══ UUID FILTER: Khi có 2 xe DatBike gần nhau, chỉ kết nối xe đã ghép đôi ═══
            // Nếu UUID khớp → connect ngay
            if let savedUUIDStr = preferences.savedPeripheralUUID {
                if peripheral.identifier.uuidString == savedUUIDStr {
                    cancelScanTimer()
                    central.stopScan()
                    connectPeripheral(peripheral, central: central)
                    return
                } else {
                    // ═══ RPA DETECTION LOG ═══
                    // Nếu quét ra Dat Bike nhưng UUID khác với UUID đã lưu, rất có thể là do MAC quay vòng (RPA)
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "[RPA-DETECTED] Phát hiện xe nhưng UUID khác (Cũ: \(savedUUIDStr.prefix(8)) | Mới: \(peripheral.identifier.uuidString.prefix(8))). Đây có thể là MAC quay vòng hoặc xe của người khác. iOS sẽ không tự ghép vào Pending Connect!"))
                }
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
        btWasPoweredOff = false  // ═══ ĐÂY LÀ NƠI DUY NHẤT RESET btWasPoweredOff ═══
        forceFullScan = false
        micRetryCount = 0
        btPowerCycleScanRounds = 0  // Reset scan loop counter khi connect thành công
        consecutiveStandbyCount = 0  // Reset standby drain counter khi connect thành công
        
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
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "Xe đã xóa bonding (code 14). Đang tự động gỡ iOS Bluetooth bằng ASKManager và yêu cầu ghép đôi lại..."))
            
            // Xóa ở cấp độ OS (iOS 18+)
            if #available(iOS 18.0, *), let savedUUID = preferences.savedPeripheralUUID {
                ASKManager.shared.removeAccessory(withUUID: savedUUID)
            }
            
            preferences.savedPeripheralUUID = nil
            micRetryCount = 0
            btWasPoweredOff = true
            forceFullScan = true
            
            if #available(iOS 18.0, *) {
                stateMachine.transition(to: .scanning)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    ASKManager.shared.showPicker()
                }
            } else {
                stateMachine.transition(to: .error(
                    "Đã phát hiện thiết bị khác chiếm kết nối xe.\n" +
                    "Bạn dùng phiên bản iOS cũ nên App không thể tự động gỡ lỗi. Vui lòng:\n" +
                    "1. Vào Cài đặt → Bluetooth → chọn chữ (i) cạnh xe Ngựa sắt → Quên thiết bị này\n" +
                    "2. Quay lại App để kết nối."
                ))
            }
            return
        }
        
        if isMICFailure || isEncryptionFailure || isConnectionTimeout {
            // TTL: Reset counter nếu lần MIC failure cuối đã quá 60s
            if let lastTime = lastMicFailureTime, Date().timeIntervalSince(lastTime) > micRetryTTL {
                micRetryCount = 0
            }
            lastMicFailureTime = Date()
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
            // MIC cluster guard: nếu 2+ MIC failures trong <10s → chờ 5s để iOS flush encryption cache
            let delay: Double
            if let lastTime = lastMicFailureTime, Date().timeIntervalSince(lastTime) < 10 {
                delay = 5.0  // MIC cluster detected
            } else {
                delay = Double(micRetryCount) * 1.0
            }
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
        
        
        // ═══ KHÔNG gọi stopBackgroundExecutionTime() ở đây ═══
        // BG task phải sống đến khi pending reconnect hoàn tất.
        // Nếu end ở đây → iOS suspend ngay → didConnect không fire → kẹt .scanning.
        // Sẽ end BG task ở cuối hàm, hoặc khi didConnect fire.
        
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
                
                // ═══ FIX: AUTO-CONNECT SAU KHI RỜI XE THỜI GIAN NGẮN ═══
                // Nếu app đang ở BG và đã chuyển sang scanning (phát lệnh pending connect),
                // PHẢI end bg task để app suspend ngay.
                // Nếu không, bg task cũ chạy tiếp. Khi user quay lại nhanh (trong vòng 30s),
                // didConnect fire nhưng dùng thời gian CÒN LẠI của bg task cũ.
                // bg task cũ expire giữa chừng → iOS suspend app → kẹt auth.
                if isAppInBackground && stateMachine.state == .scanning && scanTimer == nil {
                    stopBackgroundExecutionTime()
                }
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
        
        // ═══ Connection timeout (code 6) → invalidate encryption cache ═══
        // Sau disconnect bất ngờ (code 6), iOS có thể giữ stale encryption keys.
        // Dùng forceFullScan thay vì btWasPoweredOff để tránh scan loop vô tận.
        // forceFullScan: buộc scan mới (tránh MIC failure) nhưng KHÔNG kích hoạt
        //   infinite scan guard trong startScanWithTimeout() → an toàn hơn.
        // btWasPoweredOff: CHỈ dùng khi centralManagerDidUpdateState(.poweredOff) thật sự.
        let isConnectionTimeout = (nsError?.code ?? 0) == 6
        if isConnectionTimeout {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[DID_DISCONNECT] Connection timeout (code=6) → invalidate encryption cache (forceFullScan=true)"))
            forceFullScan = true
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
        
        // ═══ BG + timeout + wasConnected: chỉ pending connect, bỏ fallback timer ═══
        // Khi app ở background + Active Session bị code=6, reconnect loop là vô nghĩa.
        // iOS pending connect sẽ tự fire khi xe quay lại gần.
        if isAppInBackground && isConnectionTimeout && wasConnected {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[DID_DISCONNECT] BG + timeout + wasConnected → chỉ pending connect, bắt buộc suspend app (end bg task)"))
            // ═══ FIX: AUTO-CONNECT SAU KHI RỜI XE THỜI GIAN NGẮN ═══
            // Bắt buộc stop bgTask để app suspend. 
            // Nếu không, bgTask cũ tiếp tục sống. Nếu xe lại gần trong vòng 30s, didConnect fire
            // nhưng chỉ dùng thời gian CÒN LẠI của bgTask cũ → expire giữa chừng → fail auth.
            // Khi suspend, OS vẫn theo dõi pending connect và sẽ wake app dậy + cấp trọn vẹn 30s mới.
            stopBackgroundExecutionTime()
            return
        }
        
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
        
        // End BG task SAU KHI đã setup fallback
        // didConnect hoặc fallback timer sẽ gọi extendBackgroundExecutionTime() khi cần
        if isAppInBackground { stopBackgroundExecutionTime() }
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
            
            DispatchQueue.main.async {
                // GUARD: Bắt buộc kiểm tra state trước khi thay đổi StateMachine.
                // Nếu rớt mạng trong lúc đọc BLE, didDisconnect đã xử lý state rồi.
                guard ctx.peripheral.state == .connected else {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "[SESSION_CHECK] Bỏ qua vì xe đã mất kết nối trong quá trình đọc (state=\(ctx.peripheral.state.rawValue))"))
                    self.isRestoringSession = false
                    return
                }
                
                if isActive {
                    // Counter LẺ → phiên auth vẫn sống → restore .active TRỰC TIẾP
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                        message: "[RESTORE] Phiên auth vẫn active (counter lẻ) → skip auth, vào .active trực tiếp"))
                    
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
                    
                    // User requirement: 1 ngày chỉ sync time 1 lần, skip proximity token
                    if self.preferences.needsTimeSyncToday {
                        Task {
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
                    }
                } else {
                    // Counter CHẴN → cần auth lại
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[RESTORE] Phiên auth đã hết (counter chẵn) → vào standby + auth lại"))
                    self.isRestoringSession = false
                    
                    // ═══ NEARBY MODE: Giữ BLE connection, KHÔNG auth ═══
                    if self.preferences.nearbyModeEnabled {
                        if self.isAppInBackground {
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                                message: "[NEARBY] Background → giữ BLE, không auth | peripheral=\(ctx.peripheral.identifier.uuidString.prefix(8))"))
                            self.stateMachine.transition(to: .nearby)
                            self.isAuthenticating = false
                            // Đọc data cơ bản (không cần auth)
                            self.readLockStatus()
                            self.readDeviceInfo()
                            self.queryTelemetry()
                            // Poll RSSI nhẹ (5s thay vì 0.5s) để detect đi xa
                            DispatchQueue.main.async {
                                self.standbyTimer?.invalidate()
                                self.standbyTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak ctx] _ in
                                    ctx?.peripheral.readRSSI()
                                }
                            }
                            return
                        } else {
                            // Foreground: nearbyMode ON → vẫn vào .nearby, user tự bấm kết nối
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                                message: "[NEARBY] Foreground + nearbyMode ON → vào .nearby, chờ user bấm kết nối"))
                            self.stateMachine.transition(to: .nearby)
                            self.isAuthenticating = false
                            self.readLockStatus()
                            self.readDeviceInfo()
                            self.queryTelemetry()
                            // Poll RSSI nhẹ cho UI
                            DispatchQueue.main.async {
                                self.standbyTimer?.invalidate()
                                self.standbyTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak ctx] _ in
                                    ctx?.peripheral.readRSSI()
                                }
                            }
                            return
                        }
                    }
                    
                    // ═══ STANDBY DRAIN LOOP DETECTION + EXPONENTIAL BACKOFF ═══
                    // Khi connectOnlyWhenNear=true và xe ở xa, app rơi vào vòng lặp:
                    // Connect → Standby → RSSI poll → BG Task Expired → Disconnect → Reconnect → ...
                    // Mỗi chu kỳ tốn ~15-40s CPU + 1 GATT discovery + BG task time.
                    //
                    // Chiến lược:
                    // - Lần 1-2: cho phép standby bình thường (có thể user đang đi tới xe)
                    // - Lần 3+: chuyển sang pending connect VỚI exponential backoff:
                    //   Delay = min(2^(N-3) * 5s, 120s) → 5s, 10s, 20s, 40s, 80s, 120s, 120s...
                    if self.preferences.connectOnlyWhenNear {
                        self.consecutiveStandbyCount += 1
                        let drainThreshold = self.isAppInBackground ? 2 : self.maxConsecutiveStandbyBeforePending
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "[STANDBY_DRAIN] count=\(self.consecutiveStandbyCount)/\(drainThreshold) | bg=\(self.isAppInBackground)"))
                        
                        if self.consecutiveStandbyCount >= drainThreshold {
                            // Exponential backoff: 5s, 10s, 20s, 40s, 80s, 120s max
                            let exponent = self.consecutiveStandbyCount - self.maxConsecutiveStandbyBeforePending
                            let backoffDelay = min(pow(2.0, Double(exponent)) * 5.0, 120.0)
                            
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                                message: "[STANDBY_DRAIN] Đã standby \(self.consecutiveStandbyCount) lần liên tiếp → pending connect + backoff \(String(format: "%.0f", backoffDelay))s"))
                            
                            // Disconnect + pending connect sau backoff delay
                            let peripheral = ctx.peripheral
                            if let central = self.centralManager {
                                central.cancelPeripheralConnection(peripheral)
                                self.activeContext = nil
                                self.commandDispatcher = nil
                                self.pollingEngine = nil
                                self.stateMachine.transition(to: .scanning)
                                
                                // Delay trước khi pending connect — tránh reconnect liên tục khi xe ở xa
                                DispatchQueue.main.asyncAfter(deadline: .now() + backoffDelay) { [weak self] in
                                    guard let self, let central = self.centralManager, central.state == .poweredOn else { return }
                                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                                        message: "[STANDBY_DRAIN] Backoff \(String(format: "%.0f", backoffDelay))s hết → pending connect"))
                                    central.connect(peripheral, options: [
                                        CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                                        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
                                    ])
                                }
                            }
                            return
                        }
                    }
                    
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
        weakRssiConsecutiveCount = 0  // Reset RSSI counter cho chu kỳ standby mới
        
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
                
                // Trì hoãn 2.5s đối với lần đầu ghép đôi (isKnownDevice = false)
                // Đảm bảo người dùng không rút thẻ NFC ra quá sớm khi thấy màn hình chuyển sang Dashboard
                // dẫn đến việc xác thực ở firmware xe bị ngắt ngang.
                if !isKnownDevice {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[AUTH] Lần đầu ghép đôi -> Delay 2.5s trước khi vào Dashboard để giữ thẻ NFC"))
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                }
                
                stateMachine.transition(to: .active)
                self.micRetryCount = 0 // Reset MIC retry counter khi kết nối thành công
                self.phantomGuardFailCount = 0 // Reset phantom guard để tránh backoff dài không cần thiết
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
            var hardwareMac = ""
            
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
            
            // Bike Config JSON — chứa địa chỉ MAC phần cứng thực, số khung, tên xe v.v.
            // Đây là MAC thực (ví dụ: "C8:EA:F2:XX:YY:ZZ")
            // iOS CoreBluetooth KHÔNG cho phép đọc MAC trực tiếp, nên phải lấy từ GATT characteristic.
            if let char = try? ctx.requireCharacteristic(BLECharacteristic.bikeConfigJson),
               let data = try? await ctx.queue.enqueue(task: { try await ctx.io.readValue(from: char) }),
               let jsonStr = String(data: data, encoding: .utf8) {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[DEVICE_INFO] bikeConfigJson raw: \(jsonStr.prefix(300))"))
                
                // Parse JSON linh hoạt — firmware có thể dùng nhiều key khác nhau cho MAC
                if let jsonData = jsonStr.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    // Tìm MAC address từ các key phổ biến
                    let macKeys = ["mac", "MAC", "macAddress", "mac_address", "ble_mac", "bleMac", "address"]
                    for key in macKeys {
                        if let mac = dict[key] as? String, !mac.isEmpty {
                            hardwareMac = mac.trimmingCharacters(in: .whitespacesAndNewlines)
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                                message: "[DEVICE_INFO] Tìm thấy MAC phần cứng: \(hardwareMac) (key=\(key))"))
                            break
                        }
                    }
                    
                    // Fallback: lấy serial/frame từ JSON nếu GATT characteristic trước đó trả về rỗng
                    if serial.isEmpty {
                        let serialKeys = ["serial", "serialNumber", "serial_number", "frame", "frameNumber", "frame_number"]
                        for key in serialKeys {
                            if let val = dict[key] as? String, !val.isEmpty {
                                serial = val.trimmingCharacters(in: .whitespacesAndNewlines)
                                break
                            } else if let bikeConfig = dict["bikeConfig"] as? [String: Any], let val = bikeConfig[key] as? String, !val.isEmpty {
                                serial = val.trimmingCharacters(in: .whitespacesAndNewlines)
                                break
                            }
                        }
                    }
                    if model.isEmpty {
                        // Tìm "model" ở root (cũ) hoặc trong "bikeConfig" (mới)
                        if let val = dict["model"] as? String, !val.isEmpty {
                            model = val.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if let bikeConfig = dict["bikeConfig"] as? [String: Any], let val = bikeConfig["model"] as? String, !val.isEmpty {
                            model = val.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    if name.isEmpty || name == "Dat Bike" {
                        if let val = dict["name"] as? String, !val.isEmpty, val != "Dat Bike" {
                            name = val.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if let bikeConfig = dict["bikeConfig"] as? [String: Any], let val = bikeConfig["name"] as? String, !val.isEmpty, val != "Dat Bike" {
                            name = val.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    if fw.isEmpty {
                        // Parse "firmware" object trong JSON
                        if let fwObj = dict["firmware"] as? [String: Any], let ver = fwObj["version"] as? String, !ver.isEmpty {
                            fw = ver.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if let val = dict["firmware"] as? String, !val.isEmpty {
                            fw = val.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
            }
            
            let vehicleString = "Xe: \(name) / \(model) / \(serial) / FW: \(fw) / MAC: \(hardwareMac.isEmpty ? "N/A" : hardwareMac)"
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
            
            // ═══ SMART SAVE: Chỉ ghi đè nếu dữ liệu mới KHÔNG rỗng ═══
            // Tránh trường hợp lần đầu ghép nối bị lỗi read → ghi đè cache offline bằng chuỗi rỗng.
            // Lần kết nối sau query thành công → dữ liệu sẽ được lưu bổ sung.
            if !displayName.isEmpty && displayName != "Dat Bike" {
                self.preferences.savedBikeName = displayName
            } else if self.preferences.savedBikeName == nil {
                // Lần đầu chưa có gì → lưu tạm "Dat Bike"
                self.preferences.savedBikeName = displayName
            }
            
            if !serial.isEmpty {
                self.preferences.savedBikeSerial = serial
            }
            
            if !model.isEmpty {
                self.preferences.savedBikeModel = model
            }
            
            if !fw.isEmpty {
                self.preferences.savedBikeFirmware = fw
            }
            
            // MAC phần cứng: ưu tiên giá trị thực từ bikeConfigJson, fallback về CoreBluetooth UUID
            if !hardwareMac.isEmpty {
                self.preferences.savedBikeMac = hardwareMac
            } else if self.preferences.savedBikeMac == nil {
                // Chưa có MAC nào → lưu tạm UUID của CoreBluetooth (để ít nhất có thể nhận dạng)
                self.preferences.savedBikeMac = ctx.peripheral.identifier.uuidString
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "[DEVICE_INFO] Không tìm thấy MAC phần cứng trong bikeConfigJson — lưu tạm CoreBluetooth UUID"))
            }
            
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
                        message: "[RSSI] Standby chờ gần: RSSI=\(rssiValue) / Ngưỡng=\(threshold) | weakCount=\(self.weakRssiConsecutiveCount)"))
                }
                
                // Chỉ auto-authenticate khi vào vùng VÀ không bị đình chỉ trong phiên
                if Double(rssiValue) >= threshold {
                    if self.isSessionAutoSuspended {
                        return
                    }
                    
                    // Reset tất cả drain counters — RSSI đạt ngưỡng, auth sẽ thành công
                    self.consecutiveStandbyCount = 0
                    self.weakRssiConsecutiveCount = 0
                    
                    self.standbyTimer?.invalidate()
                    self.standbyTimer = nil
                    self.isAuthenticating = true
                    if let ctx = self.activeContext, let pin = self.preferences.savedPin {
                        self.executeAuthProtocol(ctx: ctx, pin: pin)
                    }
                } else {
                    // ═══ PROACTIVE STANDBY DRAIN: RSSI consistently weak ═══
                    self.weakRssiConsecutiveCount += 1
                    
                    if self.weakRssiConsecutiveCount >= self.maxWeakRssiBeforeDisconnect {
                        // ═══ FOREGROUND + connectOnlyWhenNear: Chuyển sang .nearby thay vì disconnect ═══
                        // Trường hợp: xe ngoài sân, người trong nhà — sóng yếu mạnh liên tục
                        // nhưng user chưa có nhu cầu sử dụng xe. Disconnect sẽ gây loop reconnect
                        // liên tục tốn pin. Thay vào đó, giữ kết nối nhẹ (poll RSSI 5s) ở .nearby.
                        if !self.isAppInBackground && self.preferences.connectOnlyWhenNear && !self.isSessionAutoSuspended {
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                                message: "[STANDBY_DRAIN] Foreground + RSSI yếu liên tục → chuyển .nearby (poll chậm) thay vì disconnect"))
                            self.weakRssiConsecutiveCount = 0
                            self.standbyTimer?.invalidate()
                            self.stateMachine.transition(to: .nearby)
                            self.isAuthenticating = false
                            // Poll RSSI chậm 5s — đủ để detect user quay lại gần xe
                            self.standbyTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                                self?.activeContext?.peripheral.readRSSI()
                            }
                            return
                        }
                        
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                            message: "[STANDBY_DRAIN] RSSI yếu \(self.weakRssiConsecutiveCount) lần liên tục (≈\(String(format: "%.1f", Double(self.weakRssiConsecutiveCount) * 0.5))s) → chủ động disconnect + pending connect"))
                        
                        self.standbyTimer?.invalidate()
                        self.standbyTimer = nil
                        self.weakRssiConsecutiveCount = 0
                        
                        if let ctx = self.activeContext, let central = self.centralManager {
                            let peripheral = ctx.peripheral
                            central.cancelPeripheralConnection(peripheral)
                            self.activeContext = nil
                            self.commandDispatcher = nil
                            self.pollingEngine = nil
                            self.stateMachine.transition(to: .scanning)
                            central.connect(peripheral, options: [
                                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
                            ])
                        }
                    }
                }
            } else if case .nearby = self.stateMachine.state {
                // ═══ NEARBY: RSSI poll nhẹ ═══
                let threshold = self.preferences.rssiThreshold
                
                // RSSI trở lại mạnh → chuyển về standby để auto-auth
                if Double(rssiValue) >= threshold && !self.isSessionAutoSuspended {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[NEARBY] RSSI=\(rssiValue) đạt ngưỡng \(threshold) → chuyển về standby để auth"))
                    self.weakRssiConsecutiveCount = 0
                    if let ctx = self.activeContext, let pin = self.preferences.savedPin {
                        self.standbyTimer?.invalidate()
                        self.standbyTimer = nil
                        self.isAuthenticating = true
                        self.executeAuthProtocol(ctx: ctx, pin: pin)
                    }
                    return
                }
                
                // Disconnect khi quá xa
                if rssiValue < -95 {
                    self.weakRssiConsecutiveCount += 1
                    if self.weakRssiConsecutiveCount >= 5 { // 5 × 5s = 25s liên tục xa
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "[NEARBY] RSSI=\(rssiValue) quá yếu liên tục → disconnect + pending connect"))
                        self.standbyTimer?.invalidate()
                        self.standbyTimer = nil
                        self.weakRssiConsecutiveCount = 0
                        if let ctx = self.activeContext, let central = self.centralManager {
                            let peripheral = ctx.peripheral
                            central.cancelPeripheralConnection(peripheral)
                            self.activeContext = nil
                            self.commandDispatcher = nil
                            self.pollingEngine = nil
                            self.stateMachine.transition(to: .scanning)
                            central.connect(peripheral, options: [
                                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
                            ])
                        }
                    }
                } else {
                    self.weakRssiConsecutiveCount = 0
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
        // End BG task khi về foreground — tránh leak (81 leaked tasks/28 ngày).
        // BLE callbacks chạy trên queue riêng (core.ble), không bị race với main queue.
        stopBackgroundExecutionTime()
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[LIFECYCLE] App → Foreground | smState=\(stateMachine.state.displayText) | activeCtx=\(activeContext?.peripheral.identifier.uuidString.prefix(8).description ?? "nil") | peripheralState=\(activeContext?.peripheral.state.rawValue ?? -1) | btPowerOff=\(btWasPoweredOff) | forceScan=\(forceFullScan)"))
        
        // ═══ NEARBY: Khi user mở app, refresh data nhưng KHÔNG auto-auth ═══
        // User phải bấm nút "Kết nối" để auth.
        if case .nearby = stateMachine.state,
           let ctx = activeContext,
           ctx.peripheral.state == .connected {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[NEARBY] User mở app → refresh data, chờ user bấm kết nối"))
            readLockStatus()
            readDeviceInfo()
            queryTelemetry()
            return
        }
        
        if stateMachine.state == .scanning {
            // ═══ AGGRESSIVE FOREGROUND RECONNECT ═══
            // User mở app = "tôi muốn kết nối NGAY". Hủy mọi pending stale:
            // - scanTimer đang chạy (nếu có) → clear để connect() không bị guard
            // - fallback timer đang chạy → clear
            // - pending connect cũ → cancel rồi connect mới
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[LIFECYCLE] Đang scanning → aggressive reconnect (clear stale + fresh connect)"))
            
            // Clear scan timer để connect() không bị block bởi guard "scanTimer != nil"
            scanTimer?.cancel()
            scanTimer = nil
            centralManager?.stopScan()
            
            // Clear fallback timer cũ
            disconnectFallbackTimer?.cancel()
            disconnectFallbackTimer = nil
            
            // Cancel pending connect stale (nếu có) rồi connect mới
            if let ctx = activeContext, let central = centralManager,
               ctx.peripheral.state != .connected {
                central.cancelPeripheralConnection(ctx.peripheral)
                activeContext = nil
                commandDispatcher = nil
                pollingEngine = nil
            }
            
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
