// DatBikeSmartKeyApp.swift — App entry point

import SwiftUI
import UserNotifications

@main
struct DatBikeSmartKeyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .onAppear {
                    requestNotificationPermission()
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

// MARK: - App Delegate (for background launch handling)

class AppDelegate: NSObject, UIApplicationDelegate {
    
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        
        // Check if app was launched by iOS due to BLE event
        if let bluetoothCentrals = launchOptions?[.bluetoothCentrals] as? [String] {
            print("🔄 App launched by iOS for BLE central restore: \(bluetoothCentrals)")
            // BLEManager.shared will be initialized and handle state restoration
            _ = BLEManager.shared
        }
        
        return true
    }
}
