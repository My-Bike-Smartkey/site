// DatBikeSmartKeyApp.swift — App entry point

import SwiftUI


class AppDelegate: NSObject, UIApplicationDelegate {
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
            if let dispatcher = try? container.bleCore.getDispatcher() {
                Task { try? await dispatcher.toggleLock(currentState: self.container.dashboardViewModel.lockState) }
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
    
}
