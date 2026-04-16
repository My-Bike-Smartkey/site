import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Provider
struct BikeWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BikeWidgetEntry {
        BikeWidgetEntry(date: Date(), bikeName: "Dat Bike", connectionState: "Đang kết nối", battery: 85)
    }

    func getSnapshot(in context: Context, completion: @escaping (BikeWidgetEntry) -> ()) {
        let defaults = UserDefaults(suiteName: "group.app.mybike.smartkey") ?? UserDefaults.standard
        let state = defaults.string(forKey: "widgetCurrentState") ?? "Đang quét..."
        let battery = defaults.integer(forKey: "widgetBatteryLevel")
        let name = defaults.string(forKey: "widgetBikeName") ?? "Dat Bike"
        let entry = BikeWidgetEntry(date: Date(), bikeName: name, connectionState: state, battery: battery == 0 ? 85 : battery)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        let defaults = UserDefaults(suiteName: "group.app.mybike.smartkey") ?? UserDefaults.standard
        let state = defaults.string(forKey: "widgetCurrentState") ?? "Chưa kết nối"
        let battery = defaults.integer(forKey: "widgetBatteryLevel")
        let name = defaults.string(forKey: "widgetBikeName") ?? "Dat Bike"

        let entry = BikeWidgetEntry(date: Date(), bikeName: name, connectionState: state, battery: battery == 0 ? 100 : battery)

        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Entry
struct BikeWidgetEntry: TimelineEntry {
    let date: Date
    let bikeName: String
    let connectionState: String
    let battery: Int
}

// MARK: - Widget View
struct DatBikeWidgetEntryView: View {
    var entry: BikeWidgetProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "bolt.car.fill")
                    .foregroundColor(Color(red: 0, green: 0.96, blue: 1.0))
                    .font(.title2)
                Spacer()
                Text("\(entry.battery)%")
                    .font(.system(.footnote, design: .rounded).bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(batteryColor.opacity(0.3))
                    .cornerRadius(8)
            }

            Spacer()

            Text(entry.bikeName)
                .font(.headline)
                .foregroundColor(.white)

            Text(entry.connectionState)
                .font(.caption)
                .foregroundColor(.gray)
                .lineLimit(1)

            // Interactive Button
            let isConnected = entry.connectionState.contains("kết nối") && !entry.connectionState.contains("Chưa") && !entry.connectionState.contains("Đang")
            
            Button(intent: ToggleBikeLockIntent()) {
                HStack {
                    Image(systemName: "power")
                    Text("Bật / Tắt")
                        .font(.caption.bold())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isConnected ? Color(red: 0, green: 0.96, blue: 1.0).opacity(0.15) : Color.gray.opacity(0.15))
                .foregroundColor(isConnected ? Color(red: 0, green: 0.96, blue: 1.0) : Color.gray)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(!isConnected)
        }
        .padding()
    }
    
    private var batteryColor: Color {
        if entry.battery > 50 { return .green }
        if entry.battery > 20 { return .orange }
        return .red
    }
}

// MARK: - Widget Configuration
struct DatBikeWidgetExtension: Widget {
    let kind: String = "DatBikeWidgetExtension"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BikeWidgetProvider()) { entry in
            DatBikeWidgetEntryView(entry: entry)
                .containerBackground(Color.black, for: .widget)
        }
        .configurationDisplayName("Dat Bike SmartKey")
        .description("Theo dõi và điều khiển xe từ màn hình chính.")
        .supportedFamilies([.systemSmall])
    }
}

#Preview(as: .systemSmall) {
    DatBikeWidgetExtension()
} timeline: {
    BikeWidgetEntry(date: .now, bikeName: "Weaver 200", connectionState: "Đã kết nối", battery: 85)
    BikeWidgetEntry(date: .now, bikeName: "Weaver 200", connectionState: "Chưa kết nối", battery: 42)
}
