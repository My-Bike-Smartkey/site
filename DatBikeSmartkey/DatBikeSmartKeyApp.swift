// DatBikeSmartKeyApp.swift — App entry point

import SwiftUI


class AppDelegate: NSObject, UIApplicationDelegate {
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let isBackgroundLaunch = launchOptions?[.bluetoothCentrals] != nil
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[APP_LAUNCH] isBackground=\(isBackgroundLaunch) | launchOptions=\(launchOptions?.keys.map(\.rawValue) ?? [])"))
        
        // ═══ CRITICAL: Khởi tạo CBCentralManager NGAY khi app launch ═══
        // Khi iOS relaunch app trong background (State Restoration),
        // CBCentralManager PHẢI được tạo với CÙNG RestoreIdentifierKey
        // để iOS gọi willRestoreState → kết nối lại BLE.
        let preferences = PreferencesManager.shared
        let hasSavedBike = preferences.savedPin != nil || preferences.savedPeripheralUUID != nil
        if UserDefaults.standard.bool(forKey: "disclaimerAccepted") && hasSavedBike {
            DatBikeCore.shared.initializeBluetoothHardware()
        }
        
        return true
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "App bị vuốt tắt (Terminated)"))
    }
}

// MARK: - App

@main
struct DatBikeSmartKeyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) var scenePhase
    
    @StateObject private var container = AppDIContainer()
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(container) // Truyền ngang dọc từ gốc
                .onAppear { }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .active:
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "App được mở lên (Foreground Active)"))
                    case .background:
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "App ẩn xuống chạy ngầm (Background)"))
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "mybikesmartkey" else { return }
        switch url.host {
        case "lock":      
            container.bleCore.suspendAutoFeatures()
            if let dispatcher = try? container.bleCore.getDispatcher() {
                Task { try? await dispatcher.toggleLock(currentState: self.container.dashboardViewModel.lockState) }
            }
        case "unlock":    
            container.bleCore.suspendAutoFeatures()
            if let dispatcher = try? container.bleCore.getDispatcher() {
                Task { try? await dispatcher.turnOnBike() }
            }
        case "connect":   container.bleCore.wakeUpFromStandby()
        case "disconnect": container.dashboardViewModel.forceStandby()
        case "dashboard": break  // app mở bình thường
        default:          break
        }
    }
    
}
