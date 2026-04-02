// BLEManager.swift — Core Bluetooth Manager with AccessorySetupKit (iOS 18+)
// Uses ASAccessorySession for discovery/pairing, CoreBluetooth for GATT communication

@preconcurrency import CoreBluetooth
import AccessorySetupKit
import Combine
import UserNotifications
import CryptoKit
import Security
import WidgetKit

final class BLEManager: NSObject, ObservableObject, @unchecked Sendable {

    // MARK: - Published State
    
    @Published var connectionState: ConnectionState = .disconnected
    @Published var lockStatus: LockStatus = .unknown(Data())
    @Published var rssi: Int = -100
    @Published var bikeInfo = BikeInfo()
    @Published var batteryTelemetry: BatteryTelemetry?
    @Published var dashboardTelemetry: DashboardTelemetry?
    @Published var logs: [BLELogEntry] = []
    @Published var discoveredBikes: [DiscoveredBike] = []
    @Published var autoUnlockEnabled: Bool {
        didSet { UserDefaults.standard.set(autoUnlockEnabled, forKey: "autoUnlockEnabled") }
    }
    @Published var autoConnectEnabled: Bool {
        didSet { UserDefaults.standard.set(autoConnectEnabled, forKey: "autoConnectEnabled") }
    }
    @Published var autoConnectRSSIThreshold: Int {
        didSet { UserDefaults.standard.set(autoConnectRSSIThreshold, forKey: "autoConnectRSSIThreshold") }
    }
    @Published var isAuthenticated = false
    @Published var hasAuthorizedAccessory = false
    @Published var pickerDismissed = false
    
    // MARK: - Private Properties
    
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var discoveredCharacteristics: [CBUUID: CBCharacteristic] = [:]
    
    private let bleQueue = DispatchQueue(label: "app.mybike.smartkey.ble", qos: .userInitiated)
    private var rssiTimer: Timer?
    private var isAuthenticating: Bool = false
    private var isConnecting: Bool = false
    private var pairingRetryCount: Int = 0
    private let maxPairingRetries: Int = 3
    
    // Encryption timeout backoff
    private var encryptionRetryCount: Int = 0
    private let maxEncryptionRetries: Int = 4
    
    // Keep-alive timer (duy trì kết nối sau khi auth xong)
    private var keepAliveTimer: Timer?
    private var isKeepAliveReading: Bool = false
    
    /// Ngăn auto-unlock lặp lại nhiều lần nếu user tự tay tắt xe lúc đang đứng gần
    private var hasTriggeredAutoUnlockSession = false
    
    /// Bond recovery mode: sau khi retry error 14 thất bại, scan lại và connect như thiết bị mới
    private var pendingBondRecovery = false
    
    /// Set by testForceDisconnect — ngăn didDisconnectPeripheral gọi scheduleReconnect
    private var suppressNextReconnect = false

    /// true khi đang chạy BLE test — tạm dừng keep-alive và RSSI polling để tránh nhiễu.
    var isTestModeActive = false

    /// Lưu counter đọc được ở bước 1 của manual flow (Read → Write → Verify).
    private var lastManualCounter: UInt32? = nil

    /// Set trước khi gọi disconnect() từ auth failure — đảm bảo scheduleReconnect luôn chạy
    /// bất kể cài đặt autoBackgroundReconnectEnabled của người dùng.
    private var forceNextReconnect: Bool = false

    /// Cho phép tự kết nối lại sau khi mất tầm phủ sóng.
    /// false = sau khi mất kết nối phải mở app mới kết nối lại được.
    var autoBackgroundReconnectEnabled: Bool = true

    /// Cho phép hiển thị thông báo local (mất kết nối, kết nối thành công, v.v.)
    var notificationsEnabled: Bool = true
    
    /// Số lần đã reconnect do counter +2 race condition — giới hạn vòng lặp
    private var raceReconnectCount: Int = 0
    private let maxRaceReconnects: Int = 2
    
    // Auth sequence state
    private var authContinuation: CheckedContinuation<Bool, Never>?
    private var pendingWriteCallbacks: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var pendingReadCallbacks: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var pendingRSSIContinuation: CheckedContinuation<Int?, Never>? = nil
    
    /// Mirror của `rssi` chỉ được truy cập từ bleQueue (không có data race).
    /// Dùng làm fallback trong RSSI-gate timeout để tránh cross-thread access vào
    /// @Published `rssi` (được ghi từ main thread).
    private var rssiRaw: Int = -100

    /// Timeout đọc/ghi BLE thích ứng theo tín hiệu (seconds).
    /// Tín hiệu yếu → retry nhiều lần hơn trong firmware → cần thêm thời gian.
    private var bleAdaptiveTimeout: TimeInterval {
        switch rssiRaw {
        case -65...0:    return 3.0   // tốt  (≥ -65 dBm)
        case -75...(-66): return 5.0  // khá  (-66 → -75 dBm)
        case -85...(-76): return 8.0  // yếu  (-76 → -85 dBm)
        default:          return 12.0 // rất yếu (< -85 dBm)
        }
    }

    /// Initial delay trước lần poll đầu tiên sau lệnh bật/tắt (ms).
    /// Tín hiệu yếu → firmware nhận lệnh chậm hơn → delay dài hơn.
    private var cmdInitialDelayMs: UInt64 {
        switch rssiRaw {
        case -65...0:    return 400   // tốt
        case -75...(-66): return 600  // khá
        case -85...(-76): return 900  // yếu
        default:          return 1200 // rất yếu
        }
    }
    
    /// True khi session BLE vẫn còn sống (retrieveConnectedPeripherals).
    /// Ngăn auth sequence chạy lại trên phiên đang hoạt động, tránh bike xóa bonding.
    private var isLiveSessionRestore: Bool = false
    
    /// Thời điểm đọc RSSI lần cuối — dùng để phát hiện RSSI stale trong didFailToConnect.
    /// rssiTimer dừng khi disconnect, nên RSSI có thể là giá trị từ nhiều phút trước.
    private var lastRSSIDate: Date? = nil
    
    /// Flag set by willRestoreState: cần auto-connect khi BT powers on
    private var shouldReconnectAfterRestore = false

    /// Set khi ASK `accessoryAdded` fires — đảm bảo lần ghép nối đầu tiên luôn connect
    /// dù autoConnectEnabled = false. Được clear sau khi connect thành công.
    private var pendingASKConnect = false
    
    // ─── AccessorySetupKit ───────────────────────────────────
    private var accessorySession = ASAccessorySession()
    private var currentAccessory: ASAccessory?
    
    private var proximityToken: String {
        if let saved = UserDefaults.standard.string(forKey: "proximityToken") {
            return saved
        }
        let token = UUID().uuidString.lowercased()
        UserDefaults.standard.set(token, forKey: "proximityToken")
        return token
    }
    
    // MARK: - Singleton
    
    static let shared = BLEManager()
    
    override init() {
        self.autoUnlockEnabled = UserDefaults.standard.bool(forKey: "autoUnlockEnabled")
        // autoConnectEnabled mặc định true (hành vi hiện tại)
        let storedAutoConnect = UserDefaults.standard.object(forKey: "autoConnectEnabled") as? Bool
        self.autoConnectEnabled = storedAutoConnect ?? true
        // autoConnectRSSIThreshold mặc định -80 dBm (xa hơn -65 của auto-unlock)
        let storedRSSI = UserDefaults.standard.object(forKey: "autoConnectRSSIThreshold") as? Int
        self.autoConnectRSSIThreshold = storedRSSI ?? -80
        super.init()
        
        // ── Persistent Log Restore ──
        // Load log history từ file (7 ngày gần nhất) vào bộ nhớ để hiển thị UI ngay
        loadPersistedLogs(daysBack: 7)
        // Ghi dấu phiên mới vào file log để phân biệt giữa các lần mở app
        PersistentLogger.shared.markSessionStart()
        
        log(.info, "BLE Manager khởi tạo (AccessorySetupKit — iOS 18+)")
        
        // ⚠️ CRITICAL: Activate ASAccessorySession BEFORE CBCentralManager.
        // Creating CBCentralManager first causes "CBManagers active with global permissions" error.
        // CBCentralManager will be initialized lazily after ASK session activates.
        accessorySession.activate(on: .main) { [weak self] event in
            self?.handleAccessoryEvent(event)
        }
    }
    
