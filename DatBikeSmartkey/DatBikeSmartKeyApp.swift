// DatBikeSmartKeyApp.swift — App entry point (AccessorySetupKit)

import SwiftUI
import UserNotifications
import FirebaseCore

// MARK: - AppDelegate (Firebase setup)

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        return true
    }
}

// MARK: - App

@main
struct DatBikeSmartKeyApp: App {
    
    // Kết nối AppDelegate để Firebase khởi động trước khi UI render
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    
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

