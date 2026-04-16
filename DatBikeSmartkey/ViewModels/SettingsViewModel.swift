import Foundation
import Combine

@MainActor
class SettingsViewModel: ObservableObject {
    
    private let core: DatBikeCore
    let preferences: PreferencesManager
    
    // Outputs cho giao diện Cài đặt
    @Published var rssiThreshold: Double
    @Published var autoUnlockEnabled: Bool
    @Published var autoTurnOnThreshold: Double
    @Published var connectOnlyWhenNear: Bool
    @Published var isDebugModeEnabled: Bool
    @Published var notificationsEnabled: Bool
    @Published var widgetAndLiveActivityEnabled: Bool
    
    @Published var isConnected: Bool = false
    @Published var isSyncingTime: Bool = false
    
    @Published var bikeInfo = IoTVehicleInfo()
    @Published var logs: [BLELogEntry] = []
    
    private var cancellables = Set<AnyCancellable>()
    
    init(core: DatBikeCore, preferences: PreferencesManager) {
        self.core = core
        self.preferences = preferences
        
        self.rssiThreshold = preferences.rssiThreshold
        self.autoUnlockEnabled = preferences.autoUnlockEnabled
        self.autoTurnOnThreshold = preferences.autoTurnOnThreshold
        self.connectOnlyWhenNear = preferences.connectOnlyWhenNear
        self.isDebugModeEnabled = preferences.isDebugModeEnabled
        self.notificationsEnabled = preferences.notificationsEnabled
        self.widgetAndLiveActivityEnabled = preferences.widgetAndLiveActivityEnabled
        
        setupBindings()
    }
    
    private func setupBindings() {
        // Đồng bộ 2 chiều: Khi gạt toggle trên Màn hình, nó đẩy thẳng vào Singleton Preferences
        $rssiThreshold
            .dropFirst()
            .sink { [weak self] val in
                guard let self = self else { return }
                self.preferences.rssiThreshold = val
                // Ngưỡng bật xe phải GẦN HƠN (lớn hơn) ngưỡng kết nối
                if self.autoTurnOnThreshold < val {
                    self.autoTurnOnThreshold = val
                }
            }
            .store(in: &cancellables)
            
        $autoUnlockEnabled
            .dropFirst()
            .sink { [weak self] val in self?.preferences.autoUnlockEnabled = val }
            .store(in: &cancellables)
            
        $autoTurnOnThreshold
            .dropFirst()
            .sink { [weak self] val in
                guard let self = self else { return }
                self.preferences.autoTurnOnThreshold = val
                // Ngưỡng kết nối phải XA HƠN (nhỏ hơn) hoặc bằng ngưỡng bật xe
                if val < self.rssiThreshold {
                    self.rssiThreshold = val
                }
            }
            .store(in: &cancellables)
            
        $connectOnlyWhenNear
            .dropFirst()
            .sink { [weak self] val in self?.preferences.connectOnlyWhenNear = val }
            .store(in: &cancellables)
            
        $isDebugModeEnabled
            .dropFirst()
            .sink { [weak self] val in self?.preferences.isDebugModeEnabled = val }
            .store(in: &cancellables)
            
        $notificationsEnabled
            .dropFirst()
            .sink { [weak self] val in self?.preferences.notificationsEnabled = val }
            .store(in: &cancellables)
            
        $widgetAndLiveActivityEnabled
            .dropFirst()
            .sink { [weak self] val in self?.preferences.widgetAndLiveActivityEnabled = val }
            .store(in: &cancellables)
        
        core.$currentVehicleInfo
            .receive(on: DispatchQueue.main)
            .assign(to: \.bikeInfo, on: self)
            .store(in: &cancellables)
        
        core.connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.isConnected = (state == .active)
            }
            .store(in: &cancellables)
    }
    
    func forgetBike() {
        core.disconnect()
        // Xoá PIN + UUID → lần ghép tiếp sẽ hiện bước NFC + scan mới
        PreferencesManager.shared.savedPin = nil
        PreferencesManager.shared.savedPeripheralUUID = nil
    }
    
    func syncTime() {
        guard let dispatcher = try? core.getDispatcher() else { return }
        Task {
            try? await dispatcher.syncTime()
        }
    }
    
    // Developer Utils
    func deleteAllRecords() {
        // ...
    }
}
