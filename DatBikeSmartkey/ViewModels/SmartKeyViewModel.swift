// SmartKeyViewModel.swift — ViewModel bridging BLEManager → SwiftUI

import SwiftUI
import Combine

@MainActor
final class SmartKeyViewModel: ObservableObject {
    
    // MARK: - Published
    
    @Published var connectionState: ConnectionState = .disconnected
    @Published var lockStatus: LockStatus = .unknown(Data())
    @Published var rssi: Int = -100
    @Published var bikeInfo = BikeInfo()
    @Published var logs: [BLELogEntry] = []
    @Published var discoveredBikes: [DiscoveredBike] = []
    @Published var selectedBike: DiscoveredBike? = nil
    @Published var autoUnlockEnabled: Bool = false
    @Published var isAuthenticated = false
    @Published var isDebugModeEnabled: Bool = false {
        didSet { UserDefaults.standard.set(isDebugModeEnabled, forKey: "isDebugModeEnabled") }
    }
    @Published var hasAuthorizedAccessory = false
    @Published var pickerDismissed = false

    @Published var isProcessing = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var isFinding = false

    // Time Sync
    @Published var isSyncingTime = false
    @Published var lastTimeSyncResult: Bool? = nil   // nil = never, true = success, false = error
    @Published var lastTimeSyncDate: Date? = nil

