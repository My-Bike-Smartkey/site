import Foundation
import ActivityKit
import UserNotifications

@available(iOS 16.1, *)
class LiveActivityManager {
    static let shared = LiveActivityManager()
    
    // B6 FIX: Cooldown guard để tránh spam log "Target is not foreground" mỗi 10s
    private var lastLiveActivityAttempt: Date?
    private let liveActivityCooldown: TimeInterval = 60.0
    
    private init() {}
    
    // MARK: - Public API
    
    func startActivity(bikeName: String, lockState: String, connectionState: String, batteryLevel: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        
        // Cooldown guard: Không cố start lại quá nhanh nếu lần trước vừa failed
        if let last = lastLiveActivityAttempt, Date().timeIntervalSince(last) < liveActivityCooldown {
            return
        }
        
        // Ưu tiên: tìm Live Activity đang chạy thực sự trên hệ thống (tránh dùng stale reference)
        let runningActivities = Activity<DatBikeLiveActivityAttributes>.activities
        
        if let existing = runningActivities.first {
            // Cập nhật activity đang chạy
            updateActivity(activity: existing, lockState: lockState, connectionState: connectionState, batteryLevel: batteryLevel)
            return
        }
        
        // Không có activity nào đang chạy → tạo mới
        let attributes = DatBikeLiveActivityAttributes(bikeName: bikeName)
        let contentState = DatBikeLiveActivityAttributes.ContentState(
            lockState: lockState,
            connectionState: connectionState,
            batteryLevel: batteryLevel
        )
        
        do {
            if #available(iOS 16.2, *) {
                // API mới (không deprecated): sử dụng ActivityContent
                let initialContent = ActivityContent(state: contentState, staleDate: nil)
                _ = try Activity.request(
                    attributes: attributes,
                    content: initialContent,
                    pushType: nil
                )
            } else {
                // iOS 16.1 — API cũ vẫn là cách duy nhất
                _ = try Activity.request(
                    attributes: attributes,
                    contentState: contentState,
                    pushType: nil
                )
            }
        } catch {
            // Cập nhật timestamp để kích hoạt cooldown 60s
            lastLiveActivityAttempt = Date()
            
            // Không re-throw — Live Activity là non-critical feature
            PersistentLogger.shared.append(BLELogEntry(
                timestamp: Date(), level: .info,
                message: "Live Activity không khởi động được (thường do app chạy ngầm): \(error.localizedDescription) — Cooldown \(liveActivityCooldown)s"
            ))
        }
    }
    
    func updateActivity(lockState: String, connectionState: String, batteryLevel: Int) {
        // Dùng danh sách activity thực tế từ hệ thống để tránh stale reference crash
        let runningActivities = Activity<DatBikeLiveActivityAttributes>.activities
        guard let activity = runningActivities.first else { return }
        updateActivity(activity: activity, lockState: lockState, connectionState: connectionState, batteryLevel: batteryLevel)
    }
    
    func endActivity() {
        // Lấy danh sách thực từ hệ thống thay vì dùng biến local (tránh crash stale reference)
        let runningActivities = Activity<DatBikeLiveActivityAttributes>.activities
        Task {
            for activity in runningActivities {
                await activity.end(dismissalPolicy: .immediate)
            }
        }
    }
    
    // MARK: - Private
    
    private func updateActivity(activity: Activity<DatBikeLiveActivityAttributes>, lockState: String, connectionState: String, batteryLevel: Int) {
        let updatedState = DatBikeLiveActivityAttributes.ContentState(
            lockState: lockState,
            connectionState: connectionState,
            batteryLevel: batteryLevel
        )
        Task {
            if #available(iOS 16.2, *) {
                let updatedContent = ActivityContent(state: updatedState, staleDate: nil)
                await activity.update(updatedContent)
            } else {
                await activity.update(using: updatedState)
            }
        }
    }
}
