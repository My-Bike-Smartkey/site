import AppIntents
import SwiftUI
import WidgetKit

struct DatBikeWidgetExtensionControl: ControlWidget {
    static let kind: String = "app.dsmartkey.DatBikeWidgetExtension"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            provider: Provider()
        ) { value in
            ControlWidgetButton(action: OpenURLIntent(URL(string: "mybikesmartkey://lock")!)) {
                Label(value.isOn ? "Tắt Xe (Đang Mở)" : "Bật Xe (Đã Khoá)", systemImage: value.isOn ? "lock.open.fill" : "lock.fill")
            }
        }
        .displayName("Dat Bike SmartKey")
        .description("Bật hoặc tắt xe máy điện.")
    }
}

extension DatBikeWidgetExtensionControl {
    struct Value {
        var isOn: Bool
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: BikeControlConfiguration) -> Value {
            Value(isOn: false)
        }

        func currentValue(configuration: BikeControlConfiguration) async throws -> Value {
            let defaults = UserDefaults(suiteName: "group.app.mybike.smartkey") ?? UserDefaults.standard
            let state = defaults.string(forKey: "widgetCurrentState") ?? ""
            let isOn = state.contains("Đã kết nối") || state.contains("active")
            return Value(isOn: isOn)
        }
    }
}

struct BikeControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Cấu hình SmartKey"
}

// Cleaned unused Intent
