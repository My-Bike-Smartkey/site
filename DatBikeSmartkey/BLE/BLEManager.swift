// BLEManager.swift — Core Bluetooth Manager with Background BLE Optimization
// Handles scanning, connection, state restoration, and auto-reconnect

@preconcurrency import CoreBluetooth
import Combine
import UserNotifications
import CryptoKit

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
    
    // Auth sequence state
    private var authContinuation: CheckedContinuation<Bool, Never>?
    private var pendingWriteCallbacks: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var pendingReadCallbacks: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    
    /// True khi session BLE vẫn còn sống (state restoration hoặc retrieveConnectedPeripherals).
    /// Ngăn auth sequence chạy lại trên phiên đang hoạt động, tránh bike xóa bonding.
    private var isLiveSessionRestore: Bool = false
    
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
        log(.ble, "Bắt đầu quét BLE (service: FCF1)...")
        
        // DEBUG: Scan WITHOUT service filter to see all devices
        centralManager.scanForPeripherals(
            withServices: nil,
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
        
        if let peripheral = peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        
        discoveredCharacteristics.removeAll()
        DispatchQueue.main.async {
            self.connectionState = .disconnected
            self.isAuthenticated = false
            self.lockStatus = .unknown(Data())
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
        DispatchQueue.main.async { self.lockStatus = status }
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
        let pin = UserDefaults.standard.string(forKey: "authPIN") ?? BLEProtocol.authPIN
        guard let peripheral = peripheral else { throw BLEError.notConnected }
        guard let authChar = discoveredCharacteristics[BLECharacteristic.authChallenge] else {
            throw BLEError.characteristicNotFound("authChallenge")
        }
        
        DispatchQueue.main.async { self.connectionState = .authenticating }
        let pinData = Data(pin.utf8)
        let savedUUID = UserDefaults.standard.string(forKey: "lastPeripheralUUID")
        let isKnownDevice = (savedUUID == peripheral.identifier.uuidString)
        
        if isKnownDevice {
            // ── RECONNECT FLOW (SHA-256) ──
            log(.ble, " Tái kết nối tự động (SHA-256 Mode). Đọc Challenge...")
            
            let challengeData = try await readValue(for: authChar)
            guard challengeData.count >= 4 else {
                log(.error, " Lỗi: Challenge Data quá ngắn (\(challengeData.count) bytes)")
                throw BLEError.authFailed("Challenge data too short")
            }
            
            // 1. Chuyển thành UInt32 Little Endian
            let challengeUInt32 = challengeData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            
            // 2. Dịch phải (Logical Right Shift) 1 bit
            let shifted = challengeUInt32 >> 1
            
            // 3. Ghép chuỗi Số Nguyên + PIN
            let mixStr = "\(shifted)\(pin)"
            
            // 4. Băm SHA-256 và chuyển kết quả thành Hex String
            let hashData = Data(mixStr.utf8)
            let hashed = SHA256.hash(data: hashData)
            let hashHexStr = hashed.compactMap { String(format: "%02x", $0) }.joined()
            
            let challengeHex = challengeData.map { String(format: "%02x", $0) }.joined()
            log(.ble, " [DEBUG AUTH]")
            log(.ble, " ├─ PIN gốc: \(pin)")
            log(.ble, " ├─ Challenge (Hex): \(challengeHex) -> UInt32: \(challengeUInt32)")
            log(.ble, " ├─ Toán tử >> 1 : \(shifted)")
            log(.ble, " ├─ Chuỗi đem băm: '\(mixStr)'")
            log(.ble, " └─ Kết quả SHA-256: \(hashHexStr)")
            
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled {
                    log(.warning, " Phản hồi đang chậm, có thể kết nối đang bị cản trở bởi HĐH mã hóa...")
                }
            }
            
            try await writeValue(Data(hashHexStr.utf8), for: authChar, type: .withResponse)
            watchdog.cancel()
            log(.success, " SHA-256 write ACK received. Auth complete.")
            
        } else {
            // ── ADD NEW CARD FLOW (PLAINTEXT PIN) ──
            log(.ble, " Mã hóa thiết bị mới (Pairing Mode). Gửi PIN thô...")
            
            // Watchdog: Nếu thiết bị MỚI mà block > 0.6s tức là iOS đang popup Pairing
            let pairingWatchdog = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if !Task.isCancelled {
                    DispatchQueue.main.async { self.connectionState = .pairingRequired }
                    log(.warning, "Xe yêu cầu ghép đôi bảo mật (mất quá lâu để phản hồi)...")
                    log(.info, " Hãy quẹt thẻ NFC vào thân xe và bấm Pair (Ghép đôi)")
                }
            }
            
            do {
                try await writeValue(pinData, for: authChar, type: .withResponse)
                pairingWatchdog.cancel()
                log(.success, "PIN được chấp nhận ngay lập tức!")
            } catch {
                pairingWatchdog.cancel()
                if self.connectionState != .pairingRequired {
                    DispatchQueue.main.async { self.connectionState = .pairingRequired }
                    log(.warning, "Xe yêu cầu ghép đôi bảo mật (Caught Error)...")
                    log(.info, " Hãy quẹt thẻ NFC vào thân xe và xác nhận ghép đôi")
                }
                sendLocalNotification(title: "Ghép đôi Dat Bike", body: "Hãy quẹt thẻ NFC vào xe để hoàn tất xác thực")
                
                // Chờ người dùng quẹt thẻ (loop tối đa 20 giây)
                var isPaired = false
                for i in 1...20 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    do {
                        log(.ble, "⏳ Đang đợi ghép đôi... (\(i)/20)")
                        try await writeValue(pinData, for: authChar, type: .withResponse)
                        isPaired = true
                        log(.success, " Ghép đôi hoàn tất!")
                        DispatchQueue.main.async { self.connectionState = .authenticating }
                        break
                    } catch {}
                }
                
                if !isPaired {
                    log(.error, " Ghép đôi thất bại hoặc quá hạn 20s.")
                    throw BLEError.authFailed("Hết thời gian chờ quẹt NFC")
                }
            }
            
            // Step 2 & 3: PIN confirm như btsnoop (Chỉ áp dụng khi Pairing)
            log(.ble, " Step 2: PIN xác nhận lần 1...")
            try? await writeValue(pinData, for: authChar, type: .withResponse)
            try await Task.sleep(nanoseconds: UInt64(BLEProtocol.authConfirmDelay * 1_000_000_000))
            
            log(.ble, " Step 3: PIN xác nhận lần 2...")
            try? await writeValue(pinData, for: authChar, type: .withResponse)
            try await Task.sleep(nanoseconds: UInt64(BLEProtocol.authSessionDelay * 1_000_000_000))
        }
        
        // ── Step 5: Write session token (BEFORE CCCD — matches btsnoop order)
        let sessionToken = String(Int.random(in: 10000...99999))
        log(.ble, " Step 5: Session Token: \(sessionToken)")
        if let sessChar = discoveredCharacteristics[BLECharacteristic.sessionToken] {
            try? await writeValue(Data(sessionToken.utf8), for: sessChar, type: .withResponse)
        }
        
        // ── Step 6: Register proximity token (BEFORE CCCD — matches btsnoop order)
        let token = proximityToken
        log(.ble, " Step 6: Proximity Token: \(String(token.prefix(8)))...")
        if let autoChar = discoveredCharacteristics[BLECharacteristic.autoUnlock] {
            try? await writeValue(Data(token.utf8), for: autoChar, type: .withResponse)
        }
        
        // ── Step 7: Subscribe to serviceChanged CCCD (triggers Bluetooth icon on vehicle dashboard)
        // NOTE: Original btsnoop only subscribes serviceChanged. smartkeyEcho/lockState are polled, NOT notified.
        log(.ble, " Step 7: Dang ky CCCD (serviceChanged) de xe hien icon Bluetooth...")
        if let scChar = discoveredCharacteristics[BLECharacteristic.serviceChanged] {
            peripheral.setNotifyValue(true, for: scChar)
            try await Task.sleep(nanoseconds: 200_000_000) // Wait for CCCD Write Response from vehicle
            log(.ble, " Step 7: Da gui CCCD Write -  cho xe phan hoi...")
        }
        
        // ── Done
        // Save UUID ONLY NOW -- after full auth success -- so next connect uses SHA flow correctly
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
        
        // Send notification
        sendLocalNotification(title: "Dat Bike Connected", body: "Đã kết nối thành công với xe \(bikeInfo.name)")
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
    
    // MARK: - GATT Read/Write Helpers
    
    private func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) async throws {
        guard let peripheral = peripheral else { throw BLEError.notConnected }
        
        let hexData = data.map { String(format: "%02x", $0) }.joined()
        let charPrefix = characteristic.uuid.uuidString.prefix(8)
        log(.ble, "[TX] WRITE (\(type == .withResponse ? "REQ" : "CMD")) \(charPrefix): \(hexData)")
        
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
    
    private func readValue(for characteristic: CBCharacteristic) async throws -> Data {
        guard let peripheral = peripheral else { throw BLEError.notConnected }
        let charPrefix = characteristic.uuid.uuidString.prefix(8)
        log(.ble, "[TX] READ REQ \(charPrefix)")
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            bleQueue.async {
                self.pendingReadCallbacks[characteristic.uuid] = continuation
                peripheral.readValue(for: characteristic)
            }
            
            // Timeout after 20 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 20.0) { [weak self] in
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
            // Keep last 200 entries
            if self.logs.count > 200 {
                self.logs.removeFirst(self.logs.count - 200)
            }
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
        log(.info, " State Restoration: khôi phục phiên BLE sau khi app bị kill")
        
        if let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for p in restoredPeripherals {
                log(.info, "  → Khôi phục peripheral: \(p.name ?? p.identifier.uuidString)")
                p.delegate = self
                self.peripheral = p
                
                if p.state == .connected {
                    // Session is still alive in iOS background — vehicle still shows BT icon.
                    // Restore auth state directly. Do NOT re-run authenticate():
                    // Sending unexpected SHA to an active session causes vehicle to wipe bonding.
                    //
                    // QUAN TRỌNG: Set isLiveSessionRestore TRƯỚC discoverServices.
                    // Nếu dùng DispatchQueue.main.async thì isAuthenticated chưa được set
                    // khi didDiscoverCharacteristicsFor chạy → auth bị trigger → bike xóa bond.
                    self.isLiveSessionRestore = true
                    self.isAuthenticated = true  // Set đồng bộ để didDiscover thấy ngay
                    DispatchQueue.main.async {
                        self.connectionState = .ready
                        self.isAuthenticated = true  // Cập nhật @Published cho SwiftUI
                    }
                    // Re-discover services to rebuild the characteristic map (needed for commands)
                    p.discoverServices(BLEService.allServices)
                }
            }
        }
        
        // Restore scan state if we were scanning
        if let scanServices = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] {
            log(.info, "  → Khôi phục scan cho services: \(scanServices)")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "Unknown"
        let rssiVal = RSSI.intValue
        
        let hasServiceUUID = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(BLEService.scan) == true
        
        // Check if this is our Dat Bike
        let isDatBike = name.contains(BLEProtocol.deviceNamePrefix) ||
                        name.hasPrefix(BLEProtocol.deviceNameAltPrefix) ||
                        hasServiceUUID
                        
        // Just for debugging, log devices with strong signal or Dat Bike name
        if isDatBike || rssiVal > -70 {
            log(.ble, " [\(name)] RSSI: \(rssiVal) dBm | AdvData: \(advertisementData.keys.joined(separator: ", "))")
            if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
                log(.ble, "   → UUIDs: \(uuids.map { $0.uuidString }.joined(separator: ", "))")
            }
        }
        
        guard isDatBike else { return }
        
        // Auto-connect ONLY if this is our saved bike
        let savedUUID = UserDefaults.standard.string(forKey: "lastPeripheralUUID")
        if peripheral.identifier.uuidString == savedUUID {
            log(.success, " Tự động kết nối lại xe đã lưu: \(name)!")
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
        // Xe da xoa bonding info -- phai ghep doi lai tu dau bang NFC
        if let cbError = error as? CBError, cbError.code == .peerRemovedPairingInformation {
            log(.warning, " Xe da xoa thong tin ghep doi!")
            log(.warning, " Xoa UUID cu, chuyen sang luong ghep doi moi (NFC required)...")
            UserDefaults.standard.removeObject(forKey: "lastPeripheralUUID")
            DispatchQueue.main.async {
                self.connectionState = .pairingRequired
                self.isAuthenticated = false
            }
            sendLocalNotification(title: "Dat Bike: Can ghep doi lai",
                                  body: "Xe da xoa ket noi. Hay mo app va ghep doi lai bang the NFC.")
            return // Do NOT auto-retry
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
        
        // Reset live session flag nếu kết nối bị đứt
        isLiveSessionRestore = false
        
        // CBError code 14: Peer Removed Pairing Information.
        // Bike đã xóa bonding — phải ghép đôi lại bằng NFC.
        // QUAN TRỌNG: handle ở CẢ didDisconnect lẫn didFailToConnect vì tùy iOS version,
        // lỗi này có thể đến qua một trong hai callback.
        if let cbError = error as? CBError, cbError.code.rawValue == 14 {
            log(.warning, " [didDisconnect] Xe đã xóa thông tin ghép đôi (code 14)!")
            log(.warning, " Xóa UUID cũ, chuyển sang luồng ghép đôi mới (NFC required)...")
            UserDefaults.standard.removeObject(forKey: "lastPeripheralUUID")
            DispatchQueue.main.async {
                self.connectionState = .pairingRequired
                self.isAuthenticated = false
                self.discoveredCharacteristics.removeAll()
            }
            rssiTimer?.invalidate()
            rssiTimer = nil
            sendLocalNotification(title: "Dat Bike: Cần ghép đôi lại",
                                  body: "Xe đã xóa kết nối. Hãy mở app và ghép đôi lại bằng thẻ NFC.")
            return // Không auto-retry
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
            // First register a pending connection (works in background)
            scheduleReconnect()
            // Also start scan as fallback for foreground reconnect
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                if self.connectionState == .disconnected {
                    self.startScan()
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
        let connected = centralManager.retrieveConnectedPeripherals(withServices: [BLEService.scan, BLEService.altScan])
        if let p = connected.first(where: { $0.identifier.uuidString == savedID }) {
            // Đây là xe đã lưu, đang kết nối ở tầng iOS → BLE session còn sống.
            // Đánh dấu để didDiscoverCharacteristics bỏ qua auth, tránh bike xóa bonding.
            isLiveSessionRestore = true
            log(.info, " Phát hiện xe đang kết nối (từ iOS cache): \(p.name ?? "unknown") — sẽ khôi phục session, bỏ qua auth")
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
            if let p = known.first, p.state == .connected {
                log(.info, " Tìm thấy xe đã kết nối (from cache): \(p.name ?? savedID)")
                connect(to: p)
                return
            }
        }
        
        // 3. Fallback: Start scan — didDiscover will auto-connect to the saved UUID
        log(.info, " Không tìm thấy xe trong cache, bắt đầu quét lại...")
        startScan()
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
            log(.success, " Tat ca characteristics san sang. Bat dau xac thuc...")
            
            // NOTE: Do NOT save UUID here! It must be saved only AFTER successful authentication.
            // Saving early causes SHA flow to be used on very first connect (before NFC pairing),
            // causing auth failure, which causes vehicle to wipe bonding => Peer removed pairing error.
            
            // Start auth sequence
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
                log(.ble, "[RX] READ RESP \(charPrefix): \(hexData)")
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
        
        log(.ble, "[RX] NOTIFY \(charPrefix): \(hexData)")
        if characteristic.uuid == BLECharacteristic.smartkeyEcho ||
           characteristic.uuid == BLECharacteristic.statusFlags {
            let status = LockStatus(from: data)
            DispatchQueue.main.async { self.lockStatus = status }
            log(.info, " Cập nhật trạng thái xe: \(status.description)")
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