    var lastTimeSyncDescription: String {
        guard let date = lastTimeSyncDate else { return "Chưa đồng bộ thủ công" }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        formatter.dateFormat = "HH:mm:ss dd/MM"
        let success = lastTimeSyncResult == true
        return (success ? "✓ " : "✗ ") + formatter.string(from: date)
    }

    
    // Settings
    @Published var rssiThreshold: Double {
        didSet { UserDefaults.standard.set(rssiThreshold, forKey: "rssiThreshold") }
    }
    @Published var autoConnectEnabled: Bool = true
    @Published var autoConnectRSSIThreshold: Double {
        didSet { BLEManager.shared.autoConnectRSSIThreshold = Int(autoConnectRSSIThreshold) }
    }
    @Published var autoBackgroundReconnectEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(autoBackgroundReconnectEnabled, forKey: "autoBackgroundReconnectEnabled")
            BLEManager.shared.autoBackgroundReconnectEnabled = autoBackgroundReconnectEnabled
        }
    }
    @Published var notificationsEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled")
            BLEManager.shared.notificationsEnabled = notificationsEnabled
        }
    }
    
    // MARK: - Private
    
    private let ble = BLEManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Init
    
    init() {
        self.rssiThreshold = UserDefaults.standard.double(forKey: "rssiThreshold") != 0
            ? UserDefaults.standard.double(forKey: "rssiThreshold")
            : Double(BLEProtocol.rssiThreshold)
        let storedConnRSSI = UserDefaults.standard.object(forKey: "autoConnectRSSIThreshold") as? Int
        self.autoConnectRSSIThreshold = Double(storedConnRSSI ?? -80)
        let storedBgReconnect = UserDefaults.standard.object(forKey: "autoBackgroundReconnectEnabled") as? Bool ?? true
        self.autoBackgroundReconnectEnabled = storedBgReconnect
        BLEManager.shared.autoBackgroundReconnectEnabled = storedBgReconnect
        let storedNotif = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        self.notificationsEnabled = storedNotif
        BLEManager.shared.notificationsEnabled = storedNotif
        self.isDebugModeEnabled = UserDefaults.standard.bool(forKey: "isDebugModeEnabled")
        
        setupBindings()
    }
    
    private func setupBindings() {
        ble.$connectionState
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectionState)
        
        ble.$lockStatus
            .receive(on: DispatchQueue.main)
            .assign(to: &$lockStatus)
        
        ble.$rssi
            .receive(on: DispatchQueue.main)
            .assign(to: &$rssi)
        
        ble.$bikeInfo
            .receive(on: DispatchQueue.main)
            .assign(to: &$bikeInfo)
        
        ble.$logs
            .receive(on: DispatchQueue.main)
            .assign(to: &$logs)
            
        ble.$discoveredBikes
            .receive(on: DispatchQueue.main)
            .assign(to: &$discoveredBikes)
        
        ble.$autoUnlockEnabled
            .receive(on: DispatchQueue.main)
            .assign(to: &$autoUnlockEnabled)
        
        ble.$autoConnectEnabled
            .receive(on: DispatchQueue.main)
            .assign(to: &$autoConnectEnabled)
        
        ble.$autoConnectRSSIThreshold
            .receive(on: DispatchQueue.main)
            .map { Double($0) }
            .assign(to: &$autoConnectRSSIThreshold)
        
        ble.$isAuthenticated
            .receive(on: DispatchQueue.main)
            .assign(to: &$isAuthenticated)
        
        ble.$hasAuthorizedAccessory
            .receive(on: DispatchQueue.main)
            .assign(to: &$hasAuthorizedAccessory)
        
        ble.$pickerDismissed
            .receive(on: DispatchQueue.main)
            .assign(to: &$pickerDismissed)
    }
    
    // MARK: - Actions
    
    func startScan() {
        selectedBike = nil
        ble.startScan()
    }
    
    func showAccessoryPicker() {
        ble.showPicker()
    }
    
    func selectBike(_ bike: DiscoveredBike) {
        selectedBike = bike
        ble.stopScan()
    }
    
    func connectSelectedBike() {
        if let bike = selectedBike {
            ble.connect(to: bike.peripheral)
        }
    }
    
    func disconnect() {
        ble.disconnect()
    }
    
    func forgetBike() {
        ble.forgetBike()
    }
    
    func lock() {
        guard !isProcessing else { return }
        isProcessing = true
        
        Task {
            do {
                try await ble.lock()
            } catch {
                showError(error.localizedDescription)
            }
            isProcessing = false
        }
    }
    
    func unlock() {
        guard !isProcessing else { return }
        isProcessing = true
        
        Task {
            do {
                try await ble.unlock()
            } catch {
                showError(error.localizedDescription)
            }
            isProcessing = false
        }
    }
    
    func turnOff() {
        guard !isProcessing else { return }
        isProcessing = true
        
        Task {
            do {
                try await ble.turnOff()
            } catch {
                showError(error.localizedDescription)
            }
            isProcessing = false
        }
    }
    
    func toggleLock() {
        guard !isProcessing else { return }
        isProcessing = true
        
        Task {
            do {
                if lockStatus.isLocked {
                    try await ble.lock() // If OFF, toggles anti-theft
                } else {
                    try await ble.unlock() // If ON, turns the bike OFF
                }
            } catch {
                showError(error.localizedDescription)
            }
            isProcessing = false
        }
    }
    
    func findBike() {
        isFinding.toggle()
        Task {
            do {
                try await ble.findBike(start: isFinding)
            } catch {
                showError(error.localizedDescription)
                isFinding = false
            }
        }
    }

    func syncTime() {
        guard !isSyncingTime else { return }
        isSyncingTime = true
        Task {
            do {
                try await ble.syncTime()
                lastTimeSyncResult = true
                lastTimeSyncDate = Date()
            } catch {
                lastTimeSyncResult = false
                lastTimeSyncDate = Date()
                showError("Đồng bộ giờ thất bại: \(error.localizedDescription)")
            }
            isSyncingTime = false
        }
    }

    
    func refreshStatus() {
        Task {
            do {
                _ = try await ble.readLockStatus()
                await ble.readDeviceInfo()
                ble.readTelemetry()
            } catch {
                showError(error.localizedDescription)
            }
        }
    }
    
    func setAutoUnlock(_ enabled: Bool) {
        ble.autoUnlockEnabled = enabled
    }
    
    func setAutoConnect(_ enabled: Bool) {
        ble.autoConnectEnabled = enabled
    }

    // MARK: - BLE Test Panel

    @Published var testResult: String = ""
    @Published var isTestRunning: Bool = false
    @Published var testPreWriteDelay: Double = 2.0
    @Published var currentTestName: String = ""
    @Published var lastTestLogURL: URL?

    /// Index into ble.logs where the current test started — used by exportCurrentTestLog()
    private var testLogStartIndex: Int = 0

    func testReadCounter() {
        guard !isTestRunning else { return }
        currentTestName = "read_counter"
        testLogStartIndex = ble.logs.count
        isTestRunning = true
        testResult = "Đang đọc..."
        Task {
            let result = await ble.testReadCounter()
            testResult = result
            isTestRunning = false
        }
    }

    func testAuthAndVerify() {
        guard !isTestRunning else { return }
        currentTestName = "auth_verify_\(String(format: "%.1f", testPreWriteDelay))s"
        testLogStartIndex = ble.logs.count
        isTestRunning = true
        testResult = "Đang xác thực (\(testPreWriteDelay)s delay)..."
        Task {
            let result = await ble.testAuthAndVerify(preWriteDelay: testPreWriteDelay)
            testResult = result
            isTestRunning = false
        }
    }

    func testReadStatus() {
        guard !isTestRunning else { return }
        currentTestName = "read_status"
        testLogStartIndex = ble.logs.count
        isTestRunning = true
        testResult = "Đang đọc trạng thái..."
        Task {
            let result = await ble.testReadStatus()
            testResult = result
            isTestRunning = false
        }
    }

    func testForceDisconnect() {
        currentTestName = "force_disconnect"
        testLogStartIndex = ble.logs.count
        ble.testForceDisconnect()
        testResult = "Force disconnected (không reconnect)"
    }

    func testDisconnectAndReconnect() {
        currentTestName = "disconnect_reconnect"
        testLogStartIndex = ble.logs.count
        ble.testDisconnectAndReconnect()
        testResult = "Disconnect + scheduleReconnect triggered"
    }

    @Published var testMaxRetries: Int = 5

    func testRetryUntilPlusOne() {
        guard !isTestRunning else { return }
        currentTestName = "retry_plus1_max\(testMaxRetries)"
        testLogStartIndex = ble.logs.count
        isTestRunning = true
        testResult = "Retry auth → chờ +1 (max \(testMaxRetries) lần, delay \(testPreWriteDelay)s)..."
        Task {
            let result = await ble.testRetryUntilPlusOne(
                preWriteDelay: testPreWriteDelay,
                maxAttempts: testMaxRetries
            )
            testResult = result
            isTestRunning = false
        }
    }

    /// Lưu các log từ lúc bắt đầu test đến hiện tại ra file .txt, trả về URL để share.
    func exportCurrentTestLog() {
        let slice = Array(ble.logs.dropFirst(testLogStartIndex))
        guard !slice.isEmpty else { return }
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let text = slice.map { e in
            "\(timeFmt.string(from: e.timestamp)) [\(e.level.rawValue)] \(e.message)"
        }.joined(separator: "\n")

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "test_\(currentTestName)_\(stamp.string(from: Date())).txt"

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("test_logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        lastTestLogURL = url
    }

    // MARK: - Computed
    
    var signalStrength: SignalStrength {
        switch rssi {
        case -50...0:    return .excellent
        case -65...(-51): return .good
        case -80...(-66): return .fair
        default:          return .weak
        }
    }
    
    var isConnected: Bool {
        connectionState.isConnected
    }
    
    // MARK: - Telemetry Attributes
    
    var batteryPercentage: Int {
        if let soc = ble.batteryTelemetry?.soc?.soc {
            return Int(soc * 100)
        }
        return 0
    }
    
    var motorTemp: Float {
        ble.dashboardTelemetry?.motorTemp ?? 0
    }
    
    var controllerTemp: Float {
        ble.dashboardTelemetry?.controllerTemp ?? 0
    }
    
    var odometer: Float {
        ble.dashboardTelemetry?.odometerKm ?? 0
    }
    
    var speed: Float {
        ble.dashboardTelemetry?.speedKmh ?? 0
    }
    
    // MARK: - Helpers
    
    private func showError(_ message: String) {
        errorMessage = message
        showError = true
    }
}

// MARK: - Signal Strength

enum SignalStrength: Int, CaseIterable {
    case excellent = 4
    case good = 3
    case fair = 2
    case weak = 1
    
    var label: String {
        switch self {
        case .excellent: return "Rất mạnh"
        case .good:      return "Mạnh"
        case .fair:      return "Trung bình"
        case .weak:      return "Yếu"
        }
    }
    
    var color: Color {
        switch self {
        case .excellent: return .green
        case .good:      return .green.opacity(0.8)
        case .fair:      return .orange
        case .weak:      return .red
        }
    }
}
