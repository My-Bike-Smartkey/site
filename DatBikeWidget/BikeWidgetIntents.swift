// BikeWidgetIntents.swift — AppIntent cho iOS 17 Interactive Widget

import AppIntents
import WidgetKit

// MARK: - Lock Intent

struct LockBikeIntent: AppIntent {
    static var title: LocalizedStringResource = "Khoá xe"
    static var description = IntentDescription("Khoá xe Dat Bike")

    // Mở app để thực hiện BLE command
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Deep link tới app để thực hiện BLE lock
        // App sẽ bắt onOpenURL("datbike://lock") và gọi ble.lock()
        return .result()
    }
}

// MARK: - Unlock Intent

struct UnlockBikeIntent: AppIntent {
    static var title: LocalizedStringResource = "Mở khoá xe"
    static var description = IntentDescription("Mở khoá xe Dat Bike")

    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        return .result()
    }
}

// MARK: - Find Bike Intent

struct FindBikeIntent: AppIntent {
    static var title: LocalizedStringResource = "Tìm xe"
    static var description = IntentDescription("Bật còi tìm xe Dat Bike")

    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        return .result()
    }
}
