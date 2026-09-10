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

    /// LỚP 3: User đang ở trạng thái "Tạm dừng" (đã ngắt BLE, không auto-reconnect).
    @Published var isPaused: Bool = false
    
    // Accessor cho View
    var batteryPercentage: Int { Int(telemetry.soc) }
    var odometer: Float { telemetry.odometerKm }
    var motorTemp: Float { telemetry.motorTemp }
    var isConnected: Bool { connectionState.isConnected }
    var lockStatus: IoTLockState { lockState }
    
    var hasAuthorizedAccessory: Bool {
        if preferences.savedPeripheralUUID != nil { return true }
        if #available(iOS 18.0, *) {
            return ASKManager.shared.hasAuthorizedAccessory
        }
        return false // iOS 17 trở xuống không hỗ trợ ASK
    }
    
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
        self.isPaused = core.isConnectionPaused // sync trạng thái pause persist qua relaunch
        self.isNearbyNotInUse = (core.connectionIntent == .manualOnlyNearbyNotInUse) // §4.5
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
            .sink { [weak self] data in
                guard let self else { return }
                self.telemetry = data
                if data.soc > 0 { self.lastDataUpdatedAt = Date() } // §4.4: timestamp dữ liệu stale
            }
            .store(in: &cancellables)

        // §UX: pending connect flag — phân biệt "chờ xe vào tầm sóng" vs "đang kết nối"
        core.$isPendingConnectWaiting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in
                self?.isPendingConnect = val
            }
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
        if #available(iOS 18.0, *) {
            let ask = ASKManager.shared
            if ask.hasAuthorizedAccessory {
                core.initializeBluetoothHardware()
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "Trì hoãn khởi tạo Bluetooth (iOS 18) để tránh xung đột ASK Picker."))
            }
        } else {
            core.initializeBluetoothHardware()
        }
    }
    
    func connectBike() {
        self.pairingError = nil
        self.showError = false

        if #available(iOS 18.0, *) {
            let ask = ASKManager.shared

            // ═══ F2: session.accessories chỉ đáng tin SAU .activated ═══
            // Cold-launch race: đọc quá sớm → false dù user đã pair → (bản cũ)
            // tự showPicker không user gesture. Giờ: đợi activation rồi retry 1 lần.
            if !ask.isActivated {
                askActivationCancellable = ask.$isActivated
                    .receive(on: DispatchQueue.main)
                    .first(where: { $0 })
                    .sink { [weak self] _ in
                        self?.askActivationCancellable = nil
                        self?.connectBike()
                    }
                return
            }

            guard ask.hasAuthorizedAccessory else {
                // ═══ F4 offline-path: event .accessoryRemoved có thể bị bỏ lỡ ═══
                // (app không chạy lúc user gỡ trong Settings). Phát hiện stale:
                // app còn UUID nhưng hệ thống không còn accessory → dọn + báo.
                if preferences.savedPeripheralUUID != nil {
                    core.handleAccessoryRemovedFromSystem()
                }
                // Chưa từng pair → KHÔNG auto-showPicker (F2).
                // UI tự hiện nút "Thêm xe" cho user chủ động ghép đôi.
                return
            }
        }

        isProcessing = true
        core.initializeBluetoothHardware()
        core.connect()
    }

    /// Bắt đầu ghép đôi — CHỈ gọi từ user gesture (nút "Thêm xe", alert xác nhận).
    /// Đây là đường DUY NHẤT được mở ASK picker (F2: chuẩn user-gesture của Apple).
    func startPairing() {
        pairingError = nil
        showError = false

        guard #available(iOS 18.0, *) else {
            // iOS 15-17: không có ASK — dùng luồng scan CoreBluetooth cũ
            isProcessing = true
            core.initializeBluetoothHardware()
            core.connect()
            return
        }

        ASKManager.shared.onPickerDismissed = { [weak self] error in
            DispatchQueue.main.async {
                self?.isProcessing = false
                // F3: completion fire ở CẢ HAI nhánh — chọn xong hoặc cancel.
                // Chỉ nâng lỗi khi user KHÔNG chọn được xe nào.
                if let error = error {
                    self?.pairingError = error.localizedDescription
                    self?.errorMessage = error.localizedDescription
                    self?.showError = true
                }
            }
        }
        isProcessing = true

        // Xoá mờ ranh giới animation của SwiftUI Button, đảm bảo UIWindow hoàn toàn sẵn sàng tiếp nhận XPC.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            ASKManager.shared.showPicker()
        }
    }

    /// Cancellable cho việc chờ ASK activation (F2) — giữ strong để subscription sống.
    private var askActivationCancellable: AnyCancellable?
    
    /// User chọn xe từ danh sách (Fallback cho iOS 15/16)
    func selectBike(_ bikeId: String) {
        isProcessing = true
        core.selectBike(bikeId)
    }
    
    func refreshStatus() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Tải lại' (Refresh Status)"))
        isProcessing = true
        core.queryTelemetry()
        // isProcessing sẽ tự tắt khi lockState cập nhật (trong setupBindings)
    }
    
    func forceAuthenticate() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Đánh thức xe' (Force Authenticate)"))
        isProcessing = true
        core.forceAuthenticate()
    }
    
    func submitPairingPin(_ pin: String) {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User submitted PIN"))
        core.submitPairingPin(pin)
    }
    
    func forceStandby() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Ngắt kết nối' (Force Standby)"))
        core.forceStandbyOverride()
    }
    
    /// User bấm "Kết nối" khi đang ở nearby → auth ngay
    func connectFromNearby() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Kết nối' từ chế độ gần xe"))
        isProcessing = true
        core.connectFromNearby()
    }
    
    /// User bấm "Kết nối lại" khi bị kẹt ở scanning → reset toàn bộ flags + connect mới
    func forceReconnect() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Kết nối lại' (Force Reconnect)"))
        isProcessing = true
        core.forceReconnect()
    }
    
    /// User bật chế độ "Đang ở gần"
    func activateNearbyMode() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User bật chế độ 'Đang ở gần'"))
        core.activateNearbyMode()
    }
    
    /// User tắt chế độ "Đang ở gần"
    func deactivateNearbyMode() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tắt chế độ 'Đang ở gần'"))
        isProcessing = true
        core.deactivateNearbyMode()
    }

    // MARK: - Lớp 3: Tạm dừng / Tiếp tục kết nối

    /// User bấm "Tạm dừng" → ngắt BLE hoàn toàn, chặn auto-reconnect (dẹp code=6).
    func pauseConnection() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Tạm dừng' (Pause)"))
        core.pauseConnection()
        isPaused = true
    }

    /// User bấm "Tiếp tục kết nối" → mở lại auto-reconnect.
    func resumeConnection() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Tiếp tục' (Resume)"))
        isPaused = false
        isNearbyNotInUse = false
        isProcessing = true
        core.resumeConnection()
    }

    // MARK: - §4 (P3): "Ở gần xe, chưa dùng" / "Kết nối để dùng xe"

    /// Reason manualOnly cho copy UI (card + nút).
    @Published var isNearbyNotInUse: Bool = false

    /// §UX: pending connect (chờ xe vào tầm sóng) — bind từ core.
    @Published private(set) var isPendingConnect = false

    /// Dòng dữ liệu stale cho card manualOnly: "pin 84% · 17:22".
    var staleDataLine: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if telemetry.soc > 0 {
            return "Dữ liệu mới nhất: pin \(Int(telemetry.soc))% · \(formatter.string(from: lastDataUpdatedAt))"
        }
        return "Dữ liệu mới nhất: chưa có dữ liệu"
    }
    private var lastDataUpdatedAt = Date()

    /// §4.1: Nút "Ở gần xe, chưa dùng" — ngắt BLE một lần, chặn auto-connect.
    func setNearbyNotInUse() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Ở gần xe, chưa dùng'"))
        isNearbyNotInUse = true
        isPaused = true // cùng cơ chế manualOnly (UI cũ render card qua isPaused)
        core.setNearbyNotInUse()
    }

    /// §4.1: Nút chính trên card — thoát manualOnly và kết nối.
    func connectForRide() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Kết nối để dùng xe'"))
        isNearbyNotInUse = false
        isPaused = false
        isProcessing = true
        core.connectForRide()
    }
    
    func lock() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Chống trộm' (Arm Anti-Theft)"))
        core.suspendAutoFeatures()
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
        guard !isProcessing else { return }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Bật xe' (Turn On Bike)"))
        core.suspendAutoFeatures()
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
        guard !isProcessing else { return }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Tắt xe' (Turn Off Bike)"))
        core.suspendAutoFeatures()
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
        guard !isProcessing else { return }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped Main V-Hexa Button (Toggle Lock)"))
        core.suspendAutoFeatures()
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
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Tìm xe' (Find Bike)"))
        guard let dispatcher = try? core.getDispatcher() else { return }
        isFinding = true
        Task {
            try? await dispatcher.findBike(start: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.isFinding = false }
        }
    }
}
