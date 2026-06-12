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
    
    /// Chế độ "Đang ở gần": phát hiện xe gần nhưng KHÔNG tự auth/bật xe.
    /// Khi user mở app (foreground) mới auth.
    @Published var nearbyModeEnabled: Bool {
        didSet { sharedDefaults.set(nearbyModeEnabled, forKey: "nearbyModeEnabled") }
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
    
    /// Bật/tắt ghi log bỏợi PersistentLogger
    @Published var isLoggingEnabled: Bool {
        didSet {
            sharedDefaults.set(isLoggingEnabled, forKey: "isLoggingEnabled")
            PersistentLogger.shared.isLoggingEnabled = isLoggingEnabled
        }
    }
    
    /// Ghi cả log VERBOSE (RSSI, STANDBY_CHECK...) — chỉ bật khi debug sâu
    @Published var verboseLoggingEnabled: Bool {
        didSet {
            sharedDefaults.set(verboseLoggingEnabled, forKey: "verboseLoggingEnabled")
            PersistentLogger.shared.minimumLevel = verboseLoggingEnabled ? .verbose : .info
        }
    }
    
    @Published var skipProximityToken: Bool {
        didSet { sharedDefaults.set(skipProximityToken, forKey: "skipProximityToken") }
    }
    
    /// Ẩn số khung xe trong log khi chia sẻ — bảo vệ quyền riêng tư
    @Published var redactFrameNumber: Bool {
        didSet { sharedDefaults.set(redactFrameNumber, forKey: "redactFrameNumber") }
    }
    
    @Published var savedPin: String? {
        didSet { sharedDefaults.set(savedPin, forKey: "savedPin") }
    }
    
    
    @Published var savedPeripheralUUID: String? {
        didSet { sharedDefaults.set(savedPeripheralUUID, forKey: "lastPeripheralUUID") }
    }
    
    @Published var savedBikeName: String? {
        didSet { sharedDefaults.set(savedBikeName, forKey: "savedBikeName") }
    }
    
    @Published var savedBikeSerial: String? {
        didSet { sharedDefaults.set(savedBikeSerial, forKey: "savedBikeSerial") }
    }
    
    @Published var savedBikeMac: String? {
        didSet { sharedDefaults.set(savedBikeMac, forKey: "savedBikeMac") }
    }
    
    @Published var savedBikeModel: String? {
        didSet { sharedDefaults.set(savedBikeModel, forKey: "savedBikeModel") }
    }
    
    @Published var savedBikeFirmware: String? {
        didSet { sharedDefaults.set(savedBikeFirmware, forKey: "savedBikeFirmware") }
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
        self.nearbyModeEnabled = defaults.bool(forKey: "nearbyModeEnabled")
        self.isDebugModeEnabled = defaults.object(forKey: "isDebugModeEnabled") as? Bool ?? false
        self.savedPin = defaults.string(forKey: "savedPin")
        self.savedPeripheralUUID = defaults.string(forKey: "lastPeripheralUUID")
        
        self.savedBikeName = defaults.string(forKey: "savedBikeName")
        self.savedBikeSerial = defaults.string(forKey: "savedBikeSerial")
        self.savedBikeMac = defaults.string(forKey: "savedBikeMac")
        self.savedBikeModel = defaults.string(forKey: "savedBikeModel")
        self.savedBikeFirmware = defaults.string(forKey: "savedBikeFirmware")
        
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
        self.redactFrameNumber         = defaults.object(forKey: "redactFrameNumber") as? Bool ?? true
        
        // Logging toggle — mặc định BẬT
        let loggingEnabled = defaults.object(forKey: "isLoggingEnabled") as? Bool ?? true
        self.isLoggingEnabled = loggingEnabled
        PersistentLogger.shared.isLoggingEnabled = loggingEnabled
        
        let verboseEnabled = defaults.object(forKey: "verboseLoggingEnabled") as? Bool ?? false
        self.verboseLoggingEnabled = verboseEnabled
        PersistentLogger.shared.minimumLevel = verboseEnabled ? .verbose : .info
    }
}
