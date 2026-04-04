// DatBikeSmartKeyApp.swift — App entry point (AccessorySetupKit)

import SwiftUI
import UserNotifications

// MARK: - App

@main
struct DatBikeSmartKeyApp: App {
    
    @StateObject private var container = AppDIContainer()
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(container) // Truyền ngang dọc từ gốc
                .onAppear {
                    requestNotificationPermission()
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "mybikesmartkey" else { return }
        switch url.host {
        case "lock":      
            if let dispatcher = try? container.bleCore.getDispatcher() {
                Task { try? await dispatcher.toggleLock() }
            }
        case "unlock":    
            if let dispatcher = try? container.bleCore.getDispatcher() {
                Task { try? await dispatcher.turnOnBike() }
            }
        case "connect":   container.bleCore.connect()
        case "dashboard": break  // app mở bình thường
        default:          break
        }
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("✅ Notification permission granted")
            }
        }
    }
}
