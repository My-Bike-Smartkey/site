// SharedBikeState.swift
// Shared between Main App and Widget Extension via App Group UserDefaults.
// Both targets must have the App Group entitlement: group.app.mybike.smartkey

import Foundation

// MARK: - App Group ID

let appGroupID = "group.app.mybike.smartkey"

// MARK: - Shared State

struct SharedBikeState: Codable {
    var isConnected: Bool = false
    var lockStatusRaw: String = "unknown"   // "locked", "unlocked", "armed", "unknown"
    var bikeName: String = ""
    var batteryPercent: Int = 0
    var odometerKm: Float = 0
    var lastUpdated: Date = .distantPast

    // MARK: Persistence

    static func load() -> SharedBikeState {
        guard
            let defaults = UserDefaults(suiteName: appGroupID),
            let data = defaults.data(forKey: "sharedBikeState"),
            let state = try? JSONDecoder().decode(SharedBikeState.self, from: data)
        else {
            return SharedBikeState()
        }
        return state
    }

    func save() {
        guard
            let defaults = UserDefaults(suiteName: appGroupID),
            let data = try? JSONEncoder().encode(self)
        else { return }
        defaults.set(data, forKey: "sharedBikeState")
    }

    // MARK: Computed

    var lockIcon: String {
        switch lockStatusRaw {
        case "unlocked": return "lock.open.fill"
        case "armed":    return "lock.shield.fill"
        default:         return "lock.fill"
        }
    }

    var lockLabel: String {
        switch lockStatusRaw {
        case "unlocked": return "Đang chạy"
        case "armed":    return "Chống trộm"
        default:         return "Đã khoá"
        }
    }

    var isStale: Bool {
        Date().timeIntervalSince(lastUpdated) > 300 // 5 phút
    }
}
