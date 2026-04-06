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
    
    @Published var savedPeripheralUUID: String? {
        didSet { UserDefaults.standard.set(savedPeripheralUUID, forKey: "lastPeripheralUUID") }
    }
    
    /// Ngày cuối cùng đã sync time với xe — dùng để auto sync 1 lần/ngày
    var lastTimeSyncDate: Date? {
        get { UserDefaults.standard.object(forKey: "lastTimeSyncDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastTimeSyncDate") }
    }
    
    /// Kiểm tra hôm nay đã sync time chưa
    var needsTimeSyncToday: Bool {
        guard let last = lastTimeSyncDate else { return true }
        return !Calendar.current.isDateInToday(last)
    }
    
    private init() {
        let storedRssi = UserDefaults.standard.double(forKey: "rssiThreshold")
        self.rssiThreshold = storedRssi == 0 ? -65.0 : storedRssi
        
        self.autoUnlockEnabled = UserDefaults.standard.bool(forKey: "autoUnlockEnabled")
        self.isDebugModeEnabled = UserDefaults.standard.object(forKey: "isDebugModeEnabled") as? Bool ?? true
        self.savedPin = UserDefaults.standard.string(forKey: "savedPin")
        self.savedPeripheralUUID = UserDefaults.standard.string(forKey: "lastPeripheralUUID")
    }
}
