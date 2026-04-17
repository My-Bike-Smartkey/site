import Foundation
import ActivityKit
import UserNotifications

@available(iOS 16.1, *)
class LiveActivityManager {
    static let shared = LiveActivityManager()
    
    private var currentActivity: Activity<DatBikeLiveActivityAttributes>?
    
    private init() {}
    
    func startActivity(bikeName: String, lockState: String, connectionState: String, batteryLevel: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        
        if currentActivity != nil {
            updateActivity(lockState: lockState, connectionState: connectionState, batteryLevel: batteryLevel)
            return
        }
        
        let attributes = DatBikeLiveActivityAttributes(bikeName: bikeName)
        let initialContentState = DatBikeLiveActivityAttributes.ContentState(
            lockState: lockState,
            connectionState: connectionState,
            batteryLevel: batteryLevel
        )
        
        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                contentState: initialContentState,
                pushType: nil
            )
            print("Live Activity started: \(currentActivity?.id ?? "")")
        } catch {
            print("Error starting Live Activity: \(error.localizedDescription)")
        }
    }
    
    func updateActivity(lockState: String, connectionState: String, batteryLevel: Int) {
        guard let activity = currentActivity else { return }
        
        let updatedContentState = DatBikeLiveActivityAttributes.ContentState(
            lockState: lockState,
            connectionState: connectionState,
            batteryLevel: batteryLevel
        )
        
        Task {
            await activity.update(using: updatedContentState)
        }
    }
    
    func endActivity() {
        let activities = Activity<DatBikeLiveActivityAttributes>.activities
        Task {
            for activity in activities {
                await activity.end(dismissalPolicy: .immediate)
            }
        }
    }
}
