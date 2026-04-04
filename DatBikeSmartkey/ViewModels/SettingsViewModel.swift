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
    
    struct FakeBikeInfo {
        var name = "Dat Bike Weaver"
        var model = "Weaver 200"
        var serial = "DB200021"
        var deviceToken = "Token"
        var isEmpty = false
    }
    @Published var bikeInfo = FakeBikeInfo()
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
    }
    
    func forgetBike() {
        core.disconnect()
        // Cần truyền logic vào Core để xoá AccesssorySetupKit.
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
