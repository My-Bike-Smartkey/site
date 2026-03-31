// BLEManager.swift — Core Bluetooth Manager with Background BLE Optimization
// Handles scanning, connection, state restoration, and auto-reconnect

@preconcurrency import CoreBluetooth
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
    @Published var isAuthenticated = false
    
    // MARK: - Private Properties
    
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var discoveredCharacteristics: [CBUUID: CBCharacteristic] = [:]
    
    private let bleQueue = DispatchQueue(label: "com.jedix.datbikesmartkey.ble", qos: .userInitiated)
    private var rssiTimer: Timer?
    private var scanRestartTimer: Timer?
    private var isAuthenticating: Bool = false
    private var pairingRetryCount: Int = 0
    private let maxPairingRetries: Int = 3
    
    /// Bond recovery mode: sau khi retry error 14 thất bại, scan lại và connect như thiết bị mới
    private var pendingBondRecovery = false
    
    // Auth sequence state
    private var authContinuation: CheckedContinuation<Bool, Never>?
    private var pendingWriteCallbacks: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var pendingReadCallbacks: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    
    
    /// Flag set by willRestoreState: cần bật lại background scan khi BT powers on
    private var shouldResumeScanAfterRestore = false
    
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
        super.init()
        
        // State restoration is only supported on real devices with bluetooth-central background mode
        #if targetEnvironment(simulator)
        let options: [String: Any] = [
            CBCentralManagerOptionShowPowerAlertKey: true
        ]
        log(.info, "BLE Manager khởi tạo (Simulator — không có State Restoration)")
        #else
        let options: [String: Any] = [
            CBCentralManagerOptionRestoreIdentifierKey: BLEProtocol.centralRestoreID,
            CBCentralManagerOptionShowPowerAlertKey: true
        ]
        log(.info, "BLE Manager khởi tạo với State Restoration")
        #endif
        
        centralManager = CBCentralManager(delegate: self, queue: bleQueue, options: options)
    }
    
    // MARK: - Public API
    
    func startScan() {
        guard centralManager.state == .poweredOn else {
            log(.warning, "Bluetooth chưa bật")
            DispatchQueue.main.async { self.connectionState = .bluetoothOff }
            return
        }
        
        guard connectionState != .scanning else { return }
        
        DispatchQueue.main.async {
            self.connectionState = .scanning
            self.discoveredBikes.removeAll()
        }
        log(.ble, "Bắt đầu quét BLE (service: AUTH + MAIN)...")
        
        centralManager.scanForPeripherals(
            withServices: [BLEService.auth, BLEService.main],
            options: nil
        )
    }
    
    /// Quét ngầm cho xe đã lưu — Grab-key mode.
    /// iOS duy trì scan này ngay cả khi app bị vuốt tắt (kill). Khi phát hiện BLE advertisement
    /// chứa Service UUID 128-bit độc quyền (10CB0217..., D4905F67...), iOS tự đánh thức app
    /// qua State Restoration → didDiscover → auto-connect → authenticate → mở khóa xe.
    /// Cực kỳ tiết kiệm pin vì iOS dùng hardware BLE filter, app không cần chạy liên tục.
    private func startBackgroundScan() {
        guard centralManager.state == .poweredOn else { return }
        guard UserDefaults.standard.string(forKey: "lastPeripheralUUID") != nil else { return }
        guard !isAuthenticated else { return }
        
        log(.info, "📡 Grab-key: bật quét ngầm BLE (Service UUID 128-bit: AUTH + MAIN)")
        
        // allowDuplicatesKey = false: bắt buộc cho background scan.
        // iOS tự bỏ qua key này khi ở background, nhưng set rõ ràng cho chắc chắn.
        centralManager.scanForPeripherals(
            withServices: BLEService.backgroundScanUUIDs,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
    
    func stopScan() {
        centralManager.stopScan()
        scanRestartTimer?.invalidate()
        scanRestartTimer = nil
        log(.info, "Đã dừng quét")
    }
    
    func connect(to peripheral: CBPeripheral) {
        stopScan()
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
        log(.warning, "Đã xóa kết nối với xe trên App. Để xóa hoàn toàn, vui lòng vào Cài đặt Bluetooth của iPhone và chọn 'Quên thiết bị' (Forget This Device).")
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
        var state = SharedBikeState()
        state.isConnected = connectionState.isConnected
        state.lockStatusRaw = lockRaw
        state.bikeName = bikeInfo.name.isEmpty ? "Dat Bike" : bikeInfo.name
        state.batteryPercent = Int((batteryTelemetry?.soc?.soc ?? 0) * 100)
        state.odometerKm = dashboardTelemetry?.odometerKm ?? 0
        state.lastUpdated = Date()
        state.save()
        WidgetCenter.shared.reloadAllTimelines()
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


    func lock() async throws {
        guard let char = discoveredCharacteristics[BLECharacteristic.smartkeyEcho] else {
            throw BLEError.characteristicNotFound("smartkeyEcho")
        }
        log(.ble, " Gửi lệnh KHÓA (0x31 → smartkeyEcho)")
        try await writeValue(BLECommand.lock, for: char, type: .withResponse)
        
        try await Task.sleep(nanoseconds: 400_000_000)
        try await readLockStatus()
    }

    
    func unlock() async throws {
        guard let char = discoveredCharacteristics[BLECharacteristic.unlockCmd] else {
            throw BLEError.characteristicNotFound("unlockCmd")
        }
        // Confirmed: write ASCII '0' (0x30) = tắt xe — REPORT.md §4.2 Step 9
        log(.ble, "⚡ Gửi lệnh TẮT XE (0x30 → unlockCmd)")
        try await writeValue(BLECommand.unlock, for: char, type: .withResponse)
        // Poll đến khi bike xác nhận đã tắt (isLocked = true / raw 0000)
        // Bike cần >400ms để đổi state sau lệnh 0x30 — thực tế ~1s
        try await pollLockStatus(until: { $0.isLocked }, attempts: 8, intervalMs: 400)
    }
    
    func turnOff() async throws {
        guard let char = discoveredCharacteristics[BLECharacteristic.unlockCmd] else {
            throw BLEError.characteristicNotFound("unlockCmd")
        }
        log(.ble, " Gửi lệnh BẬT XE (0x31 → unlockCmd)")
        try await writeValue(BLECommand.powerOff, for: char, type: .withResponse)
        // Poll đến khi bike xác nhận đã bật (isLocked = false / raw 0200)
        try await pollLockStatus(until: { !$0.isLocked }, attempts: 8, intervalMs: 400)
    }
    
    /// Poll readLockStatus mỗi `intervalMs` ms cho đến khi predicate đúng hoặc hết attempts.
    private func pollLockStatus(
        until predicate: @escaping (LockStatus) -> Bool,
        attempts: Int,
        intervalMs: UInt64
    ) async throws {
        for i in 0..<attempts {
            try await Task.sleep(nanoseconds: intervalMs * 1_000_000)
            let status = try await readLockStatus()
            if predicate(status) { return }
            if i < attempts - 1 {
                log(.info, "Chờ bike đổi trạng thái... (\(i + 1)/\(attempts))")
            }
        }
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
    func readLockStatus() async throws -> LockStatus {
        guard let char = discoveredCharacteristics[BLECharacteristic.smartkeyEcho] else {
            throw BLEError.characteristicNotFound("smartkeyEcho")
        }
        let data = try await readValue(for: char)
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
        var isKnownDevice = (savedUUID == peripheral.identifier.uuidString)
        
        // ── Pre-auth bond check ──
        // iOS không expose bondState như Android. Thay vào đó, thử đọc encrypted characteristic.
        // Nếu bond stale (xe đã xóa LTK) → read fail → chuyển sang new card flow, tránh gửi SHA-256
        // trên bond hỏng (gây xe wipe bonding → error 14 loop).
        if isKnownDevice {
            do {
                let testData = try await readValue(for: authChar)
                if testData.count < 4 {
                    log(.warning, " Pre-auth check: Challenge quá ngắn (\(testData.count)B) → coi như bond stale")
                    isKnownDevice = false
                    UserDefaults.standard.removeObject(forKey: "lastPeripheralUUID")
                }
            } catch {
                log(.warning, " Pre-auth check: Read challenge thất bại (\(error.localizedDescription)) → bond có thể stale, chuyển sang new card flow")
                isKnownDevice = false
                UserDefaults.standard.removeObject(forKey: "lastPeripheralUUID")
            }
        }
        
        if isKnownDevice {
            // ── RECONNECT FLOW (SHA-256) with Counter Verification ──
            log(.ble, " Tái kết nối tự động (SHA-256 Mode). Đọc Challenge...")
            
            // Challenge đã được đọc thành công trong pre-auth check, đọc lại để lấy giá trị mới nhất
            var currentChallengeData = try await readValue(for: authChar)
            guard currentChallengeData.count >= 4 else {
                log(.error, " Lỗi: Challenge Data quá ngắn (\(currentChallengeData.count) bytes)")
                throw BLEError.authFailed("Challenge data too short")
            }
            
            var authSuccess = false
            
            for attempt in 1...BLEProtocol.maxAuthRetries {
                if attempt > 1 {
                    // Đợi trước khi retry — giống Dat Bike app (~1.2s giữa các lần)
                    try await Task.sleep(nanoseconds: UInt64(BLEProtocol.authRetryDelay * 1_000_000_000))
                    currentChallengeData = try await readValue(for: authChar)
                    guard currentChallengeData.count >= 4 else {
                        log(.error, " Retry \(attempt): Challenge data quá ngắn")
                        continue
                    }
                    log(.ble, " Retry \(attempt)/\(BLEProtocol.maxAuthRetries): đọc counter mới...")
                }
                
                // 1. Chuyển thành UInt32 Little Endian
                let currentCounter = currentChallengeData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                
                // 2. Dịch phải (Logical Right Shift) 1 bit
                let shifted = currentCounter >> 1
                
                // 3. Ghép chuỗi Số Nguyên + PIN
                let mixStr = "\(shifted)\(pin)"
                
                // 4. Băm SHA-256 → Hex String
                let hashed = SHA256.hash(data: Data(mixStr.utf8))
                let hashHexStr = hashed.compactMap { String(format: "%02x", $0) }.joined()
                
                let challengeHex = currentChallengeData.map { String(format: "%02x", $0) }.joined()
                log(.ble, " [AUTH] attempt \(attempt) — computing response...")
                
                // 5. Ghi hash
                try await writeValue(Data(hashHexStr.utf8), for: authChar, type: .withResponse)
                
                // 6. Đọc lại counter để xác nhận — Dat Bike app kiểm tra counter +1
                try await Task.sleep(nanoseconds: 200_000_000) // 200ms cho firmware xử lý
                let verifyData = try await readValue(for: authChar)
                guard verifyData.count >= 4 else {
                    log(.warning, " Verify: data quá ngắn (\(verifyData.count) bytes)")
                    continue
                }
                let newCounter = verifyData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                
                if newCounter > currentCounter {
                    authSuccess = true
                    log(.success, " Counter verified: \(currentCounter) → \(newCounter) (+\(newCounter - currentCounter)). Auth OK!")
                    break
                }
                
                log(.warning, " Counter không tăng (attempt \(attempt)/\(BLEProtocol.maxAuthRetries)): expected >\(currentCounter), got \(newCounter)")
            }
            
            if !authSuccess {
                throw BLEError.authFailed("Counter verification failed after \(BLEProtocol.maxAuthRetries) attempts")
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
        
        // THỬ NGHIỆM TẮT BOND: Tạm thời Không Đăng Ký CCCD (serviceChanged)
        // Nếu việc đăng ký CCCD này ép iOS phải tạo mã hóa / lưu Bond, tắt nó đi sẽ tránh Error 14
        /*
        log(.ble, " Step 7: Dang ky CCCD (serviceChanged) de xe hien icon Bluetooth...")
        if let scChar = discoveredCharacteristics[BLECharacteristic.serviceChanged] {
            peripheral.setNotifyValue(true, for: scChar)
            try await Task.sleep(nanoseconds: 200_000_000) // Wait for CCCD Write Response from vehicle
            log(.ble, " Step 7: Da gui CCCD Write -  cho xe phan hoi...")
        }
        */
        
        // ── Done
        // Save UUID ONLY NOW -- after full auth success -- so next connect uses SHA flow correctly
        pairingRetryCount = 0
        pendingBondRecovery = false
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
        
        // Grab-key: tự động mở khóa khi app được iOS đánh thức ở background
        if autoUnlockEnabled && lockStatus.isLocked {
            log(.info, "🔓 Grab-key auto-unlock: xe đang khóa, tự động mở...")
            do {
                try await unlock()
                sendLocalNotification(title: "Dat Bike", body: "🔓 Xe đã tự động mở khóa (Grab-key)")
            } catch {
                log(.error, "Grab-key auto-unlock thất bại: \(error.localizedDescription)")
                sendLocalNotification(title: "Dat Bike Connected", body: "Đã kết nối nhưng không thể tự mở khóa")
            }
        } else {
            sendLocalNotification(title: "Dat Bike Connected", body: "Đã kết nối thành công với xe \(bikeInfo.name)")
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
        guard let peripheral = peripheral else { return }
        
        log(.info, " Đăng ký auto-reconnect (pending connection)...")
        
        // iOS will maintain this connection request even if app is terminated
        // When the peripheral comes back in range, iOS will wake the app
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ])
    }
    
    /// Kết nối lại trực tiếp khi gặp error 14 — không scan, không tạo kết nối mới hoàn toàn.
    /// Dùng peripheral reference có sẵn hoặc retrieve từ UUID đã lưu.
    private func reconnectDirectly() {
        // Delay ngắn để iOS xử lý xong disconnect trước khi connect lại
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            
            // Cách 1: Đã có peripheral reference → connect thẳng
            if let p = self.peripheral {
                self.log(.info, " → Connect trực tiếp (có peripheral reference)")
                self.centralManager.connect(p, options: nil)
                return
            }
            
            // Cách 2: Reference mất → retrieve từ UUID cache
            if let savedID = UserDefaults.standard.string(forKey: "lastPeripheralUUID"),
               let uuid = UUID(uuidString: savedID) {
                let known = self.centralManager.retrievePeripherals(withIdentifiers: [uuid])
                if let p = known.first {
                    self.log(.info, " → Connect qua retrievePeripherals (UUID cache)")
                    self.peripheral = p
                    p.delegate = self
                    self.centralManager.connect(p, options: nil)
                    return
                }
            }
            
            // Cách 3: Fallback cuối — scan (trường hợp hiếm)
            self.log(.warning, " → Không tìm được peripheral, fallback sang scan...")
            self.startScan()
        }
    }
    
    // MARK: - GATT Read/Write Helpers
    
    private func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) async throws {
        guard let peripheral = peripheral, peripheral.state == .connected else { throw BLEError.notConnected }
        
        let hexData = data.map { String(format: "%02x", $0) }.joined()
        let charPrefix = characteristic.uuid.uuidString.prefix(8)
        log(.ble, "[TX] WRITE (\(type == .withResponse ? "REQ" : "CMD")) \(charPrefix) (\(data.count) bytes)")
        
        if type == .withResponse {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                bleQueue.async {
                    self.pendingWriteCallbacks[characteristic.uuid] = continuation
                    peripheral.writeValue(data, for: characteristic, type: type)
                }
                
                // Timeout after 20 seconds to allow for iOS pairing UI and slow SMP handshakes
                DispatchQueue.global().asyncAfter(deadline: .now() + 20.0) { [weak self] in
                    if let cont = self?.pendingWriteCallbacks.removeValue(forKey: characteristic.uuid) {
                        self?.log(.error, "[RX] TIMEOUT \(charPrefix)")
                        cont.resume(throwing: BLEError.timeout)
                    }
                }
            }
            log(.ble, "[RX] ACK \(charPrefix)")
        } else {
            peripheral.writeValue(data, for: characteristic, type: type)
        }
    }
    
    private func readValue(for characteristic: CBCharacteristic, timeout: TimeInterval = 20.0) async throws -> Data {
        guard let peripheral = peripheral, peripheral.state == .connected else { throw BLEError.notConnected }
        let charPrefix = characteristic.uuid.uuidString.prefix(8)
        log(.ble, "[TX] READ REQ \(charPrefix)")
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            bleQueue.async {
                self.pendingReadCallbacks[characteristic.uuid] = continuation
                peripheral.readValue(for: characteristic)
            }
            
            // Timeout after specified interval
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                if let cont = self?.pendingReadCallbacks.removeValue(forKey: characteristic.uuid) {
                    self?.log(.error, "[RX] TIMEOUT READ \(charPrefix)")
                    cont.resume(throwing: BLEError.timeout)
                }
            }
        }
    }
    
    // MARK: - Notifications
    
    func sendLocalNotification(title: String, body: String) {
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
        #if DEBUG
        print("[\(level.rawValue)] \(message)")
        #endif
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
                // Try to reconnect to known peripheral
                self.tryReconnectKnown()
                
                // Nếu state restoration yêu cầu resume scan → bật grab-key
                if self.shouldResumeScanAfterRestore {
                    self.shouldResumeScanAfterRestore = false
                    self.startBackgroundScan()
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
    
    /// State Restoration — critical for background BLE
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        log(.info, "🔄 State Restoration: iOS đánh thức app — khôi phục phiên BLE")
        
        if let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for p in restoredPeripherals {
                log(.info, "  → Khôi phục peripheral: \(p.name ?? p.identifier.uuidString) (state: \(p.state.rawValue))")
                p.delegate = self
                self.peripheral = p
                
                if p.state == .connected {
                    log(.info, "  → OS giữ kết nối BLE, tiến hành ping để xác nhận session...")
                    DispatchQueue.main.async {
                        self.connectionState = .sessionVerifying
                    }
                    // Re-discover services to rebuild the characteristic map (needed for commands)
                    p.discoverServices(BLEService.allServices)
                } else {
                    // Peripheral đã mất kết nối — cần reconnect khi BT powers on
                    log(.info, "  → Peripheral đã ngắt, sẽ auto-reconnect + grab-key scan khi BT bật")
                    shouldResumeScanAfterRestore = true
                }
            }
        }
        
        // Restore scan state: iOS khôi phục thông tin scan trước khi app bị kill
        if let scanServices = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] {
            log(.info, "  → Khôi phục background scan cho services: \(scanServices)")
            shouldResumeScanAfterRestore = true
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "Unknown"
        let rssiVal = RSSI.intValue
        
        let containedUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasServiceUUID = containedUUIDs.contains(BLEService.scan) || 
                             containedUUIDs.contains(BLEService.altScan) ||
                             containedUUIDs.contains(BLEService.auth)
        
        // Check if this is our Dat Bike
        let isDatBike = name.contains(BLEProtocol.deviceNamePrefix) ||
                        name.hasPrefix(BLEProtocol.deviceNameAltPrefix) ||
                        hasServiceUUID
                        
        guard isDatBike else { return }
        
        // Just for debugging, log Dat Bike info
        log(.ble, " [\(name)] RSSI: \(rssiVal) dBm | AdvData: \(advertisementData.keys.joined(separator: ", "))")
        if !containedUUIDs.isEmpty {
            log(.ble, "   → UUIDs: \(containedUUIDs.map { $0.uuidString }.joined(separator: ", "))")
        }
        
        // Auto-connect ONLY if this is our saved bike
        let savedUUID = UserDefaults.standard.string(forKey: "lastPeripheralUUID")
        if peripheral.identifier.uuidString == savedUUID {
            log(.success, " Tự động kết nối lại xe đã lưu: \(name)!")
            connect(to: peripheral)
        } else if pendingBondRecovery && isDatBike {
            // Bond recovery: xe đã xóa bond cũ → kết nối như thiết bị mới (PIN pairing flow)
            // KHÔNG SET false ở đây để didFailToConnect còn biết mà ngừng loop nếu iOS bond quá lỳ
            log(.info, " Bond recovery: kết nối \(name) như thiết bị mới (sẽ dùng PIN + NFC)...")
            connect(to: peripheral)
        } else {
            // Update discovered list
            DispatchQueue.main.async {
                if let index = self.discoveredBikes.firstIndex(where: { $0.id == peripheral.identifier.uuidString }) {
                    self.discoveredBikes[index].rssi = rssiVal
                } else {
                    self.discoveredBikes.append(DiscoveredBike(peripheral: peripheral, name: name, rssi: rssiVal))
                }
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log(.success, " Đã kết nối BLE tới \(peripheral.name ?? "xe")")
        DispatchQueue.main.async { self.connectionState = .connecting }
        
        // Discover all services
        peripheral.discoverServices(BLEService.allServices)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let errMsg = error?.localizedDescription ?? "Khong ro loi"
        log(.error, " Ket noi that bai: \(errMsg)")
        
        // CBErrorPeerRemovedPairingInformation (code 14):
        // Bonding keys lệch giữa iOS và xe. Xe đã xoá LTK.
        if let cbError = error as? CBError, cbError.code == .peerRemovedPairingInformation {
            
            // Nếu đang trong bond recovery mode mà connect mới VẪN fail → iOS system bond còn stale
            if pendingBondRecovery {
                pendingBondRecovery = false
                pairingRetryCount = 0
                log(.error, " Bond recovery thất bại — iOS vẫn giữ bond cũ. Cần xóa thủ công.")
                UserDefaults.standard.removeObject(forKey: "lastPeripheralUUID")
                self.peripheral = nil
                discoveredCharacteristics.removeAll()
                DispatchQueue.main.async {
                    self.connectionState = .error("Xe đã xóa kết nối BLE. Hãy vào Cài đặt iPhone ➔ Bluetooth ➔ chọn xe ➔ Quên thiết bị này. Sau đó quay lại app để ghép đôi lại.")
                    self.isAuthenticated = false
                }
                sendLocalNotification(title: "Cần xóa kết nối cũ", body: "Vào Cài đặt ➔ Bluetooth ➔ Quên thiết bị. Sau đó mở app + quẹt NFC.")
                return
            }
            
            // Skip retry — mỗi lần retry với bond cũ chỉ làm xe reject thêm.
            // Vào thẳng bond recovery: xóa saved UUID → scan → connect as new device → NFC pairing.
            log(.error, " Bonding mất (code 14). Skip retry → bond recovery ngay.")
            pairingRetryCount = 0
            pendingBondRecovery = true
            UserDefaults.standard.removeObject(forKey: "lastPeripheralUUID")
            self.peripheral = nil
            discoveredCharacteristics.removeAll()
            
            DispatchQueue.main.async {
                self.connectionState = .connecting
                self.isAuthenticated = false
            }
            
            sendLocalNotification(title: "Đang ghép đôi lại", body: "Xe yêu cầu xác thực lại — chuẩn bị thẻ NFC.")
            
            // Scan lại → didDiscover sẽ detect pendingBondRecovery → auto-connect as new device
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.startScan()
            }
            return
        }
        
        DispatchQueue.main.async {
            self.connectionState = .error(errMsg)
        }
        // Auto retry for other errors
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.startScan()
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log(.warning, " Ngắt kết nối: \(error?.localizedDescription ?? "chủ động")")
        
        // Cancel pending read/write continuations to prevent zombie operations
        for (_, continuation) in pendingWriteCallbacks {
            continuation.resume(throwing: BLEError.notConnected)
        }
        pendingWriteCallbacks.removeAll()
        for (_, continuation) in pendingReadCallbacks {
            continuation.resume(throwing: BLEError.notConnected)
        }
        pendingReadCallbacks.removeAll()
        
        
        // CBError code 14: Peer Removed Pairing Information.
        // Một số iOS version fire didDisconnect thay vì didFailToConnect cho error 14.
        // Dùng cùng retry + bond recovery flow.
        if let cbError = error as? CBError, cbError.code.rawValue == 14 {
            log(.error, " [didDisconnect] Xe đã xoá Bonding Key (Code 14)")
            rssiTimer?.invalidate()
            rssiTimer = nil
            
            if pendingBondRecovery {
                // Recovery mode connect cũng bị disconnect error 14 → iOS bond stale
                pendingBondRecovery = false
                pairingRetryCount = 0
                log(.error, " Bond recovery thất bại → cần xóa thủ công trong Cài đặt.")
                UserDefaults.standard.removeObject(forKey: "lastPeripheralUUID")
                self.peripheral = nil
                DispatchQueue.main.async {
                    self.connectionState = .error("Xe đã xóa kết nối BLE. Hãy vào Cài đặt iPhone ➔ Bluetooth ➔ chọn xe ➔ Quên thiết bị này. Sau đó quay lại app để ghép đôi lại.")
                    self.isAuthenticated = false
                    self.discoveredCharacteristics.removeAll()
                }
                sendLocalNotification(title: "Cần xóa kết nối cũ", body: "Vào Cài đặt ➔ Bluetooth ➔ Quên thiết bị. Sau đó mở app + quẹt NFC.")
                return
            }
            
            // Skip retry — vào thẳng bond recovery (giống didFailToConnect)
            log(.error, " [didDisconnect] Bonding mất (code 14). Skip retry → bond recovery ngay.")
            pairingRetryCount = 0
            pendingBondRecovery = true
            UserDefaults.standard.removeObject(forKey: "lastPeripheralUUID")
            self.peripheral = nil
            discoveredCharacteristics.removeAll()
            
            DispatchQueue.main.async {
                self.connectionState = .connecting
                self.isAuthenticated = false
            }
            
            sendLocalNotification(title: "Đang ghép đôi lại", body: "Xe yêu cầu xác thực lại — chuẩn bị thẻ NFC.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.startScan()
            }
            return
        }
        
        DispatchQueue.main.async {
            self.connectionState = .disconnected
            self.isAuthenticated = false
            self.discoveredCharacteristics.removeAll()
        }
        
        rssiTimer?.invalidate()
        rssiTimer = nil
        
        // Only notify and auto-reconnect if this was an unexpected drop (not user-initiated)
        if error != nil {
            sendLocalNotification(title: "Dat Bike", body: "Đã mất kết nối với xe")
        }
        
        // If user has a saved bike, try to reconnect automatically
        let hasSavedBike = UserDefaults.standard.string(forKey: "lastPeripheralUUID") != nil
        if hasSavedBike {
            // Pending connection: iOS duy trì ngay cả khi app bị kill → wake on reconnect
            scheduleReconnect()
            // Grab-key background scan: fallback nếu pending connection hết hạn
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                if self.connectionState == .disconnected {
                    self.startBackgroundScan()
                }
            }
        }
    }
    
    // MARK: - Known Device Reconnect
    
    private func tryReconnectKnown() {
        let savedID = UserDefaults.standard.string(forKey: "lastPeripheralUUID")
        guard savedID != nil else {
            // No saved bike — wait for user to scan manually
            return
        }
        
        // 1. Check if this peripheral is already physically connected to iOS (fast path)
        let connected = centralManager.retrieveConnectedPeripherals(withServices: [BLEService.auth, BLEService.main, BLEService.scan, BLEService.altScan])
        if let p = connected.first(where: { $0.identifier.uuidString == savedID }) {
            log(.info, " Phát hiện xe đang kết nối (từ iOS cache): \(p.name ?? "unknown") — sẽ ping session tránh lỗi auth đè.")
            connect(to: p)
            return
        } else if let p = connected.first {
            // Có thiết bị BLE đang kết nối nhưng không phải xe đã lưu → vẫn thử kết nối bình thường
            log(.info, " Phát hiện thiết bị BLE khác đang kết nối: \(p.name ?? "unknown")")
            connect(to: p)
            return
        }
        
        // 2. Try retrieve from cache (works if app was recently opened)
        if let savedID = savedID, let uuid = UUID(uuidString: savedID) {
            let known = centralManager.retrievePeripherals(withIdentifiers: [uuid])
            if let p = known.first {
                log(.info, " Tìm thấy xe trong cache (\(p.name ?? "unknown")). Queue lệnh connect...")
                connect(to: p)
                return
            }
        }
        
        // 3. Fallback: Grab-key background scan — didDiscover sẽ auto-connect tới saved UUID
        // Dùng startBackgroundScan() thay vì startScan() để không ảnh hưởng UI
        // và hoạt động đúng khi app bị iOS đánh thức ở background
        log(.info, "🔍 Không tìm thấy xe trong cache, bật grab-key scan...")
        startBackgroundScan()
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
            guard !isAuthenticated && !isAuthenticating else { return }
            
            isAuthenticating = true
            
            Task {
                // ── BƯỚC 1: PING GHOST CONNECTION ──
                // Thay vì luôn chạy auth, kiểm tra xe có đang active session không bằng cách đọc 1 characteristic cần mã hóa
                let savedUUID = UserDefaults.standard.string(forKey: "lastPeripheralUUID")
                let isKnownDevice = (savedUUID == peripheral.identifier.uuidString)
                
                if isKnownDevice {
                    DispatchQueue.main.async { self.connectionState = .sessionVerifying }
                    self.log(.ble, "🔍 [PING] Kiểm tra session cũ (Ghost Connection)...")
                    
                    if let pingChar = self.discoveredCharacteristics[BLECharacteristic.vehicleStatus] {
                        do {
                            // Cần timeout ngắn gọn (2s) để chẩn đoán trạng thái
                            _ = try await self.readValue(for: pingChar, timeout: 2.0)
                            
                            // Nếu thành công -> Session vẫn sống ngoẻo!
                            self.log(.success, "✅ [PING OK] Trạng thái phiên cũ hợp lệ! Bỏ qua xác thực.")
                            
                            // THỬ NGHIỆM TẮT BOND: Không khôi phục CCCD
                            /*
                            if let scChar = self.discoveredCharacteristics[BLECharacteristic.serviceChanged] {
                                if !scChar.isNotifying {
                                    self.log(.ble, " CCCD (serviceChanged) bị mất auth, tiến hành gửi lại lệnh Notify (0x0100)...")
                                    peripheral.setNotifyValue(true, for: scChar)
                                } else {
                                    self.log(.success, " CCCD (serviceChanged) báo cáo đã được subscribed.")
                                }
                            }
                            */
                            
                            DispatchQueue.main.async {
                                self.isAuthenticated = true
                                self.connectionState = .ready
                            }
                            _ = try? await self.readLockStatus()
                            await self.readDeviceInfo()
                            self.startRSSIMonitoring()
                            self.isAuthenticating = false
                            return
                        } catch {
                            self.log(.warning, "⚠️ [PING FAIL] Phiên bị từ chối hoặc timeout. Máy sẽ chạy lại quy trình xác thực. Lỗi: \(error.localizedDescription)")
                        }
                    }
                }
                
                // ── BƯỚC 2: AUTHENTICATE BÌNH THƯỜNG ──
                self.log(.success, " Bắt đầu luồng xác thực (SHA / New Card)...")
                DispatchQueue.main.async { self.connectionState = .authenticating }
                do {
                    // Start auth sequence
                    try await self.authenticate()
                } catch {
                    self.log(.error, "Xác thực thất bại: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.connectionState = .error("Xác thực thất bại")
                    }
                }
                self.isAuthenticating = false
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
        let hexData = data.map { String(format: "%02x", $0) }.joined()
        
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
        DispatchQueue.main.async { self.rssi = rssiVal }
        
        // Auto-unlock logic
        if autoUnlockEnabled && lockStatus.isLocked && rssiVal > BLEProtocol.rssiThreshold {
            log(.info, " Ở gần xe (RSSI: \(rssiVal) > \(BLEProtocol.rssiThreshold)). Auto-unlock...")
            sendLocalNotification(title: "Auto Unlock", body: "Phát hiện bạn đang ở gần xe. Đang mở khóa...")
            Task {
                try? await unlock()
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

private enum KeychainHelper {
    private static let serviceName = "com.jedix.datbikesmartkey"
    
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
