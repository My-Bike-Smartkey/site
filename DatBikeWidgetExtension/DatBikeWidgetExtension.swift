import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Provider
struct BikeWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BikeWidgetEntry {
        BikeWidgetEntry(date: Date(), bikeName: "Dat Bike", connectionState: "Đang tải...", battery: 85, lockStatusRaw: "locked", odometer: 0, motorTemp: 0, lastUpdated: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (BikeWidgetEntry) -> ()) {
        let defaults = UserDefaults(suiteName: "group.app.mybike.smartkey") ?? UserDefaults.standard
        let state = defaults.string(forKey: "widgetCurrentState") ?? "Đang quét..."
        let battery = defaults.integer(forKey: "widgetBatteryLevel")
        let name = defaults.string(forKey: "widgetBikeName") ?? "Dat Bike"
        
        let lockState = "locked"
        let odo: Float = 0
        
        // Cố gắng đọc từ SharedBikeState
        if let data = defaults.data(forKey: "sharedBikeState"),
           let decoded = try? JSONDecoder().decode(SharedBikeState.self, from: data) {
            completion(BikeWidgetEntry(date: Date(), bikeName: name, connectionState: state, battery: battery == 0 ? decoded.batteryPercent : battery, lockStatusRaw: decoded.lockStatusRaw, odometer: decoded.odometerKm, motorTemp: decoded.motorTemp, lastUpdated: decoded.lastUpdated))
        } else {
            completion(BikeWidgetEntry(date: Date(), bikeName: name, connectionState: state, battery: battery == 0 ? 85 : battery, lockStatusRaw: lockState, odometer: odo, motorTemp: 0, lastUpdated: Date()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        let defaults = UserDefaults(suiteName: "group.app.mybike.smartkey") ?? UserDefaults.standard
        let state = defaults.string(forKey: "widgetCurrentState") ?? "Chưa kết nối"
        let battery = defaults.integer(forKey: "widgetBatteryLevel")
        let name = defaults.string(forKey: "widgetBikeName") ?? "Dat Bike"
        
        var lockState = "locked"
        var odo: Float = 0
        var motorTemp: Float = 0
        var lastUpdated: Date = .distantPast
        var realBattery = battery == 0 ? 100 : battery
        
        if let data = defaults.data(forKey: "sharedBikeState"),
           let decoded = try? JSONDecoder().decode(SharedBikeState.self, from: data) {
            lockState = decoded.lockStatusRaw
            odo = decoded.odometerKm
            motorTemp = decoded.motorTemp
            lastUpdated = decoded.lastUpdated
            realBattery = decoded.batteryPercent > 0 ? decoded.batteryPercent : realBattery
        }

        let entry = BikeWidgetEntry(date: Date(), bikeName: name, connectionState: state, battery: realBattery, lockStatusRaw: lockState, odometer: odo, motorTemp: motorTemp, lastUpdated: lastUpdated)

        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Entry
struct SharedBikeState: Codable {
    var isConnected: Bool = false
    var isAuthenticated: Bool = false
    var connectionPhase: String = "disconnected"
    var lockStatusRaw: String = "unknown"
    var bikeName: String = ""
    var batteryPercent: Int = 0
    var odometerKm: Float = 0
    var motorTemp: Float = 0
    var lastUpdated: Date = .distantPast
}

struct BikeWidgetEntry: TimelineEntry {
    let date: Date
    let bikeName: String
    let connectionState: String
    let battery: Int
    let lockStatusRaw: String
    let odometer: Float
    let motorTemp: Float
    let lastUpdated: Date
}

// MARK: - Widget View
struct DatBikeWidgetEntryView: View {
    var entry: BikeWidgetProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: lockIcon)
                    .font(.title2)
                    .foregroundColor(entry.lockStatusRaw == "unlocked" ? .green : .white)
            }
            .widgetURL(URL(string: "mybikesmartkey://lock")!)
            
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                HStack {
                    Image("VHexaLogoWhite").renderingMode(.template).resizable().scaledToFit().frame(width: 20, height: 20).foregroundColor(carColor)
                    Text("\(entry.battery)%")
                        .font(.headline)
                }
                Text(entry.connectionState)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .widgetURL(URL(string: "mybikesmartkey://dashboard")!)
            
        case .accessoryInline:
            Label("\(entry.battery)% - \(entry.connectionState)", image: "VHexaLogoWhite")
            
        case .systemMedium:
            HStack(spacing: 0) {
                // Left side: Info
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image("VHexaLogoWhite")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .foregroundColor(carColor)
                        Text(entry.bikeName)
                            .font(.headline)
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    // Battery
                    HStack {
                        Text("\(entry.battery)%")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        if entry.odometer > 0 {
                            Text("· \(String(format: "%.0f", entry.odometer))km")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Date().timeIntervalSince(entry.lastUpdated) > 300 ? Color.red : Color.green)
                            .frame(width: 6, height: 6)
                        Text(entry.connectionState)
                            .font(.caption)
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }
                    let minutesAgo = Int(Date().timeIntervalSince(entry.lastUpdated) / 60)
                    if minutesAgo > 5 {
                        Text("Chờ lâu (\(minutesAgo)p)")
                            .font(.caption2)
                            .foregroundColor(.red.opacity(0.8))
                    } else {
                        Text("Vừa cập nhật")
                            .font(.caption2)
                            .foregroundColor(Color.green.opacity(0.8))
                    }
                }
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Right side: Action Buttons
                VStack(spacing: 8) {
                    // Trạng thái kết nối đã được DatBikeCore suy ra chính xác giống Dashboard
                    let isBikeOn = entry.connectionState.contains("bật") || entry.lockStatusRaw == "unlocked"
                    let isConnected = isBikeOn || (entry.connectionState.contains("kết nối") && !entry.connectionState.contains("Chưa") && !entry.connectionState.contains("Đang"))
                    
                    // Lock Toggle Button
                    Link(destination: URL(string: "mybikesmartkey://lock")!) {
                        HStack {
                            Image(systemName: lockIcon)
                            Text(entry.lockStatusRaw == "unlocked" ? "Khoá Xe" : "Mở Khoá")
                        }
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isConnected ? (entry.lockStatusRaw == "unlocked" ? Color.red.opacity(0.8) : Color(red: 0, green: 0.96, blue: 1.0).opacity(0.8)) : Color.gray.opacity(0.3))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(!isConnected)
                    
                    let isStandby = entry.connectionState.contains("Chờ") && !isBikeOn
                    let isReady = isConnected && !isStandby
                    
                    if isReady {
                        Link(destination: URL(string: "mybikesmartkey://disconnect")!) {
                            HStack {
                                Image(systemName: "wifi.slash")
                                Text("Ngắt Nối")
                            }
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.15))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                    } else {
                        Link(destination: URL(string: "mybikesmartkey://connect")!) {
                            HStack {
                                Image(systemName: isStandby ? "bolt.fill" : "antenna.radiowaves.left.and.right")
                                Text(isStandby ? "Đánh Thức" : "Kết Nối")
                            }
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.orange.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                    }
                }
                .frame(width: 120)
            }
            .padding()
            
        default:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image("VHexaLogoWhite")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .foregroundColor(carColor)
                    Spacer()
                    Text("\(entry.battery)%")
                        .font(.system(.footnote, design: .rounded).bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(batteryColor.opacity(0.3))
                        .cornerRadius(8)
                }
                
                Spacer()
                
                Text(entry.bikeName)
                    .font(.headline)
                
                Text(entry.connectionState)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
                
                let isConnected = entry.connectionState.contains("kết nối") && !entry.connectionState.contains("Chưa") && !entry.connectionState.contains("Đang")
                
                Link(destination: URL(string: "mybikesmartkey://lock")!) {
                    HStack {
                        Image(systemName: lockIcon)
                        Text("Bật / Tắt")
                            .font(.caption.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(isConnected ? Color(red: 0, green: 0.96, blue: 1.0).opacity(0.15) : Color.gray.opacity(0.15))
                    .foregroundColor(isConnected ? Color(red: 0, green: 0.96, blue: 1.0) : Color.gray)
                    .cornerRadius(10)
                }
            }
            .padding()
        }
    }
    

    private var carColor: Color {
        let isConnected = entry.connectionState.contains("kết nối") && !entry.connectionState.contains("Chưa") && !entry.connectionState.contains("Đang")
        if isConnected {
            return entry.lockStatusRaw == "unlocked" ? .green : .orange
        }
        return .gray
    }

    private var lockIcon: String {
        switch entry.lockStatusRaw {
        case "unlocked": return "lock.open.fill"
        case "armed":    return "lock.shield.fill"
        default:         return "lock.fill"
        }
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
        .description("Theo dõi và điều khiển xe từ màn hình chính và khoá màn hình.")
        .supportedFamilies([.systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
