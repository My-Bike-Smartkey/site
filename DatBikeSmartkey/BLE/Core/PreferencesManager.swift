import Foundation
import Combine

/// Quản lý tập trung mọi tùy chọn hệ thống cài đặt của App.
/// Loại bỏ hoàn toàn sự rải rác của `UserDefaults.standard` trong mã nguồn.
class PreferencesManager {
    static let shared = PreferencesManager()
    
    var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: "group.app.mybike.smartkey") ?? UserDefaults.standard
    }
    
    @Published var rssiThreshold: Double {
        didSet { sharedDefaults.set(rssiThreshold, forKey: "rssiThreshold") }
    }
    
    @Published var autoUnlockEnabled: Bool {
        didSet { sharedDefaults.set(autoUnlockEnabled, forKey: "autoUnlockEnabled") }
    }
    
    @Published var autoTurnOnThreshold: Double {
        didSet { sharedDefaults.set(autoTurnOnThreshold, forKey: "autoTurnOnThreshold") }
    }
    
    @Published var isDebugModeEnabled: Bool {
        didSet { sharedDefaults.set(isDebugModeEnabled, forKey: "isDebugModeEnabled") }
    }
    
    @Published var connectOnlyWhenNear: Bool {
        didSet { sharedDefaults.set(connectOnlyWhenNear, forKey: "connectOnlyWhenNear") }
    }
    
    @Published var notificationsEnabled: Bool {
        didSet { sharedDefaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    
    @Published var widgetAndLiveActivityEnabled: Bool {
        didSet { sharedDefaults.set(widgetAndLiveActivityEnabled, forKey: "widgetAndLiveActivityEnabled") }
    }
    
    // MARK: - Granular Notification Preferences
    // Mỗi loại thông báo có thể tắt riêng biệt (mặc định: bật hết)
    
    @Published var notifyOnConnected: Bool {
        didSet { sharedDefaults.set(notifyOnConnected, forKey: "notifyOnConnected") }
    }
    
    @Published var notifyOnDisconnected: Bool {
        didSet { sharedDefaults.set(notifyOnDisconnected, forKey: "notifyOnDisconnected") }
    }
    
    @Published var notifyOnStandby: Bool {
        didSet { sharedDefaults.set(notifyOnStandby, forKey: "notifyOnStandby") }
    }
    
    @Published var notifyOnAutoTurnOn: Bool {
        didSet { sharedDefaults.set(notifyOnAutoTurnOn, forKey: "notifyOnAutoTurnOn") }
    }
    
    // MARK: - Battery/BMS Notification Preferences
    
    @Published var notifyOnBatteryFull: Bool {
        didSet { sharedDefaults.set(notifyOnBatteryFull, forKey: "notifyOnBatteryFull") }
    }
    
    @Published var notifyOnBatteryThreshold: Bool {
        didSet { sharedDefaults.set(notifyOnBatteryThreshold, forKey: "notifyOnBatteryThreshold") }
    }
    
    @Published var notifyOnChargeDisconnect: Bool {
        didSet { sharedDefaults.set(notifyOnChargeDisconnect, forKey: "notifyOnChargeDisconnect") }
    }
    
    @Published var batteryLowThreshold: Int {
        didSet { sharedDefaults.set(batteryLowThreshold, forKey: "batteryLowThreshold") }
    }
    
    /// Bỏ qua gửi Proximity Token khi auth (dùng cho test ASK)
    @Published var skipProximityToken: Bool {
        didSet { sharedDefaults.set(skipProximityToken, forKey: "skipProximityToken") }
    }
    
    @Published var savedPin: String? {
        didSet { sharedDefaults.set(savedPin, forKey: "savedPin") }
    }
    
    @Published var savedPeripheralUUID: String? {
        didSet { sharedDefaults.set(savedPeripheralUUID, forKey: "lastPeripheralUUID") }
    }
    
    /// Ngày cuối cùng đã sync time với xe — dùng để auto sync 1 lần/ngày
    var lastTimeSyncDate: Date? {
        get { sharedDefaults.object(forKey: "lastTimeSyncDate") as? Date }
        set { sharedDefaults.set(newValue, forKey: "lastTimeSyncDate") }
    }
    
    /// Bọc trạng thái hiện thời để truyền qua App Group cho Widget tiện hiển thị
    var widgetCurrentState: String {
        get { sharedDefaults.string(forKey: "widgetCurrentState") ?? "Chưa kết nối" }
        set { sharedDefaults.set(newValue, forKey: "widgetCurrentState") }
    }
    
    var widgetBatteryLevel: Int {
        get { sharedDefaults.integer(forKey: "widgetBatteryLevel") }
        set { sharedDefaults.set(newValue, forKey: "widgetBatteryLevel") }
    }
    
    /// Kiểm tra hôm nay đã sync time chưa
    var needsTimeSyncToday: Bool {
        guard let last = lastTimeSyncDate else { return true }
        return !Calendar.current.isDateInToday(last)
    }
    
    private init() {
        let defaults = UserDefaults(suiteName: "group.app.mybike.smartkey") ?? UserDefaults.standard
        
        // Migrate data from standard UserDefaults to App Group if needed
        if !defaults.bool(forKey: "hasMigratedToAppGroup") {
            let standard = UserDefaults.standard
            let keys = ["rssiThreshold", "autoUnlockEnabled", "autoTurnOnThreshold", "isDebugModeEnabled", "connectOnlyWhenNear", "notificationsEnabled", "savedPin", "lastPeripheralUUID", "lastTimeSyncDate"]
            for key in keys {
                if let val = standard.object(forKey: key) {
                    defaults.set(val, forKey: key)
                }
            }
            defaults.set(true, forKey: "hasMigratedToAppGroup")
        }
        
        let storedRssi = defaults.double(forKey: "rssiThreshold")
        if storedRssi == 0 || storedRssi == -65.0 || storedRssi == -80.0 {
            self.rssiThreshold = -75.0
            defaults.set(-75.0, forKey: "rssiThreshold")
        } else {
            self.rssiThreshold = storedRssi
        }
        
        self.autoUnlockEnabled = defaults.bool(forKey: "autoUnlockEnabled")
        
        let storedAutoTurnOn = defaults.double(forKey: "autoTurnOnThreshold")
        if storedAutoTurnOn == 0 || storedAutoTurnOn == -70.0 {
            self.autoTurnOnThreshold = -50.0
            defaults.set(-50.0, forKey: "autoTurnOnThreshold")
        } else {
            self.autoTurnOnThreshold = storedAutoTurnOn
        }
        
        if defaults.object(forKey: "notificationsEnabled") == nil {
            self.notificationsEnabled = true
            defaults.set(true, forKey: "notificationsEnabled")
        } else {
            self.notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        }
        
        if defaults.object(forKey: "widgetAndLiveActivityEnabled") == nil {
            self.widgetAndLiveActivityEnabled = true
            defaults.set(true, forKey: "widgetAndLiveActivityEnabled")
        } else {
            self.widgetAndLiveActivityEnabled = defaults.bool(forKey: "widgetAndLiveActivityEnabled")
        }
        
        self.connectOnlyWhenNear = defaults.bool(forKey: "connectOnlyWhenNear")
        self.isDebugModeEnabled = defaults.object(forKey: "isDebugModeEnabled") as? Bool ?? false
        self.savedPin = defaults.string(forKey: "savedPin")
        self.savedPeripheralUUID = defaults.string(forKey: "lastPeripheralUUID")
        
        // Granular notification preferences — default true
        self.notifyOnConnected    = defaults.object(forKey: "notifyOnConnected")    as? Bool ?? true
        self.notifyOnDisconnected = defaults.object(forKey: "notifyOnDisconnected") as? Bool ?? true
        self.notifyOnStandby      = defaults.object(forKey: "notifyOnStandby")      as? Bool ?? true
        self.notifyOnAutoTurnOn   = defaults.object(forKey: "notifyOnAutoTurnOn")   as? Bool ?? true
        
        // BMS notification preferences — default true (except threshold which defaults to 20%)
        self.notifyOnBatteryFull      = defaults.object(forKey: "notifyOnBatteryFull")      as? Bool ?? true
        self.notifyOnBatteryThreshold = defaults.object(forKey: "notifyOnBatteryThreshold") as? Bool ?? true
        self.notifyOnChargeDisconnect = defaults.object(forKey: "notifyOnChargeDisconnect") as? Bool ?? true
        self.batteryLowThreshold      = defaults.integer(forKey: "batteryLowThreshold") > 0 ? defaults.integer(forKey: "batteryLowThreshold") : 20
        self.skipProximityToken        = defaults.object(forKey: "skipProximityToken") as? Bool ?? false
    }
}
