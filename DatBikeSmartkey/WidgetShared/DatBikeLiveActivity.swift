import ActivityKit
import WidgetKit
import SwiftUI

@available(iOS 16.1, *)
struct BikeLiveActivityView: View {
    let context: ActivityViewContext<DatBikeLiveActivityAttributes>
    
    var body: some View {
        HStack {
            Image(systemName: "bicycle")
                .font(.title2)
                .foregroundColor(Color(red: 0, green: 0.96, blue: 1.0))
                .padding(.leading, 16)
            
            VStack(alignment: .leading) {
                Text(context.attributes.bikeName)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(context.state.connectionState)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            VStack(alignment: .trailing) {
                Text(context.state.lockState)
                    .font(.subheadline.bold())
                    .foregroundColor(context.state.lockState.contains("Mở") ? .green : .red)
                
                HStack(spacing: 4) {
                    Image(systemName: "battery.100")
                        .foregroundColor(.green)
                    Text("\(context.state.batteryLevel)%")
                        .font(.caption)
                        .foregroundColor(.white)
                }
            }
            .padding(.trailing, 16)
        }
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.8))
        .cornerRadius(20)
    }
}

@available(iOS 16.1, *)
struct DatBikeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DatBikeLiveActivityAttributes.self) { context in
            // Lock screen / Banner UI
            BikeLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "bicycle")
                        .foregroundColor(Color(red: 0, green: 0.96, blue: 1.0))
                        .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.batteryLevel)%")
                        .foregroundColor(.green)
                        .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.connectionState)
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.lockState)
                        .font(.body.bold())
                        .foregroundColor(context.state.lockState.contains("Mở") ? .green : .red)
                }
            } compactLeading: {
                Image(systemName: "bicycle")
                    .foregroundColor(Color(red: 0, green: 0.96, blue: 1.0))
            } compactTrailing: {
                Text(context.state.lockState.contains("Mở") ? "🔓" : "🔒")
            } minimal: {
                Image(systemName: "bolt.car.fill")
                    .foregroundColor(Color(red: 0, green: 0.96, blue: 1.0))
            }
        }
    }
}
