import Foundation
import Combine

/// Container Chứa toàn bộ các Service Cấp Cao.
/// Các ViewModel và Màn hình chỉ nhận Dependency từ đây.
@MainActor
class AppDIContainer: ObservableObject {
    
    // Core Services
    let bleCore: DatBikeCore
    let preferences: PreferencesManager
    
    // ViewModels
    lazy var dashboardViewModel: DashboardViewModel = {
        DashboardViewModel(core: bleCore, preferences: preferences)
    }()
    
    lazy var settingsViewModel: SettingsViewModel = {
        SettingsViewModel(core: bleCore, preferences: preferences)
    }()
    
    init() {
        self.bleCore = DatBikeCore()
        self.preferences = PreferencesManager.shared
        
        // Khởi động Bluetooth ngay lập tức nếu cần thiết
        // (Tuỳ chọn: Nếu muốn tự kích hoạt)
    }
}
