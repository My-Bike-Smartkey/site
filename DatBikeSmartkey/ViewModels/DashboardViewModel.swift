import Foundation
import Combine

@MainActor
class DashboardViewModel: ObservableObject {
    
    // Dependencies
    private let core: DatBikeCore
    private let preferences: PreferencesManager
    private var cancellables = Set<AnyCancellable>()
    
    // Outputs cho UI
    @Published var connectionState: IoTConnectionState = .idle
    @Published var telemetry: IoTTelemetryData = IoTTelemetryData()
    @Published var lockState: IoTLockState = .locked
    @Published var isProcessing: Bool = false
    @Published var pairingError: String? = nil
    
    @Published var isFinding: Bool = false
    @Published var showError: Bool = false
    @Published var errorMessage: String = ""
    @Published var rssi: Int = 0
    
    /// Danh sách xe BLE tìm thấy trong quá trình scan
    @Published var discoveredBikes: [DiscoveredBike] = []
    
    @Published var bikeInfo = IoTVehicleInfo()
    
    // Accessor cho View
    var batteryPercentage: Int { Int(telemetry.soc) }
    var odometer: Float { telemetry.odometerKm }
    var motorTemp: Float { telemetry.motorTemp }
    var isConnected: Bool { connectionState.isConnected }
    var lockStatus: IoTLockState { lockState }
    
    // Signal
    var signalStrength: SignalStrength {
        if rssi >= -60 { return .excellent }
        if rssi >= -75 { return .good }
        if rssi >= -85 { return .fair }
        return .weak
    }
    
    init(core: DatBikeCore, preferences: PreferencesManager) {
        self.core = core
        self.preferences = preferences
        setupBindings()
    }
    
    private func setupBindings() {
        core.connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
                self?.isProcessing = false
                if case .error(let msg) = state {
                    self?.pairingError = msg
                    self?.errorMessage = msg
                    self?.showError = true
                } else {
                    self?.pairingError = nil
                }
            }
            .store(in: &cancellables)
            
        core.telemetryData
            .receive(on: DispatchQueue.main)
            .assign(to: \.telemetry, on: self)
            .store(in: &cancellables)
            
        core.lockState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.lockState = state
                self?.isProcessing = false
            }
            .store(in: &cancellables)
        
        core.$discoveredBikes
            .receive(on: DispatchQueue.main)
            .assign(to: \.discoveredBikes, on: self)
            .store(in: &cancellables)
        
        core.$currentVehicleInfo
            .receive(on: DispatchQueue.main)
            .assign(to: \.bikeInfo, on: self)
            .store(in: &cancellables)
        
        core.$currentRSSI
            .receive(on: DispatchQueue.main)
            .assign(to: \.rssi, on: self)
            .store(in: &cancellables)
    }
    
    // MARK: - Tiền Trình Bấm Nút
    
    func initializeHardware() {
        core.initializeBluetoothHardware()
    }
    
    func connectBike() {
        isProcessing = true
        core.connect()
    }
    
    /// User chọn xe từ danh sách
    func selectBike(_ bikeId: String) {
        isProcessing = true
        core.selectBike(bikeId)
    }
    
    func refreshStatus() {
        isProcessing = true
        core.queryTelemetry()
        // isProcessing sẽ tự tắt khi lockState cập nhật (trong setupBindings)
    }
    
    func submitPairingPin(_ pin: String) {
        core.submitPairingPin(pin)
    }
    
    func lock() {
        guard let dispatcher = try? core.getDispatcher() else { return }
        isProcessing = true
        Task {
            if let state = try? await dispatcher.armAntiTheft() {
                self.lockState = state
            }
            self.isProcessing = false
        }
    }
    
    func turnOnBike() {
        guard let dispatcher = try? core.getDispatcher() else { return }
        isProcessing = true
        Task {
            if let state = try? await dispatcher.turnOnBike() {
                self.lockState = state
            }
            self.isProcessing = false
        }
    }
    
    func turnOffBike() {
        guard let dispatcher = try? core.getDispatcher() else { return }
        isProcessing = true
        Task {
            if let state = try? await dispatcher.turnOffBike() {
                self.lockState = state
            }
            self.isProcessing = false
        }
    }
    
    func toggleLock() {
        guard let dispatcher = try? core.getDispatcher() else { return }
        isProcessing = true
        Task {
            if let state = try? await dispatcher.toggleLock(currentState: lockState) {
                self.lockState = state
            }
            self.isProcessing = false
        }
    }
    
    func findBike() {
        guard let dispatcher = try? core.getDispatcher() else { return }
        isFinding = true
        Task {
            try? await dispatcher.findBike(start: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.isFinding = false }
        }
    }
}
