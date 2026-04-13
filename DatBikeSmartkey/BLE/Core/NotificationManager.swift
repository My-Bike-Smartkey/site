//
//  NotificationManager.swift
//  DatBikeSmartkey
//

import Foundation
import UserNotifications

class NotificationManager: NSObject, @unchecked Sendable {
    static let shared = NotificationManager()
    
    // Lưu lại thời gian đã gửi thông báo để tránh spam (Debounce 60 giây)
    private var lastNotificationTime: Date?
    private let debounceInterval: TimeInterval = 60.0
    
    private override init() {
        super.init()
    }
    
    func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning, message: "Lỗi xin quyền thông báo: \(error.localizedDescription)"))
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "Quyền thông báo hệ thống: \(granted ? "Đã cấp" : "Từ chối")"))
            }
        }
    }
    
    func sendConnectNotification(bikeName: String = "Xe máy điện DATBIKE") {
        // Kiểm tra cơ chế chống Spam
        let now = Date()
        if let lastTime = lastNotificationTime {
            if now.timeIntervalSince(lastTime) < debounceInterval {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "Bỏ qua thông báo kết nối do ngắt quãng quá ngắn (< \(Int(debounceInterval))s)"))
                return
            }
        }
        
        lastNotificationTime = now
        
        let content = UNMutableNotificationContent()
        content.title = "Đã kết nối thành công"
        content.body = "Điện thoại của bạn đã lấy lại sóng Bluetooth với \(bikeName). Sẵn sàng sử dụng!"
        content.sound = UNNotificationSound.default
        
        // Push ngay lập tức (1 giây)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
        let request = UNNotificationRequest(identifier: "DatBikeConnection", content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error, message: "Lỗi gửi Local Notification: \(error.localizedDescription)"))
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success, message: "Đã bật Notification Background báo kết nối thành công."))
            }
        }
    }
}
