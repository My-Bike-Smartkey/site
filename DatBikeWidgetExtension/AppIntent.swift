import WidgetKit
import AppIntents

struct ToggleBikeLockIntent: AppIntent {
    static var title: LocalizedStringResource = "Bật/Tắt Xe"
    static var description = IntentDescription("Bật hoặc tắt xe máy điện từ Widget.")
    
    init() {}
    
    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: "group.app.mybike.smartkey") ?? UserDefaults.standard
        let currentState = defaults.string(forKey: "widgetCurrentState") ?? ""
        print("Widget Intent: Toggle Bike Lock, state: \(currentState)")
        defaults.set("Đang chuyển đổi...", forKey: "widgetCurrentState")
        return .result()
    }
}
