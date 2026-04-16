import Foundation
import AppIntents

@available(iOS 16.0, *)
public struct ToggleBikeLockIntent: AppIntent {
    public static var title: LocalizedStringResource = "Bật/Tắt Xe"
    public static var description = IntentDescription("Bật hoặc tắt xe máy điện màn hình nền.")
    
    public init() {}
    
    public func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: "group.app.mybike.smartkey") ?? UserDefaults.standard
        let currentState = defaults.string(forKey: "widgetCurrentState") ?? ""
        
        // Cập nhật log ngầm cho Widget
        print("Widget Intent Triggered: Toggle Bike Lock, Current internal state: \(currentState)")
        
        // Vì Widget chạy độc lập ở Extension, nếu muốn điều khiển BLE, 
        // Extension CÓ THỂ tự instantiate 1 instance của DatBikeCore rút gọn, 
        // hoặc ra lệnh cho App qua Push Notification / URL Scheme.
        // Tối ưu nhất: Lưu cờ "pending_action" vào App Groups và gọi URL scheme (nếu app đang chết),
        // Hoặc trong AppIntent gọi thẳng DatBikeCore.shared nếu Core được public ở AppGroup framework.
        
        // Tạm thời, Widget sẽ demo thay đổi UI bằng cách chèn Data
        defaults.set("Đang chuyển đổi...", forKey: "widgetCurrentState")
        
        return .result()
    }
}
