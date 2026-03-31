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
    @Published var authPIN: String {
        didSet { UserDefaults.standard.set(authPIN, forKey: "authPIN") }
    }
    @Published var rssiThreshold: Double {
        didSet { UserDefaults.standard.set(rssiThreshold, forKey: "rssiThreshold") }
    }
    
    // MARK: - Private
    
    private let ble = BLEManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Init
    
    init() {
        if let savedPIN = UserDefaults.standard.string(forKey: "authPIN") {
            self.authPIN = savedPIN
        } else {
            // Lần đầu: tự sinh PIN 12 ký tự ngẫu nhiên, lưu ngay
            let generatedPIN = BLEProtocol.generateSecurePIN()
            self.authPIN = generatedPIN
            UserDefaults.standard.set(generatedPIN, forKey: "authPIN")
        }
        self.rssiThreshold = UserDefaults.standard.double(forKey: "rssiThreshold") != 0
            ? UserDefaults.standard.double(forKey: "rssiThreshold")
            : Double(BLEProtocol.rssiThreshold)
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
                    try await ble.turnOff() // If ON, turns the bike OFF
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
