import Foundation
import Combine

/// Quản lý tập trung mọi tùy chọn hệ thống cài đặt của App.
/// Loại bỏ hoàn toàn sự rải rác của `UserDefaults.standard` trong mã nguồn.
class PreferencesManager {
    static let shared = PreferencesManager()
    
    @Published var rssiThreshold: Double {
        didSet { UserDefaults.standard.set(rssiThreshold, forKey: "rssiThreshold") }
    }
    
    @Published var autoUnlockEnabled: Bool {
        didSet { UserDefaults.standard.set(autoUnlockEnabled, forKey: "autoUnlockEnabled") }
    }
    
    @Published var isDebugModeEnabled: Bool {
        didSet { UserDefaults.standard.set(isDebugModeEnabled, forKey: "isDebugModeEnabled") }
    }
    
    @Published var savedPin: String? {
        didSet { UserDefaults.standard.set(savedPin, forKey: "savedPin") }
    }
    
    private init() {
        let storedRssi = UserDefaults.standard.double(forKey: "rssiThreshold")
        self.rssiThreshold = storedRssi == 0 ? -65.0 : storedRssi
        
        self.autoUnlockEnabled = UserDefaults.standard.bool(forKey: "autoUnlockEnabled")
        self.isDebugModeEnabled = UserDefaults.standard.object(forKey: "isDebugModeEnabled") as? Bool ?? true
        self.savedPin = UserDefaults.standard.string(forKey: "savedPin")
    }
}