    /// Init CBCentralManager ONLY after ASAccessorySession has activated.
    /// This prevents the "CBManagers active with global permissions" conflict.
    /// Uses State Restoration ID so iOS maintains connection when app is killed.
    private func initCentralManagerIfNeeded() {
        guard centralManager == nil else { return }
        log(.info, "📡 Khởi tạo CBCentralManager (sau ASK activation, có State Restoration)")
        centralManager = CBCentralManager(delegate: self, queue: bleQueue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "app.mybike.smartkey.central"
        ])
    }
    
    // MARK: - Public API
    
    /// Show system AccessorySetupKit picker to discover and authorize a Dat Bike
    func showPicker() {
        // Each descriptor must have bluetoothServiceUUID (name alone is not allowed)
        let desc1 = ASDiscoveryDescriptor()
        desc1.bluetoothServiceUUID = BLEService.scan       // 0000FCF1...
        
        let desc2 = ASDiscoveryDescriptor()
        desc2.bluetoothServiceUUID = BLEService.auth       // 10CB0217...
        
        let desc3 = ASDiscoveryDescriptor()
        desc3.bluetoothServiceUUID = BLEService.altScan    // 15111100...
        
        // Name + service UUID combo (name alone crashes)
        let desc4 = ASDiscoveryDescriptor()
        desc4.bluetoothServiceUUID = BLEService.scan
        desc4.bluetoothNameSubstring = BLEProtocol.deviceNamePrefix  // "Dat Bike"
        
        let desc5 = ASDiscoveryDescriptor()
        desc5.bluetoothServiceUUID = BLEService.scan
        desc5.bluetoothNameSubstring = BLEProtocol.deviceNameAltPrefix  // "QT_"
        
        let bikeImage = UIImage(named: "PickerBike") ?? UIImage(systemName: "motorcycle.fill")!
        
        func createItem(desc: ASDiscoveryDescriptor) -> ASPickerDisplayItem {
            return ASPickerDisplayItem(name: "Xe máy điện DAT BIKE QUANTUM", productImage: bikeImage, descriptor: desc)
        }
        
        let pickerItems = [
            createItem(desc: desc1),
            createItem(desc: desc2),
            createItem(desc: desc3),
            createItem(desc: desc4),
            createItem(desc: desc5)
        ]
        
        log(.info, "📱 Hiện ASK Picker (5 descriptors)...")
        DispatchQueue.main.async { self.pickerDismissed = false }
        
        accessorySession.showPicker(for: pickerItems) { [weak self] error in
            if let error {
                self?.log(.error, "Picker error: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { self?.pickerDismissed = true }
        }
    }
    
    /// Start scan — now just triggers ASK picker or auto-connects authorized accessory
    func startScan() {
        // If we already have an authorized accessory, connect directly
        if let accessory = currentAccessory, accessory.bluetoothIdentifier != nil {
            log(.info, "🔗 Đã có xe authorized — kết nối trực tiếp...")
            connectToAccessory(accessory)
            return
        }
        
        // Otherwise, show the system picker
        showPicker()
    }
    
    func stopScan() {
        // No-op with ASK — picker is system-managed
        log(.info, "Dừng quét (ASK — no-op)")
    }
    
    // MARK: - AccessorySetupKit Event Handler
    
    private func handleAccessoryEvent(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            log(.success, "✅ ASAccessorySession activated")
            // Check if we already have an authorized accessory
            if let existing = accessorySession.accessories.first {
                currentAccessory = existing
                DispatchQueue.main.async { self.hasAuthorizedAccessory = true }
                log(.info, "🔗 Xe đã authorize: \(existing.displayName)")
                // ONLY init CBCentralManager when we have an authorized accessory
                // Creating it without authorized accessories = "global permissions" conflict
                initCentralManagerIfNeeded()
                // ⚠️ KHÔNG gọi connectToAccessory ở đây.
                // centralManagerDidUpdateState(.poweredOn) sẽ luôn là người gọi connection
                // (qua shouldReconnectAfterRestore, isLiveSessionRestore, hoặc fallback).
                // Nếu gọi ở đây, didDisconnectPeripheral (từ pending connection timeout trong
                // State Restoration) sẽ reset isConnecting = false ở giữa, cho phép
                // centralManagerDidUpdateState(.poweredOn) gọi connectToAccessory LẦN NỮA
                // → double connect → double discoverServices → double auth Task.
                // Log xác nhận: "📡 Tìm thấy peripheral" xuất hiện 2 lần cùng timestamp
                // tại 13:25:42, 13:31:42, 14:28:17 trong datbike_ble_log.
            } else {
                DispatchQueue.main.async { self.hasAuthorizedAccessory = false }
                log(.info, "📱 Chưa có xe nào — cần showPicker()")
                // ⚠️ Do NOT init CBCentralManager here — no authorized accessory yet
            }
            
        case .accessoryAdded:
            if let accessory = event.accessory {
                currentAccessory = accessory
                pendingASKConnect = true  // lần ghép nối đầu tiên — luôn connect bất kể autoConnect toggle
                DispatchQueue.main.async { self.hasAuthorizedAccessory = true }
                log(.success, "🏍️ Xe mới được authorize: \(accessory.displayName)")
                initCentralManagerIfNeeded()
                connectToAccessory(accessory)
            }
            
        case .accessoryRemoved:
            log(.warning, "🗑️ Xe bị xoá khỏi Accessories: \(event.accessory?.displayName ?? "")")
            currentAccessory = nil
            DispatchQueue.main.async { self.hasAuthorizedAccessory = false }
            disconnect()
            UserDefaults.standard.removeObject(forKey: "lastPeripheralUUID")
            
        case .accessoryChanged:
            if let accessory = event.accessory {
                currentAccessory = accessory
                log(.info, "🔄 Accessory updated: \(accessory.displayName)")
            }
            
        case .pickerDidDismiss:
            log(.info, "📱 Picker đã đóng")
            DispatchQueue.main.async { self.pickerDismissed = true }
            
        default:
            log(.info, "ASK event: \(event.eventType)")
        }
    }
    
    /// Connect to an authorized ASAccessory via its bluetoothIdentifier
    private func connectToAccessory(_ accessory: ASAccessory) {
        guard let btUUID = accessory.bluetoothIdentifier else {
            log(.error, "Accessory không có bluetoothIdentifier")
            return
        }
        
        guard centralManager?.state == .poweredOn else {
            log(.warning, "Bluetooth chưa bật — chờ poweredOn để kết nối")
            return
        }
        
        // Retrieve CBPeripheral from ASK identifier — NO SCANNING NEEDED
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [btUUID])
        if let p = peripherals.first {
            log(.success, "📡 Tìm thấy peripheral từ ASK: \(p.name ?? btUUID.uuidString)")
            connect(to: p)
        } else {
            log(.warning, "Không tìm thấy peripheral cho UUID \(btUUID) — thử pending connect...")
            // Fallback: connect via saved UUID
            if let savedID = UserDefaults.standard.string(forKey: "lastPeripheralUUID"),
               let uuid = UUID(uuidString: savedID) {
                let known = centralManager.retrievePeripherals(withIdentifiers: [uuid])
                if let p = known.first {
                    connect(to: p)
                    return
                }
            }
            // Cả 2 retrieval đều thất bại — iOS peripheral cache có thể chưa được populate
            // (xảy ra sau khi BT tắt/bật qua đêm). Retry sau 5s để CB stack kịp khởi tạo.
            log(.warning, "📡 Không tìm thấy peripheral trong cache — retry sau 5s...")
            DispatchQueue.main.async { self.connectionState = .disconnected }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self else { return }
                guard let accessory = self.currentAccessory else { return }
                guard self.peripheral?.state != .connected,
                      self.peripheral?.state != .connecting else { return }
                self.log(.info, "🔄 Retry connectToAccessory (peripheral cache rỗng trước đó)...")
                self.connectToAccessory(accessory)
            }
        }
    }
    
    func connect(to peripheral: CBPeripheral) {
        // Guard against duplicate connections
        guard !isConnecting else {
            log(.info, "⚠️ Đã đang kết nối, bỏ qua duplicate connect")
            return
        }
        guard peripheral.state != .connected && peripheral.state != .connecting else {
            log(.info, "⚠️ Peripheral đã ở trạng thái \(peripheral.state.rawValue), bỏ qua")
            return
        }
        
        isConnecting = true
        self.peripheral = peripheral
        peripheral.delegate = self
        
        DispatchQueue.main.async { self.connectionState = .connecting }
        log(.ble, "Đang kết nối tới \(peripheral.name ?? peripheral.identifier.uuidString)...")
        
        // Connect with notification options for background
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ])
    }
    
    func disconnect() {
        rssiTimer?.invalidate()
        rssiTimer = nil
        
        // Cancel pending read/write continuations to prevent zombie operations
        for (_, continuation) in pendingWriteCallbacks {
            continuation.resume(throwing: BLEError.notConnected)
        }
        pendingWriteCallbacks.removeAll()
        for (_, continuation) in pendingReadCallbacks {
            continuation.resume(throwing: BLEError.notConnected)
        }
        pendingReadCallbacks.removeAll()
        
        if let peripheral = peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        
        discoveredCharacteristics.removeAll()
        DispatchQueue.main.async {
            self.connectionState = .disconnected
            self.isAuthenticated = false
            self.lockStatus = .unknown(Data())
            self.writeToAppGroup()   // ← notify Widget: disconnected
        }
        log(.info, "Đã ngắt kết nối")
    }
    
    func forgetBike() {
        disconnect()
        self.peripheral = nil
        UserDefaults.standard.removeObject(forKey: "lastPeripheralUUID")
        UserDefaults.standard.removeObject(forKey: "proximityToken")
        
        // Remove from AccessorySetupKit
        if let accessory = currentAccessory {
            accessorySession.removeAccessory(accessory) { [weak self] error in
                if let error {
                    self?.log(.warning, "ASK removeAccessory error: \(error.localizedDescription)")
                } else {
                    self?.log(.info, "✅ Xe đã xoá khỏi AccessorySetupKit")
                }
            }
            currentAccessory = nil
            DispatchQueue.main.async { self.hasAuthorizedAccessory = false }
        }
        
        log(.warning, "Đã xóa kết nối với xe.")
    }
    
    // MARK: - Vehicle Control
    
    // MARK: - App Group Sync (Widget)

    /// Ghi trạng thái xe vào App Group để Widget Extension đọc.
    private func writeToAppGroup() {
        let lockRaw: String
        switch lockStatus {
        case .unlocked:  lockRaw = "unlocked"
        case .armed:     lockRaw = "armed"
        default:         lockRaw = "locked"
        }
        let phase: String
        switch connectionState {
        case .ready:           phase = "ready"
        case .authenticating:  phase = "authenticating"
        case .scanning, .connecting: phase = "connecting"
        default:               phase = "disconnected"
        }
        var state = SharedBikeState()
        state.isConnected = connectionState.isConnected
        state.isAuthenticated = isAuthenticated
        state.connectionPhase = phase
        state.lockStatusRaw = lockRaw
        state.bikeName = bikeInfo.name.isEmpty ? "Dat Bike" : bikeInfo.name
        state.batteryPercent = Int((batteryTelemetry?.soc?.soc ?? 0) * 100)
        state.odometerKm = dashboardTelemetry?.odometerKm ?? 0
        state.lastUpdated = Date()
        state.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Kích hoạt kết nối thủ công từ widget deep link
    func triggerManualConnect() {
        guard connectionState == .disconnected || connectionState == .bluetoothOff else { return }
        log(.info, "🔌 triggerManualConnect từ widget")
        tryReconnectKnown()
    }

    // MARK: - Manual Time Sync

    /// Ghi TIME_SYNC (44e2bde6) với giờ hiện tại (UTC+7) theo yêu cầu thủ công từ Settings.
    func syncTime() async throws {
        guard let syncChar = discoveredCharacteristics[BLECharacteristic.timeSync] else {
            throw BLEError.characteristicNotFound("timeSync (44e2bde6)")
        }
        let vnTZ = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = vnTZ
        let comps = cal.dateComponents([.hour, .minute, .second], from: Date())
        let secs = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
        let value = String(secs)
        let h = comps.hour ?? 0
        let m = String(format: "%02d", comps.minute ?? 0)
        let s = String(format: "%02d", comps.second ?? 0)
        log(.ble, "⏱ TIME_SYNC manual: \(value) (\(h):\(m):\(s) VN)")
        try await writeValue(Data(value.utf8), for: syncChar, type: .withResponse)
    }


    // MARK: - BLE Test Panel

    /// Đọc challenge counter hiện tại (không ghi gì). Dùng để quan sát counter raw trước/sau auth.
    /// Poll discoveredCharacteristics until the given UUID appears, or timeout.
    /// Addresses intermittent "char not found" errors when the test is triggered
    /// just before service-discovery completes.
    private func waitForCharacteristic(_ uuid: CBUUID, timeoutSeconds: Double = 5.0) async -> CBCharacteristic? {
        let intervalNS: UInt64 = 200_000_000  // 200 ms
        let maxAttempts = Int(timeoutSeconds / 0.2)
        for _ in 0..<maxAttempts {
            if let char = discoveredCharacteristics[uuid] { return char }
            try? await Task.sleep(nanoseconds: intervalNS)
        }
        return discoveredCharacteristics[uuid]
    }

    func testReadCounter() async -> String {
        guard let authChar = await waitForCharacteristic(BLECharacteristic.authChallenge) else {
            log(.error, "[TEST] authChallenge characteristic not found (waited 5s)")
            return "ERR: char not found (xe chưa kết nối / chưa discover services?)"
        }
        do {
            let data = try await readValue(for: authChar)
            guard data.count >= 4 else { return "ERR: data too short (\(data.count)b)" }
            let counter = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            log(.info, "[TEST] readCounter: \(counter) (raw: \(data.prefix(4).hexString))")
            return "counter=\(counter) raw=\(data.prefix(4).hexString)"
        } catch {
            log(.error, "[TEST] readCounter error: \(error.localizedDescription)")
            return "ERR: \(error.localizedDescription)"
        }
    }

    /// Ghi SHA-256 auth response rồi đọc lại counter — giống luồng reconnect thật.
    /// - Parameters:
    ///   - preWriteDelay: thời gian chờ trước khi ghi (giây), để test race condition.
    ///   - useWrongSHA: nếu true, ghi SHA sai (all-zeros) để test firmware rejection.
    func testAuthAndVerify(preWriteDelay: Double = 0, useWrongSHA: Bool = false) async -> String {
        let pin: String
        if let k = KeychainHelper.load(key: "authPIN") { pin = k }
        else if let u = UserDefaults.standard.string(forKey: "authPIN") { pin = u }
        else { return "ERR: no PIN" }

        guard let authChar = await waitForCharacteristic(BLECharacteristic.authChallenge) else {
            return "ERR: authChallenge not found (xe chưa kết nối?)"
        }
        do {
            // Read challenge
            let data = try await readValue(for: authChar)
            guard data.count >= 4 else { return "ERR: data too short" }
            let counter = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let shifted = counter >> 1
            let hash = SHA256.hash(data: Data("\(shifted)\(pin)".utf8))
            let hashHex = hash.compactMap { String(format: "%02x", $0) }.joined()
            log(.info, "[TEST] challenge=\(counter) shifted=\(shifted) hash=\(String(hashHex.prefix(16)))...")

            if preWriteDelay > 0 {
                log(.info, "[TEST] ⏳ Chờ \(preWriteDelay)s trước khi ghi...")
                try await Task.sleep(nanoseconds: UInt64(preWriteDelay * 1_000_000_000))
            }

            // Write (đúng hoặc sai tùy useWrongSHA)
            let hashToWrite: String
            if useWrongSHA {
                hashToWrite = String(repeating: "0", count: hashHex.count)  // all-zeros — firmware sẽ reject
                log(.warning, "[TEST] ⚠️ GHI SHA SAI (all-zeros) — firmware nên KHÔNG tăng counter")
            } else {
                hashToWrite = hashHex
            }
            try await writeValue(Data(hashToWrite.utf8), for: authChar, type: .withResponse)
            log(.info, "[TEST] Write ACK OK. Đọc lại counter...")

            // Verify loop
            for attempt in 1...4 {
                let delay: UInt64 = [400, 700, 1200, 2000][attempt - 1]
                try await Task.sleep(nanoseconds: delay * 1_000_000)
                let verify = try await readValue(for: authChar)
                guard verify.count >= 4 else { continue }
                let newCounter = verify.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                log(.info, "[TEST] Verify \(attempt): \(counter) → \(newCounter) (+\(Int(newCounter) - Int(counter)))")
                if newCounter > counter {
                    log(.success, "[TEST] ✅ Counter tăng +\(newCounter - counter) sau \(attempt) lần verify")
                    return "✅ counter \(counter)→\(newCounter) (+\(newCounter - counter)) sau \(attempt) verify"
                }
            }
            log(.error, "[TEST] ❌ Counter không tăng sau 4 lần verify")
            return "❌ counter không tăng (vẫn \(counter))"
        } catch {
            log(.error, "[TEST] error: \(error.localizedDescription)")
            return "ERR: \(error.localizedDescription)"
        }
    }

    /// Auth liên tục cho đến khi counter tăng đúng +1 (không phải +2 do race).
    /// Mỗi vòng: đọc counter baseline → ghi SHA-256 → verify tăng bao nhiêu.
    /// - Parameters:
    ///   - preWriteDelay: thời gian chờ trước khi ghi (giây)
    ///   - maxAttempts: số lần auth tối đa; nếu vượt quá → báo lỗi
    func testRetryUntilPlusOne(preWriteDelay: Double, maxAttempts: Int, useWrongSHA: Bool = false) async -> String {
        let pin: String
        if let k = KeychainHelper.load(key: "authPIN") { pin = k }
        else if let u = UserDefaults.standard.string(forKey: "authPIN") { pin = u }
        else { return "ERR: no PIN" }

        guard let authChar = await waitForCharacteristic(BLECharacteristic.authChallenge) else {
            return "ERR: authChallenge not found (xe chưa kết nối?)"
        }

        var history: [(attempt: Int, increment: Int)] = []

        for attempt in 1...max(1, maxAttempts) {
            guard peripheral?.state == .connected else {
                return "ERR: ngắt kết nối giữa chừng (attempt \(attempt))"
            }
            do {
                // 1. Đọc counter baseline
                let data = try await readValue(for: authChar)
                guard data.count >= 4 else { return "ERR: data too short" }
                let baseline = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                let shifted = baseline >> 1
                let hash = SHA256.hash(data: Data("\(shifted)\(pin)".utf8))
                let hashHex = hash.compactMap { String(format: "%02x", $0) }.joined()
                log(.info, "[RETRY-\(attempt)/\(maxAttempts)] baseline=\(baseline) shifted=\(shifted)")

                if preWriteDelay > 0 {
                    log(.info, "[RETRY-\(attempt)] ⏳ delay \(preWriteDelay)s...")
                    try await Task.sleep(nanoseconds: UInt64(preWriteDelay * 1_000_000_000))
                }

                // 2. Ghi hash (đúng hoặc sai tùy useWrongSHA)
                let hashToWrite = useWrongSHA ? String(repeating: "0", count: hashHex.count) : hashHex
                if useWrongSHA {
                    log(.warning, "[RETRY-\(attempt)] ⚠️ GHI SHA SAI (all-zeros)")
                }
                try await writeValue(Data(hashToWrite.utf8), for: authChar, type: .withResponse)
                log(.info, "[RETRY-\(attempt)] Write ACK OK. Verify...")

                // 3. Verify counter
                var increment: Int = 0
                for v in 1...4 {
                    let delay: UInt64 = [400, 700, 1200, 2000][v - 1]
                    try await Task.sleep(nanoseconds: delay * 1_000_000)
                    let verify = try await readValue(for: authChar)
                    guard verify.count >= 4 else { continue }
                    let newCounter = verify.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                    increment = Int(newCounter) - Int(baseline)
                    log(.info, "[RETRY-\(attempt)] verify \(v): \(baseline)→\(newCounter) (+\(increment))")
                    if increment > 0 { break }
                }

                history.append((attempt: attempt, increment: increment))

                if increment == 1 {
                    let trace = history.map { "#\($0.attempt):+\($0.increment)" }.joined(separator: ", ")
                    log(.success, "[RETRY] ✅ +1 đạt được ở lần \(attempt). Trace: \(trace)")
                    return "✅ +1 đạt lần \(attempt)/\(maxAttempts) | " + trace
                } else if increment == 0 {
                    log(.warning, "[RETRY-\(attempt)] ⚠️ counter không tăng — dừng")
                    return "❌ counter không tăng ở lần \(attempt)"
                } else {
                    // +2 hoặc lớn hơn → thử lại
                    log(.warning, "[RETRY-\(attempt)] +\(increment) — cần thêm lần nữa...")
                    // pause nhỏ trước lần tiếp theo để xe xử lý xong
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
            } catch {
                log(.error, "[RETRY-\(attempt)] error: \(error.localizedDescription)")
                return "ERR (attempt \(attempt)): \(error.localizedDescription)"
            }
        }

        let trace = history.map { "#\($0.attempt):+\($0.increment)" }.joined(separator: ", ")
        log(.error, "[RETRY] ❌ Không đạt +1 sau \(maxAttempts) lần. Trace: \(trace)")
        return "❌ vượt \(maxAttempts) lần, không +1 | " + trace
    }

    /// Ngắt kết nối chủ động (không scheduleReconnect). Dùng để test cold reconnect.
    func testForceDisconnect() {
        log(.info, "[TEST] Force disconnect (không auto-reconnect)")
        guard let p = peripheral else {
            log(.warning, "[TEST] Không có peripheral để ngắt")
            return
        }
        suppressNextReconnect = true
        centralManager?.cancelPeripheralConnection(p)
    }

    /// Ngắt kết nối + lập tức trigger scheduleReconnect. Test toàn bộ reconnect flow.
    func testDisconnectAndReconnect() {
        log(.info, "[TEST] Disconnect + scheduleReconnect")
        disconnect()
    }

    /// Đọc trạng thái khoá và log kết quả raw. Không ảnh hưởng state.
    func testReadStatus() async -> String {
        do {
            let status = try await readLockStatus(timeout: 8)
            return "✅ \(status.description)"
        } catch {
            return "ERR: \(error.localizedDescription)"
        }
    }

    // MARK: - Test Mode Control

    /// Tạm dừng keep-alive khi đang chạy BLE test để tránh nhiễu lệnh đọc/ghi.
    func enterTestMode() {
        isTestModeActive = true
        log(.info, "[TEST MODE] 🔒 Test mode ON — keep-alive bị tạm dừng")
    }

    /// Khôi phục keep-alive sau khi test xong.
    func exitTestMode() {
        isTestModeActive = false
        log(.info, "[TEST MODE] 🔓 Test mode OFF — khôi phục background tasks")
    }

    // MARK: - Additional Test Functions

    /// Kiểm tra trạng thái phiên auth hiện tại: connectionState, isAuthenticated, counter.
    func testCheckAuthStatus() async -> String {
        let stateStr = "state=\(connectionState) | auth=\(isAuthenticated)"
        guard let authChar = await waitForCharacteristic(BLECharacteristic.authChallenge) else {
            return "ERR: char not found\n\(stateStr)"
        }
        do {
            let data = try await readValue(for: authChar)
            guard data.count >= 4 else { return "ERR: data quá ngắn\n\(stateStr)" }
            let counter = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            log(.info, "[AUTH-STATUS] counter=\(counter) | \(stateStr)")
            return "counter=\(counter)\n\(stateStr)"
        } catch {
            return "ERR: \(error.localizedDescription)\n\(stateStr)"
        }
    }

    /// Ghi SHA sai 1 lần (all-zeros), đọc lại counter để xác nhận firmware reject.
    func testWriteWrongSHAOnce() async -> String {
        guard let authChar = await waitForCharacteristic(BLECharacteristic.authChallenge) else {
            return "ERR: authChallenge not found"
        }
        do {
            let data = try await readValue(for: authChar)
            guard data.count >= 4 else { return "ERR: data quá ngắn" }
            let counter = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let wrongHash = String(repeating: "0", count: 64)
            log(.warning, "[WRONG-SHA-ONCE] counter=\(counter) — ghi all-zeros SHA")
            try await writeValue(Data(wrongHash.utf8), for: authChar, type: .withResponse)
            try await Task.sleep(nanoseconds: 700_000_000)
            let verify = try await readValue(for: authChar)
            guard verify.count >= 4 else { return "ERR: verify data quá ngắn" }
            let newCounter = verify.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let diff = Int(newCounter) - Int(counter)
            log(.info, "[WRONG-SHA-ONCE] \(counter) → \(newCounter) (\(diff >= 0 ? "+" : "")\(diff))")
            if diff == 0 {
                return "✅ SHA sai → counter KHÔNG tăng (firmware reject đúng)"
            } else {
                return "⚠️ SHA sai nhưng counter tăng +\(diff) (unexpected!)"
            }
        } catch {
            return "ERR: \(error.localizedDescription)"
        }
    }

    /// Manual Step 1: Đọc challenge counter — lưu lại để dùng ở bước 2 và 3.
    func testManualReadChallenge() async -> String {
        guard let authChar = await waitForCharacteristic(BLECharacteristic.authChallenge) else {
            return "ERR: authChallenge not found"
        }
        do {
            let data = try await readValue(for: authChar)
            guard data.count >= 4 else { return "ERR: data quá ngắn" }
            let counter = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            lastManualCounter = counter
            log(.info, "[MANUAL-1] READ: counter=\(counter) raw=\(data.prefix(4).hexString)")
            return "📥 counter=\(counter) raw=\(data.prefix(4).hexString)\n→ Sẵn sàng ghi SHA (bước 2)"
        } catch {
            return "ERR: \(error.localizedDescription)"
        }
    }

    /// Manual Step 2: Ghi SHA dựa trên counter đã đọc ở bước 1.
    /// - Parameter wrongSHA: nếu true, ghi all-zeros thay vì hash thật.
    func testManualWriteSHA(wrongSHA: Bool = false) async -> String {
        guard let counter = lastManualCounter else {
            return "ERR: Chưa đọc challenge — bấm 'Đọc Challenge' trước"
        }
        guard let authChar = await waitForCharacteristic(BLECharacteristic.authChallenge) else {
            return "ERR: authChallenge not found"
        }
        let pin: String
        if let k = KeychainHelper.load(key: "authPIN") { pin = k }
        else if let u = UserDefaults.standard.string(forKey: "authPIN") { pin = u }
        else { return "ERR: no PIN" }
        let shifted = counter >> 1
        let hash = SHA256.hash(data: Data("\(shifted)\(pin)".utf8))
        let hashHex = hash.compactMap { String(format: "%02x", $0) }.joined()
        let toWrite = wrongSHA ? String(repeating: "0", count: 64) : hashHex
        do {
            if wrongSHA {
                log(.warning, "[MANUAL-2] WRITE SHA SAI (all-zeros) | counter=\(counter)")
            } else {
                log(.info, "[MANUAL-2] WRITE SHA đúng | counter=\(counter) shifted=\(shifted)")
            }
            try await writeValue(Data(toWrite.utf8), for: authChar, type: .withResponse)
            return wrongSHA
                ? "📤 Đã ghi SHA SAI — bấm 'Verify Counter' để kiểm tra"
                : "📤 Đã ghi SHA đúng — bấm 'Verify Counter' để kiểm tra"
        } catch {
            return "ERR: \(error.localizedDescription)"
        }
    }

    /// Manual Step 3: Đọc lại counter và so sánh với baseline từ bước 1.
    func testManualVerifyCounter() async -> String {
        guard let baseline = lastManualCounter else {
            return "ERR: Chưa có baseline — bấm 'Đọc Challenge' trước"
        }
        guard let authChar = await waitForCharacteristic(BLECharacteristic.authChallenge) else {
            return "ERR: authChallenge not found"
        }
        do {
            try await Task.sleep(nanoseconds: 500_000_000)
            let data = try await readValue(for: authChar)
            guard data.count >= 4 else { return "ERR: data quá ngắn" }
            let newCounter = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let diff = Int(newCounter) - Int(baseline)
            log(.info, "[MANUAL-3] VERIFY: \(baseline) → \(newCounter) (\(diff >= 0 ? "+" : "")\(diff))")
            lastManualCounter = newCounter  // update baseline for next step
            if diff > 0 {
                return "✅ counter \(baseline) → \(newCounter) (+\(diff))"
            } else if diff == 0 {
                return "⚠️ counter không tăng (vẫn \(newCounter)) — SHA bị reject?"
            } else {
                return "❓ counter giảm: \(baseline) → \(newCounter) (\(diff))"
            }
        } catch {
            return "ERR: \(error.localizedDescription)"
        }
    }

    /// Auth nhiều lần chờ counter tăng +2, rồi ghi SHA sai để test firmware rejection.
    func testPlusTwoThenWrongSHA(maxAttempts: Int = 8, preWriteDelay: Double = 0) async -> String {
        let pin: String
        if let k = KeychainHelper.load(key: "authPIN") { pin = k }
        else if let u = UserDefaults.standard.string(forKey: "authPIN") { pin = u }
        else { return "ERR: no PIN" }

        guard let authChar = await waitForCharacteristic(BLECharacteristic.authChallenge) else {
            return "ERR: authChallenge not found"
        }
        var history: [String] = []
        for attempt in 1...max(1, maxAttempts) {
            guard peripheral?.state == .connected else {
                return "ERR: ngắt kết nối ở attempt \(attempt)"
            }
            do {
                let base = try await readValue(for: authChar)
                guard base.count >= 4 else { return "ERR: data too short" }
                let baseline = base.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                let shifted = baseline >> 1
                let hash = SHA256.hash(data: Data("\(shifted)\(pin)".utf8))
                let hashHex = hash.compactMap { String(format: "%02x", $0) }.joined()
                if preWriteDelay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(preWriteDelay * 1_000_000_000))
                }
                try await writeValue(Data(hashHex.utf8), for: authChar, type: .withResponse)
                try await Task.sleep(nanoseconds: 600_000_000)
                let after = try await readValue(for: authChar)
                guard after.count >= 4 else { continue }
                let newCounter = after.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                let inc = Int(newCounter) - Int(baseline)
                log(.info, "[+2TEST-\(attempt)] baseline=\(baseline) → \(newCounter) (+\(inc))")
                history.append("#\(attempt):+\(inc)")
                if inc >= 2 {
                    log(.warning, "[+2TEST-\(attempt)] +\(inc) ≥ 2 — ghi SHA sai để test rejection...")
                    let wrongHash = String(repeating: "0", count: 64)
                    try await writeValue(Data(wrongHash.utf8), for: authChar, type: .withResponse)
                    try await Task.sleep(nanoseconds: 700_000_000)
                    let afterWrong = try await readValue(for: authChar)
                    guard afterWrong.count >= 4 else {
                        return "ERR: verify after wrongSHA data short | " + history.joined(separator: ", ")
                    }
                    let counterAfterWrong = afterWrong.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                    let wrongInc = Int(counterAfterWrong) - Int(newCounter)
                    log(.info, "[+2TEST] After wrong SHA: \(newCounter) → \(counterAfterWrong) (\(wrongInc >= 0 ? "+" : "")\(wrongInc))")
                    history.append("wrongSHA:\(wrongInc >= 0 ? "+" : "")\(wrongInc)")
                    let trace = history.joined(separator: ", ")
                    if wrongInc == 0 {
                        return "✅ +\(inc) → SHA sai bị reject (counter không tăng) | " + trace
                    } else {
                        return "⚠️ +\(inc) → SHA sai KHÔNG bị reject (+\(wrongInc)) | " + trace
                    }
                } else if inc == 1 {
                    log(.info, "[+2TEST-\(attempt)] +1 — tiếp tục retry...")
                    try await Task.sleep(nanoseconds: 300_000_000)
                } else {
                    let trace = history.joined(separator: ", ")
                    return "❌ counter không tăng ở attempt \(attempt) | " + trace
                }
            } catch {
                return "ERR (attempt \(attempt)): \(error.localizedDescription)"
            }
        }
        let trace = history.joined(separator: ", ")
        return "⚠️ Sau \(maxAttempts) lần không bắt được +2 | " + trace
    }

    func lock() async throws {
        guard let char = discoveredCharacteristics[BLECharacteristic.smartkeyEcho] else {
            throw BLEError.characteristicNotFound("smartkeyEcho")
        }
        log(.ble, " Gửi lệnh KHÓA (0x31 → smartkeyEcho char=\(char.uuid.uuidString.prefix(8)))")
        log(.info, "[CMD] peripheral.state=\(peripheral?.state.rawValue ?? -1)")
        try await writeValue(BLECommand.lock, for: char, type: .withResponse)
        
        try await Task.sleep(nanoseconds: 400_000_000)
        try await readLockStatus()
    }

    
    func unlock() async throws {
        guard let char = discoveredCharacteristics[BLECharacteristic.unlockCmd] else {
            throw BLEError.characteristicNotFound("unlockCmd")
        }
        // Confirmed: write ASCII '0' (0x30) = tắt xe — REPORT.md §4.2 Step 9
        log(.ble, "⚡ Gửi lệnh TẮT XE (0x30 → unlockCmd char=\(char.uuid.uuidString.prefix(8)))")
        log(.info, "[CMD] peripheral.state=\(peripheral?.state.rawValue ?? -1) isAuthenticated=\(isAuthenticated)")
        try await writeValue(BLECommand.unlock, for: char, type: .withResponse)
        // Chờ firmware xử lý lệnh trước khi bắt đầu poll — delay tăng khi tín hiệu yếu
        let delay1 = cmdInitialDelayMs
        log(.info, "[CMD] RSSI \(rssiRaw) dBm → initial poll delay \(delay1)ms")
        try await pollLockStatus(until: { $0.isLocked }, attempts: 8, initialDelayMs: delay1, intervalMs: 400)
    }
    
    func turnOff() async throws {
        guard let char = discoveredCharacteristics[BLECharacteristic.unlockCmd] else {
            throw BLEError.characteristicNotFound("unlockCmd")
        }
        log(.ble, " Gửi lệnh BẬT XE (0x31 → unlockCmd char=\(char.uuid.uuidString.prefix(8)))")
        log(.info, "[CMD] peripheral.state=\(peripheral?.state.rawValue ?? -1) isAuthenticated=\(isAuthenticated)")
        try await writeValue(BLECommand.powerOff, for: char, type: .withResponse)
        // Chờ firmware xử lý lệnh trước khi bắt đầu poll — delay tăng khi tín hiệu yếu
        let delay2 = cmdInitialDelayMs
        log(.info, "[CMD] RSSI \(rssiRaw) dBm → initial poll delay \(delay2)ms")
        try await pollLockStatus(until: { !$0.isLocked }, attempts: 8, initialDelayMs: delay2, intervalMs: 400)
    }
    
    /// Poll readLockStatus mỗi `intervalMs` ms cho đến khi predicate đúng hoặc hết attempts.
    /// `initialDelayMs`: delay trước lần poll đầu tiên để firmware kịp xử lý lệnh.
    private func pollLockStatus(
        until predicate: @escaping (LockStatus) -> Bool,
        attempts: Int,
        initialDelayMs: UInt64 = 0,
        intervalMs: UInt64
    ) async throws {
        if initialDelayMs > 0 {
            log(.info, "[POLL] Chờ \(initialDelayMs)ms để firmware xử lý lệnh...")
            try await Task.sleep(nanoseconds: initialDelayMs * 1_000_000)
        }
        for i in 0..<attempts {
            if i > 0 {
                try await Task.sleep(nanoseconds: intervalMs * 1_000_000)
            }
            guard let p = peripheral, p.state == .connected else {
                log(.error, "[POLL] peripheral ngắt kết nối (state=\(peripheral?.state.rawValue ?? -1)) — dừng poll")
                throw BLEError.notConnected
            }
            let status = try await readLockStatus()
            if predicate(status) {
                log(.info, "[POLL] Xe xác nhận trạng thái sau \(i + 1) lần poll")
                return
            }
            log(.info, "[POLL] Chờ bike đổi trạng thái... (\(i + 1)/\(attempts)) hiện tại=\(status.description)")
        }
        log(.warning, "[POLL] Hết \(attempts) lần poll — bike chưa đổi trạng thái, tiếp tục")
    }
    
    func toggleLock() async throws {
        if lockStatus.isLocked {
            try await unlock()
        } else {
            try await turnOff()
        }
    }
    
    func findBike(start: Bool = true) async throws {
        guard let char = discoveredCharacteristics[BLECharacteristic.findBike] else {
            throw BLEError.characteristicNotFound("findBike")
        }
        let cmd = start ? BLECommand.findStart : BLECommand.findStop
        log(.ble, start ? " Bắt đầu tìm xe..." : " Dừng tìm xe")
        try await writeValue(cmd, for: char, type: .withResponse)
    }
    
    @discardableResult
    func readLockStatus(timeout: TimeInterval = 20.0) async throws -> LockStatus {
        guard let char = discoveredCharacteristics[BLECharacteristic.smartkeyEcho] else {
            throw BLEError.characteristicNotFound("smartkeyEcho")
        }
        let data = try await readValue(for: char, timeout: timeout)
        let status = LockStatus(from: data)
        DispatchQueue.main.async {
            self.lockStatus = status
            self.writeToAppGroup()   // ← sync Widget
        }
        log(.info, "Trạng thái: \(status.description) (raw: \(data.hexString))")
        return status
    }
    
    func readDeviceInfo() async {
        var info = BikeInfo()
        
        // Device name (h=0x01a)
        if let char = discoveredCharacteristics[BLECharacteristic.vehicleStatus] {
            if let data = try? await readValue(for: char),
               let str = String(data: data, encoding: .utf8) {
                info.name = str.trimmingCharacters(in: .controlCharacters)
            }
        }
        
        // Serial (h=0x022)
        if let char = discoveredCharacteristics[BLECharacteristic.deviceSerialAlt] {
            if let data = try? await readValue(for: char),
               let str = String(data: data, encoding: .utf8) {
                info.serial = str.trimmingCharacters(in: .controlCharacters)
            }
        }
        
        // Model (h=0x028)
        if let char = discoveredCharacteristics[BLECharacteristic.deviceModelAlt] {
            if let data = try? await readValue(for: char),
               let str = String(data: data, encoding: .utf8) {
                info.model = str.trimmingCharacters(in: .controlCharacters)
            }
        }
        
        // Commit hash / device token (h=0x03a)
        if let char = discoveredCharacteristics[BLECharacteristic.commitHash] {
            if let data = try? await readValue(for: char),
               let str = String(data: data, encoding: .utf8) {
                info.deviceToken = str.trimmingCharacters(in: .controlCharacters)
            }
        }
        
        DispatchQueue.main.async { self.bikeInfo = info }
        log(.success, "Thông tin xe: \(info.name) / \(info.model) / \(info.serial)")
    }
    
    func readTelemetry() {
        guard let p = peripheral else { return }
        if let dashboard = discoveredCharacteristics[BLECharacteristic.dashboardData] {
            p.readValue(for: dashboard)
        }
        if let battery = discoveredCharacteristics[BLECharacteristic.batteryData] {
            p.readValue(for: battery)
        }
    }
    
    // MARK: - Authentication Sequence
    
    /// Full authentication sequence matching btsnoop_hci.log exactly
    func authenticate() async throws {
        // PIN retrieval: Keychain (secure) → migrate from UserDefaults if needed
        let pin: String
        if let keychainPIN = KeychainHelper.load(key: "authPIN") {
            pin = keychainPIN
        } else if let legacyPIN = UserDefaults.standard.string(forKey: "authPIN") {
            // Migrate from UserDefaults to Keychain
            KeychainHelper.save(key: "authPIN", value: legacyPIN)
            UserDefaults.standard.removeObject(forKey: "authPIN")
            pin = legacyPIN
            log(.info, "PIN migrated from UserDefaults to Keychain")
        } else {
            // Generate secure PIN for first use
            let generated = BLEProtocol.generateSecurePIN()
            KeychainHelper.save(key: "authPIN", value: generated)
            pin = generated
        }
        guard let peripheral = peripheral else { throw BLEError.notConnected }
        guard let authChar = discoveredCharacteristics[BLECharacteristic.authChallenge] else {
            throw BLEError.characteristicNotFound("authChallenge")
        }
        
        DispatchQueue.main.async { self.connectionState = .authenticating }
        let pinData = Data(pin.utf8)
        let savedUUID = UserDefaults.standard.string(forKey: "lastPeripheralUUID")
        let isKnownDevice = (savedUUID == peripheral.identifier.uuidString)
        
        log(.info, "[AUTH] ─── Bắt đầu xác thực ───")
        log(.info, "[AUTH] peripheral : \(peripheral.identifier.uuidString.prefix(8))... state=\(peripheral.state.rawValue) (0=dc,1=connecting,2=connected,3=disconnecting)")
        log(.info, "[AUTH] savedUUID  : \(savedUUID?.prefix(8) ?? "nil")...")
        log(.info, "[AUTH] isKnownDevice=\(isKnownDevice) → \(isKnownDevice ? "SHA-256 reconnect mode" : "Pairing mode (PIN plain-text)")")
        log(.info, "[AUTH] PIN length =\(pin.count) chars | isAuthenticating=\(isAuthenticating)")
        
        if isKnownDevice {
            // ── RECONNECT FLOW (SHA-256) với Counter Verification ──
            //
            // CÓ 2 LOẠI "CONNECTED" khác nhau:
            //   1. BLE link-layer connected (iOS Settings báo Connected): encrypted link up, SMP bonded.
            //      Xe chưa chắc show icon Bluetooth, chưa chắc nhận lệnh.
            //   2. Application-layer authenticated (xe show icon BT, nhận lệnh được):
            //      Firmware xe đã verify SHA-256 hash và tăng counter.
            //
            // Counter KHÔNG TĂNG = firmware xe chưa authenticate app ở application layer,
            // dù BLE link vẫn connected. Đây là dấu hiệu thực sự của auth failure.
            //
            // NGUYÊN NHÂN counter không tăng:
            //   a) PIN sai → hash sai → xe reject (counter không tăng là đúng)
            //   b) Firmware chưa xử lý kịp → cần chờ lâu hơn (120–800ms tăng dần)
            //   c) Xe ở trạng thái "ghost connected": iOS giữ link nhưng xe đã reset firmware
            //      → counter sẽ không bao giờ tăng dù hash đúng → phải disconnect + reconnect
            //
            // CHIẾN LƯỢC: retry với delay tăng dần; nếu sau N lần vẫn không tăng → throw
            // → catch ở didDiscoverCharacteristics → disconnect() → scheduleReconnect() → fresh challenge
            log(.info, " Tái kết nối tự động (SHA-256 Mode). Đọc Challenge...")
            
            let currentChallengeData = try await readValue(for: authChar)
            guard currentChallengeData.count >= 4 else {
                log(.error, " Lỗi: Challenge Data quá ngắn (\(currentChallengeData.count) bytes)")
                throw BLEError.authFailed("Challenge data too short")
            }
            
            // 1. Chuyển thành UInt32 Little Endian
            let currentCounter = currentChallengeData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            log(.info, "[AUTH] Challenge counter: \(currentCounter) (raw: \(currentChallengeData.prefix(4).hexString)) — \(currentCounter % 2 == 0 ? "CHẴN → cần ghi SHA-256" : "LẺ → đã xác thực sẵn")")
            
            // ── PARITY CHECK ──
            // Firmware dùng counter để track auth state:
            //   counter CHẴN (even) = chưa xác thực → app cần ghi SHA-256
            //   counter LẺ  (odd)  = đã xác thực    → app có thể gửi lệnh ngay
            //
            // Nếu counter đã LẺ khi reconnect (firmware nhớ auth từ session trước
            // hoặc internal tick qua ranh giới chẵn→lẻ), bỏ qua SHA write để
            // tránh ghi vào state đã authed → counter quay về chẵn (de-auth).
            if currentCounter % 2 == 1 {
                log(.success, " [AUTH] Counter \(currentCounter) là SỐ LẺ → Đã xác thực, bỏ qua SHA write")
                raceReconnectCount = 0
            } else {
                // Counter CHẴN → cần ghi SHA-256
                
                // 2. Dịch phải (Logical Right Shift) 1 bit — theo bytecode JS app gốc: counter_raw >>> 1
                let shifted = currentCounter >> 1
                
                // 3. Ghép chuỗi Số Nguyên + PIN (JavaScript string concat: Number + String)
                let mixStr = "\(shifted)\(pin)"
                
                // 4. Băm SHA-256 → Hex String
                let hashed = SHA256.hash(data: Data(mixStr.utf8))
                let hashHexStr = hashed.compactMap { String(format: "%02x", $0) }.joined()
                
                log(.info, "[AUTH] Counter CHẴN (\(currentCounter)) → ghi SHA-256. shifted=\(shifted), hash=\(String(hashHexStr.prefix(16)))...")
                log(.info, "[AUTH] peripheral state trước khi ghi: \(peripheral.state.rawValue)")
                // No pre-write delay: RSSI gate already provides ~1.5s settle time after BLE reconnect.
                // Adding delay here creates race condition: firmware may tick counter EVEN→ODD
                // internally during the delay, then SHA write hits ODD state → firmware rejects → +2 EVEN.
                
                // Kiểm tra peripheral vẫn còn kết nối sau khi chờ
                guard peripheral.state == .connected else {
                    log(.error, "[AUTH] ❌ Peripheral ngắt kết nối trước khi ghi SHA! state=\(peripheral.state.rawValue)")
                    throw BLEError.authFailed("Peripheral disconnected before SHA write")
                }
                log(.info, "[AUTH] Ghi SHA ngay (no pre-write delay): peripheral.state=\(peripheral.state.rawValue)")
                
                 
                // 6. Ghi SHA + verify
                // Nếu firmware reject (counter vẫn CHẴN), ghi SHA all-zeros để force-disconnect
                // ở application layer → iOS tự reconnect → fresh challenge → auth lại.
                try await writeValue(Data(hashHexStr.utf8), for: authChar, type: .withResponse)
                log(.info, " [AUTH] Write ACK nhận được. Chờ firmware verify...")

                let retryDelays: [UInt64] = [500, 1000, 2000, 4000]
                var authVerified = false

                for (attempt, delayMs) in retryDelays.enumerated() {
                    try await Task.sleep(nanoseconds: delayMs * 1_000_000)

                    let verifyData = try await readValue(for: authChar)
                    guard verifyData.count >= 4 else {
                        log(.warning, " [AUTH] Verify \(attempt+1): response ngắn (\(verifyData.count)b), retry...")
                        continue
                    }

                    let newCounter = verifyData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                    let increment = Int(newCounter) - Int(currentCounter)
                    log(.info, " [AUTH] Verify \(attempt+1): \(currentCounter) → \(newCounter) (\(increment >= 0 ? "+" : "")\(increment)) \(newCounter % 2 == 1 ? "✅ LẺ" : "CHẴN...")")

                    if newCounter % 2 == 1 {
                        log(.success, " [AUTH] Counter lẻ (\(newCounter)) — Xác thực thành công!")
                        raceReconnectCount = 0
                        authVerified = true
                        break
                    }
                }

                if !authVerified {
                    // SHA bị reject hoặc firmware timeout — ghi SHA all-zeros để signal firmware
                    // reset session ở application layer, iOS sẽ tự reconnect → fresh challenge.
                    log(.error, " [AUTH] ❌ Xác thực thất bại — ghi SHA all-zeros để reset firmware session...")
                    let zeroSHA = String(repeating: "0", count: 64)
                    try? await writeValue(Data(zeroSHA.utf8), for: authChar, type: .withResponse)
                    log(.info, " [AUTH] SHA zeros đã ghi → throw để disconnect + reconnect lấy fresh challenge")
                    raceReconnectCount += 1
                    throw BLEError.authFailed("SHA không được firmware xác nhận — disconnect để lấy fresh challenge")
                }
            }
            
        } else {
            // ── ADD NEW CARD FLOW (PLAINTEXT PIN) ──
            log(.ble, " Mã hóa thiết bị mới (Pairing Mode). Gửi PIN thô...")
            
            // Set pairing state ngay lập tức (giống Android) — không dùng watchdog
            DispatchQueue.main.async { self.connectionState = .pairingRequired }
            log(.info, " Hãy quẹt thẻ NFC vào thân xe và bấm Pair (Ghép đôi)")
            sendLocalNotification(title: "Ghép đôi Dat Bike", body: "Hãy quẹt thẻ NFC vào xe để hoàn tất xác thực")
            
            // Retry PIN write: mỗi 2s × 10 lần (tổng 20s timeout)
            var isPaired = false
            for i in 1...10 {
                do {
                    log(.ble, "⏳ Ghi PIN... (\(i)/10)")
                    try await writeValue(pinData, for: authChar, type: .withResponse)
                    isPaired = true
                    log(.success, " Ghép đôi hoàn tất!")
                    DispatchQueue.main.async { self.connectionState = .authenticating }
                    break
                } catch {
                    if i < 10 {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }
            }
            
            if !isPaired {
                log(.error, " Ghép đôi thất bại hoặc quá hạn 20s.")
                throw BLEError.authFailed("Hết thời gian chờ quẹt NFC")
            }
            
            // Step 2 & 3: PIN confirm như btsnoop (Chỉ áp dụng khi Pairing)
            log(.ble, " Step 2: PIN xác nhận lần 1...")
            try? await writeValue(pinData, for: authChar, type: .withResponse)
            try await Task.sleep(nanoseconds: UInt64(BLEProtocol.authConfirmDelay * 1_000_000_000))
            
            log(.ble, " Step 3: PIN xác nhận lần 2...")
            try? await writeValue(pinData, for: authChar, type: .withResponse)
            try await Task.sleep(nanoseconds: UInt64(BLEProtocol.authSessionDelay * 1_000_000_000))
        }
        
        // ── Step 5: TIME SYNC (44e2bde6) — seconds since midnight Vietnam time (UTC+7)
        // Chỉ ghi lần kết nối đầu tiên (giống Android) — không cần sync mỗi lần reconnect
        let isFirstConnection = (savedUUID != peripheral.identifier.uuidString)
        log(.info, "[AUTH] Step 5: isFirstConnection=\(isFirstConnection) (savedUUID \(isFirstConnection ? "≠" : "=") peripheral UUID)")
        if isFirstConnection {
            let vnTimeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = vnTimeZone
            let now = Date()
            let comps = cal.dateComponents([.hour, .minute, .second], from: now)
            let secondsSinceMidnight = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
            let timeSyncValue = String(secondsSinceMidnight)
            log(.ble, "⏱ Step 5: TIME_SYNC = \(timeSyncValue) (\(comps.hour ?? 0):\(String(format: "%02d", comps.minute ?? 0)):\(String(format: "%02d", comps.second ?? 0)) VN)")
            if let syncChar = discoveredCharacteristics[BLECharacteristic.timeSync] {
                try? await writeValue(Data(timeSyncValue.utf8), for: syncChar, type: .withResponse)
            }
        } else {
            log(.ble, "⏱ Step 5: Bỏ qua TIME_SYNC (không phải kết nối đầu tiên)")
        }

        
        // ── Step 6: Register proximity token (BEFORE CCCD — matches btsnoop order)
        let token = proximityToken
        log(.ble, " Step 6: Proximity Token: \(String(token.prefix(8)))...")
        if let autoChar = discoveredCharacteristics[BLECharacteristic.autoUnlock] {
            try? await writeValue(Data(token.utf8), for: autoChar, type: .withResponse)
        }
        
        // Step 7: CCCD cho serviceChanged (2A05)
        // NOTE: iOS CoreBluetooth không expose service 0x1801 (Generic Attribute Profile)
        // — nó được iOS host stack quản lý nội bộ, không accessible qua CB.
        // Confirmed từ logs: icon BT xe sáng lên khi auth sạch (counter +1),
        // không phụ thuộc vào CCCD write. Nếu có tìm thấy thì vẫn ghi; nếu không → bỏ qua.
        log(.ble, " Step 7: Kiểm tra serviceChanged (2A05)...")
        if let scChar = discoveredCharacteristics[BLECharacteristic.serviceChanged] {
            log(.ble, " Step 7: Tìm thấy 2A05 — ghi CCCD...")
            peripheral.setNotifyValue(true, for: scChar)
            try await Task.sleep(nanoseconds: 200_000_000)
            log(.ble, " Step 7: CCCD Write gửi xong")
        } else {
            log(.info, "[AUTH] Step 7: 2A05 không accessible (iOS quản lý 0x1801 nội bộ) — bỏ qua, icon BT do firmware sau auth")
        }
        
        // ── Done
        // Save UUID ONLY NOW -- after full auth success -- so next connect uses SHA flow correctly
        pairingRetryCount = 0
        pendingBondRecovery = false
        hasTriggeredAutoUnlockSession = false // Reset cờ auto-unlock cho phiên kết nối mới
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "lastPeripheralUUID")
        DispatchQueue.main.async {
            self.isAuthenticated = true
            self.connectionState = .ready
        }
        log(.success, " Xác thực hoàn tất! Xe sẵn sàng nhận lệnh.")
        
        // Read initial status
        _ = try? await readLockStatus()
        await readDeviceInfo()
        
        // Start RSSI monitoring
        startRSSIMonitoring()
        
        // Start keep-alive: đọc lock status mỗi 20s để giữ kết nối không bị drop
        startKeepAlive()
        
        // Grab-key: tự động mở khóa khi app được iOS đánh thức ở background
        if autoUnlockEnabled && lockStatus.isLocked && !hasTriggeredAutoUnlockSession {
            log(.info, "🔓 Grab-key auto-unlock: xe đang khóa, tự động mở...")
            do {
                try await turnOff() // NOTE: turnOff actually sends 0x31 (Turn On) logic
                hasTriggeredAutoUnlockSession = true
                sendLocalNotification(title: "MyBike Smartkey", body: "🔓 Xe đã tự động mở khóa (Grab-key)")
            } catch {
                log(.error, "Grab-key auto-unlock thất bại: \(error.localizedDescription)")
                sendLocalNotification(title: "MyBike Smartkey", body: "Đã kết nối nhưng không thể tự mở khóa")
            }
        } else {
            sendLocalNotification(title: "MyBike Smartkey", body: "Đã kết nối thành công với xe \(bikeInfo.name)")
        }
    }
    
    // MARK: - Keep-Alive
    
    private func startKeepAlive() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.keepAliveTimer?.invalidate()
            self.isKeepAliveReading = false
            // Interval 30s > read timeout 8s → không bao giờ overlap
            self.keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                guard let self, self.connectionState == .ready else { return }
                guard !self.isTestModeActive else {
                    self.log(.info, "⏭ Keep-alive skipped (test mode active)")
                    return
                }
                guard !self.isKeepAliveReading else {
                    self.log(.info, "⏭ Keep-alive skipped (read in progress)")
                    return
                }
                self.isKeepAliveReading = true
                Task {
                    _ = try? await self.readLockStatus(timeout: 8.0)
                    self.isKeepAliveReading = false
                }
            }
        }
    }
    
    // MARK: - RSSI Monitoring
    
    private func startRSSIMonitoring() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.rssiTimer?.invalidate()
            self.rssiTimer = Timer.scheduledTimer(withTimeInterval: BLEProtocol.rssiReadInterval, repeats: true) { [weak self] _ in
                guard let self = self, let p = self.peripheral else { return }
                p.readRSSI()
                
                // Read Telemetry for Reverse Engineering
                if let dashboard = self.discoveredCharacteristics[BLECharacteristic.dashboardData] {
                    p.readValue(for: dashboard)
                }
                if let battery = self.discoveredCharacteristics[BLECharacteristic.batteryData] {
                    p.readValue(for: battery)
                }
            }
        }
    }
    
    // MARK: - Background Auto-Reconnect
    
    private func scheduleReconnect() {
        guard autoConnectEnabled else {
            log(.info, "⚡ autoConnect tắt — bỏ qua pending reconnect")
            return
        }
        // Nếu peripheral nil (hiếm — sau stale-cache reset hoặc error 14),
        // thử khôi phục peripheral từ ASK bluetoothIdentifier trước khi bỏ cuộc.
        if peripheral == nil, let askUUID = currentAccessory?.bluetoothIdentifier,
           centralManager?.state == .poweredOn {
            if let p = centralManager.retrievePeripherals(withIdentifiers: [askUUID]).first {
                log(.info, "♻️ scheduleReconnect: khôi phục peripheral từ ASK UUID")
                self.peripheral = p
                p.delegate = self
            }
        }
        
        guard let peripheral = peripheral else {
            log(.warning, "⚠️ scheduleReconnect: peripheral nil — không đăng ký được pending connection")
            return
        }
        
        log(.info, " Đăng ký auto-reconnect (pending connection)...")
        
        // iOS will maintain this connection request even if app is terminated
        // When the peripheral comes back in range, iOS will wake the app
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ])
    }
    
    // MARK: - GATT Read/Write Helpers
    
    private func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) async throws {
        guard let peripheral = peripheral, peripheral.state == .connected else { throw BLEError.notConnected }
        
        let charPrefix = characteristic.uuid.uuidString.prefix(8)
        log(.ble, "[TX] WRITE (\(type == .withResponse ? "REQ" : "CMD")) \(charPrefix) (\(data.count) bytes)")
        
        if type == .withResponse {
            let timeoutSec = bleAdaptiveTimeout
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                bleQueue.async {
                    self.pendingWriteCallbacks[characteristic.uuid] = continuation
                    peripheral.writeValue(data, for: characteristic, type: type)
                }
                // QUAN TRỌNG: phải dispatch về bleQueue (không phải global()) để tránh data race
                // trên pendingWriteCallbacks Dictionary — CB delegate cũng chạy trên bleQueue.
                bleQueue.asyncAfter(deadline: .now() + timeoutSec) { [weak self] in
                    if let cont = self?.pendingWriteCallbacks.removeValue(forKey: characteristic.uuid) {
                        self?.log(.error, "[RX] TIMEOUT WRITE \(charPrefix) (\(timeoutSec)s, RSSI \(self?.rssiRaw ?? -999) dBm)")
                        cont.resume(throwing: BLEError.timeout)
                    }
                }
            }
            log(.ble, "[RX] ACK \(charPrefix)")
        } else {
            peripheral.writeValue(data, for: characteristic, type: type)
        }
    }
    
    private func readValue(for characteristic: CBCharacteristic, timeout: TimeInterval? = nil) async throws -> Data {
        guard let peripheral = peripheral, peripheral.state == .connected else { throw BLEError.notConnected }
        let charPrefix = characteristic.uuid.uuidString.prefix(8)
        log(.ble, "[TX] READ REQ \(charPrefix)")
        let timeoutSec = timeout ?? bleAdaptiveTimeout
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            bleQueue.async {
                self.pendingReadCallbacks[characteristic.uuid] = continuation
                peripheral.readValue(for: characteristic)
            }
            // QUAN TRỌNG: phải dispatch về bleQueue (không phải global()) để tránh data race
            // trên pendingReadCallbacks Dictionary — CB delegate cũng chạy trên bleQueue.
            bleQueue.asyncAfter(deadline: .now() + timeoutSec) { [weak self] in
                if let cont = self?.pendingReadCallbacks.removeValue(forKey: characteristic.uuid) {
                    self?.log(.error, "[RX] TIMEOUT READ \(charPrefix) (\(timeoutSec)s, RSSI \(self?.rssiRaw ?? -999) dBm)")
                    cont.resume(throwing: BLEError.timeout)
                }
            }
        }
    }
    
    // MARK: - Notifications
    
    func sendLocalNotification(title: String, body: String) {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    // MARK: - Logging
    
    func log(_ level: BLELogEntry.LogLevel, _ message: String) {
        let entry = BLELogEntry(timestamp: Date(), level: level, message: message)
        DispatchQueue.main.async {
            self.logs.append(entry)
        }
        // Persist to file
        PersistentLogger.shared.append(entry)
        #if DEBUG
        print("[\(level.rawValue)] \(message)")
        #endif
    }
    
    /// Load persisted logs from recent days into memory. Call once on app launch.
    func loadPersistedLogs(daysBack: Int = 7) {
        let persisted = PersistentLogger.shared.loadLogs(daysBack: daysBack)
        if !persisted.isEmpty {
            DispatchQueue.main.async {
                self.logs = persisted
            }
        }
    }
    
    func clearLogs(clearPersisted: Bool = false) {
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
        if clearPersisted {
            PersistentLogger.shared.clearAll()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async {
            switch central.state {
            case .poweredOn:
                self.log(.success, "Bluetooth đã bật")
                if self.connectionState == .bluetoothOff {
                    self.connectionState = .disconnected
                }
                
                // Xử lý State Restoration trước (ưu tiên cao hơn)
                if self.shouldReconnectAfterRestore {
                    self.shouldReconnectAfterRestore = false
                    guard self.autoConnectEnabled else {
                        self.log(.info, "⚡ autoConnect tắt — bỏ qua state restoration reconnect")
                        return
                    }
                    if let accessory = self.currentAccessory {
                        self.connectToAccessory(accessory)
                    } else {
                        self.scheduleReconnect()
                    }
                    return  // tránh double-connect
                }
                
                // Live session restore (peripheral vẫn connected khi app bị kill):
                // willRestoreState đã gọi discoverServices nhưng BT có thể chưa sẵn sàng lúc đó.
                // Gọi lại ở đây khi BT chắc chắn đã bật để đảm bảo callback didDiscoverCharacteristics luôn đến.
                if self.isLiveSessionRestore, let p = self.peripheral, p.state == .connected {
                    self.log(.info, "🔗 Live session: BT đã bật, gọi lại discoverServices để đảm bảo auth...")
                    p.discoverServices(BLEService.allServices)
                    return  // connect() sẽ bị bỏ qua anyway (state == .connected), return sớm cho rõ
                }
                
                // ASK: auto-connect to authorized accessory
                // pendingASKConnect = true nghĩa là user vừa ghép nối qua picker → luôn connect
                // dù autoConnectEnabled = false (toggle chỉ áp dụng cho auto-reconnect background)
                if let accessory = self.currentAccessory {
                    if self.pendingASKConnect || self.autoConnectEnabled {
                        self.pendingASKConnect = false
                        self.connectToAccessory(accessory)
                    } else {
                        self.log(.info, "⚡ autoConnect tắt — bỏ qua auto-connect khi BT bật")
                    }
                } else {
                    guard self.autoConnectEnabled else {
                        self.log(.info, "⚡ autoConnect tắt — bỏ qua auto-connect khi BT bật")
                        return
                    }
                    self.tryReconnectKnown()
                }
                
            case .poweredOff:
                self.log(.warning, "Bluetooth đã tắt")
                self.connectionState = .bluetoothOff
                
            case .unauthorized:
                self.log(.error, "Không có quyền Bluetooth")
                self.connectionState = .error("Cần cấp quyền Bluetooth")
                
            case .unsupported:
                self.log(.error, "Thiết bị không hỗ trợ BLE")
                self.connectionState = .error("Không hỗ trợ BLE")
                
            default:
                break
            }
        }
    }
    
    // MARK: - State Restoration (Hybrid: ASK discovery + CB persistence)
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        log(.info, "🔄 State Restoration: iOS đánh thức app — khôi phục phiên BLE")
        
        if let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for p in restoredPeripherals {
                log(.info, "  → Khôi phục peripheral: \(p.name ?? p.identifier.uuidString) (state: \(p.state.rawValue))")
                p.delegate = self
                self.peripheral = p
                
                if p.state == .connected {
                    // Session BLE vẫn sống — KHÔNG gửi bất kỳ read/write nào.
                    self.isLiveSessionRestore = true
                    self.isAuthenticated = true
                    log(.info, "  → OS giữ kết nối BLE, khôi phục session trực tiếp (KHÔNG ping)")
                    DispatchQueue.main.async {
                        self.connectionState = .ready
                        self.isAuthenticated = true
                    }
                    p.discoverServices(BLEService.allServices)
                } else {
                    log(.info, "  → Peripheral đã ngắt, sẽ auto-reconnect khi BT bật")
                    shouldReconnectAfterRestore = true
                }
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "Unknown"
        let rssiVal = RSSI.intValue
        
        log(.ble, "📡 didDiscover [\(name)] RSSI: \(rssiVal) dBm")
        
        // Auto-connect ONLY if this is our saved bike
        let savedUUID = UserDefaults.standard.string(forKey: "lastPeripheralUUID")
        if peripheral.identifier.uuidString == savedUUID {
            guard autoConnectEnabled else {
                log(.info, "⚡ autoConnect tắt — bỏ qua kết nối với \(name)")
                return
            }
            if rssiVal < autoConnectRSSIThreshold {
                log(.info, "📶 RSSI \(rssiVal) < ngưỡng \(autoConnectRSSIThreshold) dBm — bỏ qua auto-connect")
                return
            }
            log(.success, "🔗 Tự động kết nối lại xe đã lưu: \(name)!")
            connect(to: peripheral)
        } else if pendingBondRecovery { // note: bond-recovery ignores autoConnectEnabled intentionally
            let containedUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let isDatBike = name.contains(BLEProtocol.deviceNamePrefix) ||
                            name.hasPrefix(BLEProtocol.deviceNameAltPrefix) ||
                            containedUUIDs.contains(BLEService.scan) ||
                            containedUUIDs.contains(BLEService.auth)
            if isDatBike {
                log(.info, "🔧 Bond recovery: kết nối \(name) như thiết bị mới...")
                connect(to: peripheral)
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnecting = false
        isAuthenticating = false
        encryptionRetryCount = 0  // Reset khi kết nối thành công
        // KHÔNG removeAll() ở đây — characteristics đã được clear trong didDisconnect (đồng bộ).
        // Nếu removeAll() ở đây và didConnect fire 2 lần (double-connect race),
        // lần 2 sẽ xoá chars đang dùng giữa chừng auth của lần 1 → "not found".
        log(.success, " Đã kết nối BLE tới \(peripheral.name ?? "xe")")
        DispatchQueue.main.async { self.connectionState = .connecting }
        
        // Discover all services
        peripheral.discoverServices(BLEService.allServices)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnecting = false
        isAuthenticating = false
        // Cancel pending RSSI gate (defensive — in practice chars discovery requires prior successful
        // didConnect, so drops during RSSI read go through didDisconnectPeripheral;
        // included here for safety against any edge case ordering).
        if let cont = pendingRSSIContinuation {
            pendingRSSIContinuation = nil
            cont.resume(returning: nil)
        }
        let errMsg = error?.localizedDescription ?? "Không rõ lỗi"
        let nsError = error as NSError?
        let cbCode  = (error as? CBError)?.code.rawValue ?? -1
        log(.error, "❌ didFailToConnect: \(peripheral.name ?? peripheral.identifier.uuidString)")
        log(.error, "   • Mô tả : \(errMsg)")
        log(.error, "   • Domain : \(nsError?.domain ?? "-") | NSCode: \(nsError?.code ?? -1) | CBCode: \(cbCode)")
        log(.error, "   • Peripheral UUID : \(peripheral.identifier.uuidString)")
        log(.error, "   • Peripheral state: \(peripheral.state.rawValue) (0=disconnected,1=connecting,2=connected,3=disconnecting)")
        log(.error, "   • RSSI snapshot  : \(self.rssi) dBm")
        log(.error, "   • encRetry       : \(encryptionRetryCount)/\(maxEncryptionRetries)")
        log(.error, "   • isAuthenticating: \(isAuthenticating) | isAuthenticated: \(isAuthenticated)")
        log(.error, "   • chars cached   : \(discoveredCharacteristics.count)")
        log(.error, "   • savedUUID match: \(UserDefaults.standard.string(forKey: "lastPeripheralUUID") == peripheral.identifier.uuidString)")
        
        // ── iOS Encryption Timeout Deadlock Workaround ──
        // Lỗi này xảy ra khi iOS cố re-encrypt connection đã ngắt hoặc xe reset link layer.
        // Cache của bluetoothd bị kẹt, gọi connect() lại sẽ tiếp tục fail indefinitely.
        //
        // PHÂN BIỆT 2 trường hợp:
        // • Out-of-range (RSSI < -85): chỉ scheduleReconnect, không reset CM
        // • Encryption cache stale (RSSI tốt): cần rebuild CM + delay
        if errMsg.contains("encrypt the connection") {
            isConnecting = false
            log(.warning, "🔐 [ENCRYPT] Phát hiện lỗi mã hoá BLE — bắt đầu phân tích...")

            // RSSI stale check: rssiTimer dừng khi disconnect, nên self.rssi có thể là
            // giá trị từ nhiều phút trước (khi còn đứng gần xe). Nếu stale → không tin được
            // → an toàn hơn là dùng path out-of-range (chỉ scheduleReconnect, không reset CM).
            let rssiAgeSec = lastRSSIDate.map { Date().timeIntervalSince($0) } ?? 999
            let rssiIsStale = rssiAgeSec > 5.0
            log(.info, "   • RSSI age: \(String(format: "%.1f", rssiAgeSec))s (\(rssiIsStale ? "STALE — không đáng tin" : "fresh"))")

            // Nếu RSSI rất yếu HOẶC đọc quá lâu rồi → xe đang ngoài tầm, không phải stale encryption
            if self.rssi < -85 || rssiIsStale {
                log(.warning, "📡 [ENCRYPT → OUT-OF-RANGE] RSSI \(self.rssi) dBm\(rssiIsStale ? " (stale \(String(format: "%.0f", rssiAgeSec))s)" : "") → Xe ngoài tầm, KHÔNG phải encryption stale")
                log(.warning, "   → Bỏ qua CBManager reset, đăng ký pending connection chờ xe quay lại...")
                log(.warning, "   → discoveredCharacteristics.removeAll() + scheduleReconnect()")
                // KHÔNG nil peripheral — scheduleReconnect() cần nó để đăng ký pending connection
                // (nếu nil trước, guard let peripheral else { return } sẽ return ngay)
                self.discoveredCharacteristics.removeAll()
                DispatchQueue.main.async { self.connectionState = .disconnected }
                scheduleReconnect()
                return
            }

            log(.warning, "🔐 [ENCRYPT → STALE-CACHE] RSSI \(self.rssi) dBm ≥ -85 → Phán đoán: bluetoothd encryption cache bị stale")
            encryptionRetryCount += 1
            log(.warning, "♻️ [ENCRYPT] Retry \(encryptionRetryCount)/\(maxEncryptionRetries): huỷ kết nối + xoá BLE session cache...")

            central.cancelPeripheralConnection(peripheral)
            log(.info, "   → cancelPeripheralConnection() gọi xong")
            self.peripheral = nil
            self.discoveredCharacteristics.removeAll()
            log(.info, "   → peripheral = nil, discoveredCharacteristics cleared (\(discoveredCharacteristics.count) còn lại)")

            // Hết retry → yêu cầu user tắt/bật BT (không cần xóa xe)
            guard encryptionRetryCount <= maxEncryptionRetries else {
                log(.error, "❌ [ENCRYPT] Đã retry \(maxEncryptionRetries) lần liên tiếp, đều thất bại")
                log(.error, "   → Yêu cầu user tắt/bật BT thủ công (action: error state + notification)")
                DispatchQueue.main.async {
                    self.connectionState = .error("Lỗi mã hoá BLE. Vui lòng tắt và bật lại Bluetooth để kết nối lại.")
                }
                self.sendLocalNotification(title: "Lỗi kết nối", body: "Vui lòng tắt rồi bật lại Bluetooth để khắc phục.")
                return
            }

            // Delay tăng dần: bluetoothd cần ~10s để flush encryption cache nội bộ
            // (tương đương thời gian tắt/bật BT thủ công)
            let delay = 8.0 + pow(2.0, Double(encryptionRetryCount))  // 10s, 12s, 16s, 24s
            log(.info, "⏳ [ENCRYPT] Chờ \(Int(delay))s (= 8 + 2^\(encryptionRetryCount)) để flush BT cache...")
            log(.info, "   → centralManager = nil (force deinit XPC session với bluetoothd)")

            // Ép deinit XPC session với bluetoothd
            self.centralManager = nil

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.log(.info, "⏰ [ENCRYPT] Hết \(Int(delay))s — gọi initCentralManagerIfNeeded(), chờ .poweredOn tự connect lại")
                self.initCentralManagerIfNeeded()
            }
            return
        }
        
        // CBErrorPeerRemovedPairingInformation (code 14):
        // Bonding keys lệch giữa iOS và xe. Xe đã xoá LTK.
        if let cbError = error as? CBError, cbError.code == .peerRemovedPairingInformation {
            log(.error, "🔧 Error 14: Xe đã xoá bonding. Cần xoá thiết bị trong iOS Settings.")
            
            pairingRetryCount = 0
            pendingBondRecovery = false
            self.peripheral = nil
            discoveredCharacteristics.removeAll()
            UserDefaults.standard.removeObject(forKey: "lastPeripheralUUID")
            
            // Remove from ASK — user will need to re-pair after forgetting in Settings
            if let accessory = currentAccessory {
                accessorySession.removeAccessory(accessory) { [weak self] err in
                    if let err { self?.log(.warning, "ASK remove error: \(err.localizedDescription)") }
                }
                currentAccessory = nil
            }
            
            DispatchQueue.main.async {
                self.connectionState = .error("Bonding lỗi. Vào Cài đặt ➔ Bluetooth ➔ chọn xe ➔ Quên thiết bị. Sau đó mở lại app bấm Thêm xe.")
                self.isAuthenticated = false
                self.hasAuthorizedAccessory = false
            }
            
            sendLocalNotification(
                title: "Cần xóa kết nối cũ",
                body: "Vào Cài đặt ➔ Bluetooth ➔ Quên thiết bị ➔ mở app ➔ Thêm xe."
            )
            return
        }
        
        DispatchQueue.main.async {
            self.connectionState = .error(errMsg)
        }
        
        // Auto retry for other errors — reconnect via ASK accessory
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, let accessory = self.currentAccessory else { return }
            if self.centralManager != nil { // Đề phòng đang reset
                self.connectToAccessory(accessory)
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log(.warning, " Ngắt kết nối: \(error?.localizedDescription ?? "chủ động")")
        
        // Reset live session flag
        isLiveSessionRestore = false
        
        // Cancel pending read/write continuations to prevent zombie operations
        for (_, continuation) in pendingWriteCallbacks {
            continuation.resume(throwing: BLEError.notConnected)
        }
        pendingWriteCallbacks.removeAll()
        for (_, continuation) in pendingReadCallbacks {
            continuation.resume(throwing: BLEError.notConnected)
        }
        pendingReadCallbacks.removeAll()
        
        // Cancel pending RSSI gate continuation.
        // Nếu không cancel, timeout 1.5s sẽ resume với RSSI stale → Task gọi disconnect()
        // → hủy iOS pending connection → phone không bao giờ tự reconnect lại!
        if let cont = pendingRSSIContinuation {
            pendingRSSIContinuation = nil
            cont.resume(returning: nil)  // nil = cancelled, Task sẽ thoát mà không gọi disconnect()
        }
        
        
        // CBError code 14: Peer Removed Pairing Information.
        if let cbError = error as? CBError, cbError.code.rawValue == 14 {
            log(.error, "🔧 [didDisconnect] Error 14: Xe đã xoá bonding.")
            rssiTimer?.invalidate()
            rssiTimer = nil
            
            pairingRetryCount = 0
            pendingBondRecovery = false
            self.peripheral = nil
            discoveredCharacteristics.removeAll()
            UserDefaults.standard.removeObject(forKey: "lastPeripheralUUID")
            
            if let accessory = currentAccessory {
                accessorySession.removeAccessory(accessory) { [weak self] err in
                    if let err { self?.log(.warning, "ASK remove: \(err.localizedDescription)") }
                }
                currentAccessory = nil
            }
            
            DispatchQueue.main.async {
                self.connectionState = .error("Bonding lỗi. Vào Cài đặt ➔ Bluetooth ➔ Quên thiết bị ➔ mở app ➔ Thêm xe.")
                self.isAuthenticated = false
                self.hasAuthorizedAccessory = false
            }
            
            sendLocalNotification(title: "Cần xóa kết nối cũ", body: "Vào Cài đặt ➔ Bluetooth ➔ Quên thiết bị ➔ mở app ➔ Thêm xe.")
            return
        }
        
        // Reset đồng bộ TRƯỚC KHI scheduleReconnect — tránh race condition:
        // Nếu iOS reconnect rất nhanh (<1ms), main queue async chưa chạy nhưng
        // characteristics đã discovered xong → removeAll() xoá giữa chừng → "not found".
        discoveredCharacteristics.removeAll()
        isAuthenticating = false
        if !forceNextReconnect { raceReconnectCount = 0 }  // Reset chỉ khi fresh disconnect, không reset khi auth retry
        
        DispatchQueue.main.async {
            self.connectionState = .disconnected
            self.isAuthenticated = false
        }
        
        rssiTimer?.invalidate()
        rssiTimer = nil
        lastRSSIDate = nil   // xoá để didFailToConnect biết RSSI đã stale
        
        isConnecting = false
        
        // Stop keep-alive timer
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        isKeepAliveReading = false
        
        // Only notify and auto-reconnect if this was an unexpected drop (not user-initiated)
        if error != nil {
            sendLocalNotification(title: "MyBike Smartkey", body: "Đã mất kết nối với xe")
        }
        
        // ASK: auto-reconnect via pending connection

        // Auth retry (counter +2 / auth failure) — luôn reconnect bất kể cài đặt
        if forceNextReconnect {
            forceNextReconnect = false
            log(.info, "♻️ forceNextReconnect — auth retry, reconnect bất kể cài đặt backgroundReconnect")
            let hasSavedBike = UserDefaults.standard.string(forKey: "lastPeripheralUUID") != nil
            if hasSavedBike || currentAccessory != nil { scheduleReconnect() }
            return
        }

        if suppressNextReconnect {
            suppressNextReconnect = false
            log(.info, "[TEST] suppressNextReconnect=true — bỏ qua scheduleReconnect (force disconnect test)")
            DispatchQueue.main.async { self.connectionState = .disconnected }
            return
        }

        if !autoBackgroundReconnectEnabled {
            log(.info, "⛔ autoBackgroundReconnect=off — giữ disconnected, người dùng mở app để kết nối lại")
            return
        }

        let hasSavedBike = UserDefaults.standard.string(forKey: "lastPeripheralUUID") != nil
        if hasSavedBike || currentAccessory != nil {
            scheduleReconnect()
        }
    }
    
    // MARK: - Known Device Reconnect
    
    private func tryReconnectKnown() {
        guard autoConnectEnabled else {
            log(.info, "⚡ autoConnect tắt — bỏ qua tryReconnectKnown")
            return
        }
        let savedID = UserDefaults.standard.string(forKey: "lastPeripheralUUID")
        guard savedID != nil else { return }
        
        // 1. Check if peripheral is already physically connected to iOS
        let connected = centralManager.retrieveConnectedPeripherals(withServices: [BLEService.auth, BLEService.main, BLEService.scan, BLEService.altScan])
        if let p = connected.first(where: { $0.identifier.uuidString == savedID }) {
            isLiveSessionRestore = true
            log(.info, "🔗 Xe đang kết nối (iOS cache): \(p.name ?? "unknown") — khôi phục session")
            connect(to: p)
            return
        }
        
        // 2. Retrieve from cache
        if let savedID = savedID, let uuid = UUID(uuidString: savedID) {
            let known = centralManager.retrievePeripherals(withIdentifiers: [uuid])
            if let p = known.first {
                if p.state == .connected {
                    isLiveSessionRestore = true
                }
                log(.info, "🔗 Tìm thấy xe từ cache: \(p.name ?? savedID)")
                connect(to: p)
                return
            }
        }
        
        // 3. Fallback: pending connect (iOS handles reconnection in background)
        log(.info, "🔍 Không tìm thấy xe, chờ ASK hoặc pending connection...")
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log(.error, "Lỗi discover services: \(error.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services else { return }
        log(.ble, "Phát hiện \(services.count) services")
        
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log(.error, "Lỗi discover characteristics: \(error.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics else { return }
        
        for char in characteristics {
            discoveredCharacteristics[char.uuid] = char
        }
        
        log(.ble, "Service \(service.uuid.uuidString.prefix(8))... — \(characteristics.count) characteristics")
        
        // Check if we have all essential characteristics
        let hasAuth = discoveredCharacteristics[BLECharacteristic.authChallenge] != nil
        let hasLock = discoveredCharacteristics[BLECharacteristic.smartkeyEcho] != nil
        let hasUnlock = discoveredCharacteristics[BLECharacteristic.unlockCmd] != nil
        
        if hasAuth && hasLock && hasUnlock {
            // ── Live session restore path (State Restoration hoặc retrieveConnectedPeripherals) ──
            if isLiveSessionRestore {
                isLiveSessionRestore = false
                log(.success, " Characteristics sẵn sàng (live session). Kiểm tra link thật...")
                
                DispatchQueue.main.async {
                    self.connectionState = .sessionVerifying  // hiển thị "Đang khôi phục phiên..."
                }
                
                Task {
                    // ── VALIDATION PING ──
                    // iOS đôi lúc báo state=connected nhưng link layer thực tế đã chết.
                    // Gửi 1 READ nhẹ với timeout 2s để xác nhận xe có thật sự phản hồi không.
                    guard let echoChar = discoveredCharacteristics[BLECharacteristic.smartkeyEcho] else {
                        log(.warning, " ⚠️ echoChar không tìm thấy, bỏ qua ping")
                        return
                    }
                    
                    // Race giữa read thật và timeout 2s
                    var pingData: Data? = nil
                    let pingTask = Task<Data?, Never> {
                        do {
                            return try await readValue(for: echoChar)
                        } catch {
                            return nil
                        }
                    }
                    let timeoutTask = Task<Data?, Never> {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        pingTask.cancel()
                        return nil
                    }
                    
                    // Chờ cái nào xong trước
                    pingData = await pingTask.value
                    timeoutTask.cancel()
                    
                    if let data = pingData {
                        // Link thật sự sống — trust session, bỏ qua auth
                        let status = LockStatus(from: data)
                        log(.success, " ✅ Live session xác nhận: xe phản hồi. Trạng thái: \(status.description)")
                        DispatchQueue.main.async {
                            self.isAuthenticated = true
                            self.connectionState = .ready
                            self.lockStatus = status
                            self.writeToAppGroup()
                        }
                        await readDeviceInfo()
                        startRSSIMonitoring()
                        startKeepAlive()  // ← BUG FIX: keep-alive bị thiếu trong live session path
                    } else {
                        // Link chết (zombie session) — phải auth lại từ đầu
                        log(.warning, " ⚠️ Live session ZOMBIE: xe không phản hồi trong 2s. Bắt đầu xác thực lại...")
                        // QUAN TRỌNG: phải set isAuthenticating = true TRƯỚC khi gọi authenticate().
                        // Nếu không, didDiscoverCharacteristics từ service khác có thể fire và
                        // khởi động thêm 1 authenticate() concurrently → double auth race →
                        // continuation bị ghi đè → Task 1 treo vĩnh viễn.
                        self.isAuthenticating = true
                        DispatchQueue.main.async {
                            self.isAuthenticated = false
                            self.connectionState = .authenticating
                        }
                        do {
                            try await authenticate()
                            self.isAuthenticating = false
                            DispatchQueue.main.async {
                                self.connectionState = .ready
                                self.isAuthenticated = true
                            }
                            _ = try? await readLockStatus()
                            await readDeviceInfo()
                            startRSSIMonitoring()
                            startKeepAlive()
                        } catch {
                            self.isAuthenticating = false
                            log(.error, " Xác thực thất bại sau zombie session: \(error.localizedDescription)")
                            log(.info, "   → Ngắt kết nối để kích hoạt scheduleReconnect...")
                            DispatchQueue.main.async {
                                self.connectionState = .error("Xác thực thất bại — đang thử lại...")
                                self.isAuthenticated = false
                            }
                            self.disconnect()
                        }
                    }
                }
                return
            }
            
            guard !isAuthenticated && !isAuthenticating else { return }
            
            isAuthenticating = true
            log(.success, " Tất cả characteristics sẵn sàng. Kiểm tra tín hiệu trước khi xác thực...")
            
            Task {
                // ── RSSI GATE: đọc RSSI trước khi auth ──
                // Khi ở xa, connection unstable → challenge-response timeout → auth fail lặp vô tận.
                // Chỉ auth khi RSSI đủ mạnh; nếu yếu → ngắt ngay, iOS pending connection
                // sẽ tự reconnect khi xe vào gần hơn, lúc đó auth mới thành công.
                // nil = RSSI read bị cancel vì kết nối ngắt (didDisconnectPeripheral cancel continuation).
                // Không dùng Int fallback để tránh gọi disconnect() trên connection đã mất.
                let rssiOptional: Int?
                if let p = self.peripheral, p.state == .connected {
                    rssiOptional = await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
                        self.bleQueue.async {
                            self.pendingRSSIContinuation = cont
                            p.readRSSI()
                        }
                        // Timeout 1.5s: nếu BLE không trả RSSI (hiếm), dùng rssiRaw mirror.
                        // KHÔNG dùng self.rssi vì đó là @Published (main thread) — data race.
                        // rssiRaw được cập nhật trong didReadRSSI (bleQueue) nên an toàn ở đây.
                        self.bleQueue.asyncAfter(deadline: .now() + 1.5) {
                            if let cont = self.pendingRSSIContinuation {
                                self.pendingRSSIContinuation = nil
                                cont.resume(returning: self.rssiRaw)  // bleQueue-local mirror
                            }
                        }
                    }
                } else {
                    rssiOptional = nil  // không còn connected — hủy xác thực ngay
                }
                
                // Nếu nil: kết nối đã ngắt trong khi đọc RSSI → thoát sạch,
                // KHÔNG gọi disconnect() để tránh hủy iOS pending connection.
                guard let rssiNow = rssiOptional else {
                    log(.info, "📶 RSSI read bị hủy (kết nối ngắt trong khi đọc RSSI) — thoát xác thực")
                    isAuthenticating = false
                    return
                }
                
                let authMin = BLEProtocol.rssiAuthMinimum
                guard rssiNow >= authMin else {
                    log(.warning, "📶 RSSI \(rssiNow) dBm < \(authMin) dBm — tín hiệu quá yếu, hoãn xác thực")
                    log(.info, "   → Ngắt kết nối, chờ iOS reconnect khi xe vào gần hơn...")
                    isAuthenticating = false
                    self.disconnect()  // → scheduleReconnect() tự động trong didDisconnect
                    return
                }
                
                log(.info, "📶 RSSI \(rssiNow) dBm ≥ \(authMin) dBm — tín hiệu OK, bắt đầu xác thực")
                
                do {
                    try await authenticate()
                } catch {
                    log(.error, "Xác thực thất bại: \(error.localizedDescription)")
                    log(.info, "   → Ngắt kết nối để kích hoạt scheduleReconnect tự động...")
                    DispatchQueue.main.async {
                        let isGivingUp = self.suppressNextReconnect
                        self.connectionState = .error(isGivingUp
                            ? "Không thể xác thực xe — thử di chuyển gần xe hoặc tắt/bật BLE."
                            : "Xác thực thất bại — đang thử lại...")
                    }
                    // disconnect() → didDisconnectPeripheral → scheduleReconnect()
                    if !self.suppressNextReconnect { self.forceNextReconnect = true }  // Don't reconnect if give-up flag set
                    self.disconnect()
                }
                isAuthenticating = false
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let continuation = pendingWriteCallbacks.removeValue(forKey: characteristic.uuid) {
            if let error = error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let data = characteristic.value ?? Data()
        let charPrefix = characteristic.uuid.uuidString.prefix(8)
        
        // Handle pending read callback
        if let continuation = pendingReadCallbacks.removeValue(forKey: characteristic.uuid) {
            if let error = error {
                log(.error, "[RX] READ ERROR \(charPrefix): \(error.localizedDescription)")
                continuation.resume(throwing: error)
            } else {
                log(.ble, "[RX] READ RESP \(charPrefix) (\(data.count) bytes)")
                continuation.resume(returning: data)
            }
            return
        }
        
        // Handle notifications
        if characteristic.uuid == BLECharacteristic.dashboardData {
            // log(.info, " [DEBUG TELEMETRY] DASHBOARD: \(hexData)")
            let t = DashboardTelemetry(from: data)
            DispatchQueue.main.async { self.dashboardTelemetry = t }
            return
        }
        if characteristic.uuid == BLECharacteristic.batteryData {
            // log(.info, " [DEBUG TELEMETRY] BATTERY: \(hexData)")
            if let strJSON = String(bytes: data, encoding: .utf8),
               let jsonData = strJSON.data(using: .utf8) {
                if let decoded = try? JSONDecoder().decode(BatteryTelemetry.self, from: jsonData) {
                    DispatchQueue.main.async { self.batteryTelemetry = decoded }
                }
            }
            return
        }
        
        log(.ble, "[RX] NOTIFY \(charPrefix) (\(data.count) bytes)")
        if characteristic.uuid == BLECharacteristic.smartkeyEcho ||
           characteristic.uuid == BLECharacteristic.statusFlags {
            let status = LockStatus(from: data)
            DispatchQueue.main.async { self.lockStatus = status }
            log(.info, " Cập nhật trạng thái xe: \(status.description)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log(.error, " [RX] Lỗi ghi CCCD (\(characteristic.uuid.uuidString.prefix(8))): \(error.localizedDescription)")
            return
        }
        
        if characteristic.isNotifying {
            log(.success, " [RX] CCCD ACK: Enabled Notify cho \(characteristic.uuid.uuidString.prefix(8)) thành công!")
        } else {
            log(.warning, " [RX] CCCD ACK: Disabled Notify từ \(characteristic.uuid.uuidString.prefix(8))")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let rssiVal = RSSI.intValue
        lastRSSIDate = Date()
        rssiRaw = rssiVal  // cập nhật bleQueue mirror trước khi dispatch sang main
        DispatchQueue.main.async { self.rssi = rssiVal }
        
        // Resume any pending one-shot RSSI read (used by RSSI gate before auth)
        if let cont = pendingRSSIContinuation {
            pendingRSSIContinuation = nil
            cont.resume(returning: rssiVal)
        }
        
        // Auto-unlock: dùng ngưỡng do user cài trong Settings (UserDefaults),
        // fallback về constant nếu chưa cài (slider chưa được kéo).
        let savedThreshold = UserDefaults.standard.double(forKey: "rssiThreshold")
        let autoUnlockThreshold = savedThreshold != 0 ? Int(savedThreshold) : BLEProtocol.rssiThreshold
        if autoUnlockEnabled && lockStatus.isLocked && !hasTriggeredAutoUnlockSession && rssiVal > autoUnlockThreshold {
            hasTriggeredAutoUnlockSession = true
            log(.info, " Ở gần xe (RSSI: \(rssiVal) > \(BLEProtocol.rssiThreshold)). Auto-unlock...")
            sendLocalNotification(title: "Auto Unlock", body: "Phát hiện bạn đang ở gần xe. Đang mở khóa...")
            Task {
                try? await turnOff() // NOTE: turnOff actually sends 0x31 (Turn On) logic
            }
        }
    }
}

// MARK: - BLE Errors

enum BLEError: LocalizedError {
    case notConnected
    case characteristicNotFound(String)
    case timeout
    case authFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .notConnected:                return "Chưa kết nối với xe"
        case .characteristicNotFound(let c): return "Không tìm thấy characteristic: \(c)"
        case .timeout:                     return "Hết thời gian chờ"
        case .authFailed(let msg):         return "Xác thực thất bại: \(msg)"
        }
    }
}

// MARK: - Keychain Helper

/// Internal so SmartKeyViewModel can read/write the auth PIN via the same Keychain slot.
enum KeychainHelper {
    private static let serviceName = "app.mybike.smartkey"
    
    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        // Delete existing item first
        SecItemDelete(query as CFDictionary)
        
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }
    
    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
