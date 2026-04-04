// DatBikeSmartKeyApp.swift — App entry point (AccessorySetupKit)

import SwiftUI
import UserNotifications

// MARK: - App

@main
struct DatBikeSmartKeyApp: App {
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .onAppear {
                    requestNotificationPermission()
                    // Initialize BLEManager singleton — activates ASAccessorySession
                    _ = BLEManager.shared
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "mybikesmartkey" else { return }
        switch url.host {
        case "lock":      Task { try? await BLEManager.shared.lock() }
        case "unlock":    Task { try? await BLEManager.shared.turnOnBike() }
        case "connect":   BLEManager.shared.triggerManualConnect()
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

