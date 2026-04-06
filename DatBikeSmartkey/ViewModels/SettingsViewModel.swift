import Foundation
import Combine

@MainActor
class SettingsViewModel: ObservableObject {
    
    private let core: DatBikeCore
    let preferences: PreferencesManager
    
    // Outputs cho giao diện Cài đặt
    @Published var rssiThreshold: Double
    @Published var autoUnlockEnabled: Bool
    @Published var isDebugModeEnabled: Bool
    
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
        self.isDebugModeEnabled = preferences.isDebugModeEnabled
        
        setupBindings()
    }
    
    private func setupBindings() {
        // Đồng bộ 2 chiều: Khi gạt toggle trên Màn hình, nó đẩy thẳng vào Singleton Preferences
        $rssiThreshold
            .dropFirst()
            .sink { [weak self] val in self?.preferences.rssiThreshold = val }
            .store(in: &cancellables)
            
        $autoUnlockEnabled
            .dropFirst()
            .sink { [weak self] val in self?.preferences.autoUnlockEnabled = val }
            .store(in: &cancellables)
            
        $isDebugModeEnabled
            .dropFirst()
            .sink { [weak self] val in self?.preferences.isDebugModeEnabled = val }
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
