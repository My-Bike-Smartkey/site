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
    @Published var isAuthenticated = false
    @Published var hasAuthorizedAccessory = false
    @Published var pickerDismissed = false
    
    // MARK: - Private Properties
    
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var discoveredCharacteristics: [CBUUID: CBCharacteristic] = [:]
    
    private let bleQueue = DispatchQueue(label: "com.jedix.datbikesmartkey.ble", qos: .userInitiated)
    private var rssiTimer: Timer?
    private var isAuthenticating: Bool = false
    private var pairingRetryCount: Int = 0
    private let maxPairingRetries: Int = 3
    
    /// Ngăn auto-unlock lặp lại nhiều lần nếu user tự tay tắt xe lúc đang đứng gần
    private var hasTriggeredAutoUnlockSession = false
    
    /// Bond recovery mode: sau khi retry error 14 thất bại, scan lại và connect như thiết bị mới
    private var pendingBondRecovery = false
    
    // Auth sequence state
    private var authContinuation: CheckedContinuation<Bool, Never>?
    private var pendingWriteCallbacks: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var pendingReadCallbacks: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    
    /// True khi session BLE vẫn còn sống (retrieveConnectedPeripherals).
    /// Ngăn auth sequence chạy lại trên phiên đang hoạt động, tránh bike xóa bonding.
    private var isLiveSessionRestore: Bool = false
    
    /// Flag set by willRestoreState: cần auto-connect khi BT powers on
    private var shouldReconnectAfterRestore = false
    
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
        super.init()
        
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
            CBCentralManagerOptionRestoreIdentifierKey: "com.jedix.datbikesmartkey.central"
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
                log(.info, "🔗 Xe đã authorize: \(existing.displayName ?? "Dat Bike")")
                // ONLY init CBCentralManager when we have an authorized accessory
                // Creating it without authorized accessories = "global permissions" conflict
                initCentralManagerIfNeeded()
                if centralManager?.state == .poweredOn {
                    connectToAccessory(existing)
                }
            } else {
                DispatchQueue.main.async { self.hasAuthorizedAccessory = false }
                log(.info, "📱 Chưa có xe nào — cần showPicker()")
                // ⚠️ Do NOT init CBCentralManager here — no authorized accessory yet
            }
            
        case .accessoryAdded:
            if let accessory = event.accessory {
                currentAccessory = accessory
                DispatchQueue.main.async { self.hasAuthorizedAccessory = true }
                log(.success, "🏍️ Xe mới được authorize: \(accessory.displayName ?? "Dat Bike")")
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
                log(.info, "🔄 Accessory updated: \(accessory.displayName ?? "")")
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
            DispatchQueue.main.async { self.connectionState = .disconnected }
        }
    }
    
    func connect(to peripheral: CBPeripheral) {
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
        let isKnownDevice = (savedUUID == peripheral.identifier.uuidString)
        
        if isKnownDevice {
            // ── RECONNECT FLOW (SHA-256) with Counter Verification ──
            log(.ble, " Tái kết nối tự động (SHA-256 Mode). Đọc Challenge...")
            
            let currentChallengeData = try await readValue(for: authChar)
            guard currentChallengeData.count >= 4 else {
                log(.error, " Lỗi: Challenge Data quá ngắn (\(currentChallengeData.count) bytes)")
                throw BLEError.authFailed("Challenge data too short")
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
            
            log(.ble, " [AUTH] computing SHA-256 response...")
            
            // 5. Ghi hash — CHỈ 1 LẦN, không retry để tránh firmware wipe bonding
            try await writeValue(Data(hashHexStr.utf8), for: authChar, type: .withResponse)
            
            // 6. Đọc lại counter để xác nhận
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms cho firmware xử lý
            let verifyData = try await readValue(for: authChar)
            if verifyData.count >= 4 {
                let newCounter = verifyData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                if newCounter > currentCounter {
                    log(.success, " Counter verified: \(currentCounter) → \(newCounter) (+\(newCounter - currentCounter)). Auth OK!")
                } else {
                    log(.warning, " Counter không tăng: expected >\(currentCounter), got \(newCounter). Auth có thể thất bại.")
                    throw BLEError.authFailed("Counter verification failed")
                }
            } else {
                // Counter verify thất bại nhưng write đã ACK → coi như OK (giống bản đầu)
                log(.warning, " Counter verify: data ngắn (\(verifyData.count) bytes), tiếp tục...")
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
        
        // Grab-key: tự động mở khóa khi app được iOS đánh thức ở background
        if autoUnlockEnabled && lockStatus.isLocked && !hasTriggeredAutoUnlockSession {
            log(.info, "🔓 Grab-key auto-unlock: xe đang khóa, tự động mở...")
            do {
                try await turnOff() // NOTE: turnOff actually sends 0x31 (Turn On) logic
                hasTriggeredAutoUnlockSession = true
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
                // ASK: auto-connect to authorized accessory
                if let accessory = self.currentAccessory {
                    self.connectToAccessory(accessory)
                } else {
                    self.tryReconnectKnown()
                }
                
                // State Restoration: peripheral bị ngắt → reconnect khi BT bật
                if self.shouldReconnectAfterRestore {
                    self.shouldReconnectAfterRestore = false
                    if let accessory = self.currentAccessory {
                        self.connectToAccessory(accessory)
                    } else {
                        self.scheduleReconnect()
                    }
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
            log(.success, "🔗 Tự động kết nối lại xe đã lưu: \(name)!")
            connect(to: peripheral)
        } else if pendingBondRecovery {
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
            self.connectToAccessory(accessory)
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
        
        // ASK: auto-reconnect via pending connection
        let hasSavedBike = UserDefaults.standard.string(forKey: "lastPeripheralUUID") != nil
        if hasSavedBike || currentAccessory != nil {
            scheduleReconnect()
        }
    }
    
    // MARK: - Known Device Reconnect
    
    private func tryReconnectKnown() {
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
            // Session BLE vẫn còn sống → tuyệt đối không gửi auth lại.
            // Gửi SHA-256 trên phiên đang active sẽ bị bike hiểu là invalid → XÓA BONDING.
            if isLiveSessionRestore {
                isLiveSessionRestore = false
                log(.success, " Characteristics sẵn sàng (live session). Khôi phục trạng thái, bỏ qua auth.")
                DispatchQueue.main.async {
                    self.isAuthenticated = true
                    self.connectionState = .ready
                }
                Task {
                    _ = try? await readLockStatus()
                    await readDeviceInfo()
                    startRSSIMonitoring()
                }
                return
            }
            
            guard !isAuthenticated && !isAuthenticating else { return }
            
            isAuthenticating = true
            log(.success, " Tất cả characteristics sẵn sàng. Bắt đầu xác thực...")
            
            Task {
                do {
                    try await authenticate()
                } catch {
                    log(.error, "Xác thực thất bại: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.connectionState = .error("Xác thực thất bại")
                    }
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
        if autoUnlockEnabled && lockStatus.isLocked && !hasTriggeredAutoUnlockSession && rssiVal > BLEProtocol.rssiThreshold {
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
