// BikeWidgetProvider.swift — TimelineProvider đọc state từ App Group

import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct BikeEntry: TimelineEntry {
    let date: Date
    let state: SharedBikeState
}

// MARK: - Provider

struct BikeWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> BikeEntry {
        BikeEntry(date: .now, state: placeholderState())
    }

    func getSnapshot(in context: Context, completion: @escaping (BikeEntry) -> Void) {
        completion(BikeEntry(date: .now, state: SharedBikeState.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BikeEntry>) -> Void) {
        let state = SharedBikeState.load()
        let entry = BikeEntry(date: .now, state: state)

        // Refresh sau 15 phút, hoặc sớm hơn nếu connected
        let refreshInterval: TimeInterval = state.isConnected ? 5 * 60 : 15 * 60
        let nextUpdate = Date().addingTimeInterval(refreshInterval)

        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    // MARK: - Placeholder

    private func placeholderState() -> SharedBikeState {
        var s = SharedBikeState()
        s.isConnected = true
        s.lockStatusRaw = "locked"
        s.bikeName = "Dat Bike Q S3"
        s.batteryPercent = 85
        s.odometerKm = 1234.5
        s.lastUpdated = .now
        return s
    }
}
