import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Provider
@available(iOS 17.0, *)
struct BikeWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BikeWidgetEntry {
        BikeWidgetEntry(date: Date(), connectionState: "Đang kết nối", battery: 85)
    }

    func getSnapshot(in context: Context, completion: @escaping (BikeWidgetEntry) -> ()) {
        let entry = BikeWidgetEntry(date: Date(), connectionState: "Đang quét...", battery: 85)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        let defaults = UserDefaults(suiteName: "group.app.mybike.smartkey") ?? UserDefaults.standard
        let state = defaults.string(forKey: "widgetCurrentState") ?? "Chưa kết nối"
        let battery = defaults.integer(forKey: "widgetBatteryLevel")
        
        let entry = BikeWidgetEntry(date: Date(), connectionState: state, battery: battery == 0 ? 100 : battery)
        
        // Widget cập nhật lại sau mỗi 15 phút (hoặc khi App gọi WidgetCenter.shared.reloadAllTimelines)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Entry
struct BikeWidgetEntry: TimelineEntry {
    let date: Date
    let connectionState: String
    let battery: Int
}

// MARK: - Widget View
@available(iOS 17.0, *)
struct DatBikeWidgetEntryView : View {
    var entry: BikeWidgetProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    .background(Color.green.opacity(0.3))
                    .cornerRadius(8)
            }
            
            Spacer()
            
            Text("Dat Bike")
                .font(.headline)
                .foregroundColor(.white)
            
            Text(entry.connectionState)
                .font(.caption)
                .foregroundColor(.gray)
                .lineLimit(1)
            
            // Interactive Button
            Button(intent: ToggleBikeLockIntent()) {
                HStack {
                    Image(systemName: "power")
                    Text("Bật / Tắt")
                        .font(.caption.bold())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color(red: 0, green: 0.96, blue: 1.0).opacity(0.15))
                .foregroundColor(Color(red: 0, green: 0.96, blue: 1.0))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color.black)
    }
}

// MARK: - Widget Configuration
@available(iOS 17.0, *)
struct DatBikeWidget: Widget {
    let kind: String = "DatBikeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BikeWidgetProvider()) { entry in
            DatBikeWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Dat Bike Control")
        .description("Theo dõi và điều khiển xe từ màn hình chính.")
        .supportedFamilies([.systemSmall])
    }
}

@available(iOS 17.0, *)
@main
struct DatBikeWidgetBundle: WidgetBundle {
    var body: some Widget {
        DatBikeWidget()
        DatBikeLiveActivity()
    }
}
