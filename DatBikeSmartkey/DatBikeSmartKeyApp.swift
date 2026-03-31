// DatBikeSmartKeyApp.swift — App entry point (AccessorySetupKit)

import SwiftUI
import UserNotifications

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
