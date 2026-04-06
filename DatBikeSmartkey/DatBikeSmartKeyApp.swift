// DatBikeSmartKeyApp.swift — App entry point

import SwiftUI


// MARK: - App

@main
struct DatBikeSmartKeyApp: App {
    
    @StateObject private var container = AppDIContainer()
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(container) // Truyền ngang dọc từ gốc
                .onAppear { }
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
