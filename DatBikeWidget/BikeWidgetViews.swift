// BikeWidgetViews.swift — SwiftUI views cho tất cả widget families

import WidgetKit
import SwiftUI

// MARK: - Colors (matching main app dark theme)

private let bgColor     = Color(red: 0.06, green: 0.06, blue: 0.10)  // #0F0F1A
private let cardColor   = Color(red: 0.13, green: 0.13, blue: 0.20)  // #212233
private let accentOrange = Color(red: 1.0, green: 0.62, blue: 0.04)  // #FF9E0A
private let accentGreen  = Color(red: 0.20, green: 0.78, blue: 0.35) // #34C759
private let accentRed    = Color(red: 1.0,  green: 0.27, blue: 0.23) // #FF453A
private let accentBlue   = Color(red: 0.04, green: 0.52, blue: 1.0)  // #0A84FF
private let textSecondary = Color.white.opacity(0.5)

// MARK: - Shared subviews

private func lockColor(_ raw: String) -> Color {
    switch raw {
    case "unlocked": return accentGreen
    case "armed":    return accentOrange
    default:         return accentRed
    }
}

private struct BatteryView: View {
    let percent: Int
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: percent > 20 ? "battery.75" : "battery.25")
                .font(.caption2)
                .foregroundStyle(percent > 20 ? accentGreen : accentRed)
            Text("\(percent)%")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.8))
        }
    }
}

private struct ConnectionDot: View {
    let isConnected: Bool
    var body: some View {
        Circle()
            .fill(isConnected ? accentGreen : accentRed)
            .frame(width: 7, height: 7)
    }
}

// MARK: - ── Small Widget ────────────────────────────────────────

struct SmallWidgetView: View {
    let entry: BikeEntry
    private var state: SharedBikeState { entry.state }

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.06, blue: 0.12),
                         Color(red: 0.10, green: 0.08, blue: 0.18)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 0) {
                // Top row: bike name + connection dot
                HStack {
                    Text(state.bikeName.isEmpty ? "Dat Bike" : state.bikeName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(textSecondary)
                        .lineLimit(1)
                    Spacer()
                    ConnectionDot(isConnected: state.isConnected)
                }

                Spacer()

                // Lock icon — big, centered
                Image(systemName: state.lockIcon)
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(lockColor(state.lockStatusRaw))
                    .shadow(color: lockColor(state.lockStatusRaw).opacity(0.5), radius: 12)

                Spacer()

                // Lock label
                Text(state.isConnected ? state.lockLabel : state.phaseLabel)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)

                // Auth / battery status
                if state.connectionPhase == "ready" && state.batteryPercent > 0 {
                    BatteryView(percent: state.batteryPercent)
                        .padding(.top, 2)
                } else if state.connectionPhase == "authenticating" || state.connectionPhase == "connecting" {
                    HStack(spacing: 3) {
                        Image(systemName: state.phaseIcon)
                            .font(.caption2)
                            .foregroundStyle(accentOrange)
                        Text(state.phaseLabel)
                            .font(.caption2)
                            .foregroundStyle(accentOrange)
                    }
                    .padding(.top, 2)
                } else if !state.isConnected {
                    Text(state.isStale ? "Nhấn để kết nối" : "Mất kết nối")
                        .font(.caption2)
                        .foregroundStyle(textSecondary)
                        .padding(.top, 2)
                }
            }
            .padding(14)
        }
        .widgetURL(URL(string: "mybikesmartkey://dashboard"))
    }
}

struct BikeSmallWidget: Widget {
    let kind = "BikeSmallWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BikeWidgetProvider()) { entry in
            SmallWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Dat Bike — Trạng thái")
        .description("Xem nhanh trạng thái khoá và pin xe.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - ── Medium Widget ──────────────────────────────────────

struct MediumWidgetView: View {
    let entry: BikeEntry
    private var state: SharedBikeState { entry.state }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.06, blue: 0.12),
                         Color(red: 0.10, green: 0.08, blue: 0.18)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            VStack(spacing: 10) {
                // ── Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.bikeName.isEmpty ? "Dat Bike" : state.bikeName)
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.white)
                        HStack(spacing: 4) {
                            Image(systemName: state.phaseIcon)
                                .font(.system(size: 9))
                                .foregroundStyle(state.connectionPhase == "ready" ? accentGreen :
                                                 state.connectionPhase == "disconnected" ? textSecondary : accentOrange)
                            Text(state.phaseLabel)
                                .font(.caption2)
                                .foregroundStyle(state.connectionPhase == "ready" ? accentGreen :
                                                 state.connectionPhase == "disconnected" ? textSecondary : accentOrange)
                        }
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        if state.connectionPhase == "ready" && state.batteryPercent > 0 {
                            BatteryView(percent: state.batteryPercent)
                        }
                        ConnectionDot(isConnected: state.isConnected)
                    }
                }

                // ── Status row
                HStack(spacing: 16) {
                    // Lock status chip
                    HStack(spacing: 6) {
                        Image(systemName: state.lockIcon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(lockColor(state.lockStatusRaw))
                        Text(state.lockLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(lockColor(state.lockStatusRaw).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                    Spacer()

                    // Odometer
                    if state.isConnected && state.odometerKm > 0 {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(String(format: "%.0f km", state.odometerKm))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("Odometer")
                                .font(.caption2)
                                .foregroundStyle(textSecondary)
                        }
                    }
                }

                // ── Action buttons (iOS 17 Interactive)
                if state.isConnected {
                    HStack(spacing: 10) {
                        // Khoá / Mở khoá
                        if state.lockStatusRaw == "unlocked" {
                            Button(intent: LockBikeIntent()) {
                                Label("Khoá xe", systemImage: "lock.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(accentOrange.opacity(0.85), in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                            .disabled(state.connectionPhase != "ready")
                        } else {
                            Button(intent: UnlockBikeIntent()) {
                                Label("Mở khoá", systemImage: "lock.open.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(accentGreen.opacity(0.85), in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                            .disabled(state.connectionPhase != "ready")
                        }

                        // Tìm xe
                        Button(intent: FindBikeIntent()) {
                            Label("Tìm xe", systemImage: "speaker.wave.2.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(accentBlue.opacity(0.85), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .disabled(state.connectionPhase != "ready")
                    }
                } else {
                    // Không kết nối — hiện nút Kết nối
                    Button(intent: ConnectBikeIntent()) {
                        Label("Kết nối xe", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(accentBlue.opacity(0.85), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
    }
}

struct BikeMediumWidget: Widget {
    let kind = "BikeMediumWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BikeWidgetProvider()) { entry in
            MediumWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Dat Bike — Điều khiển")
        .description("Khoá / mở khoá và tìm xe trực tiếp từ màn hình chính.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - ── Lock Screen Widget ─────────────────────────────────

struct LockScreenCircleView: View {
    let entry: BikeEntry
    var body: some View {
        ZStack {
            Image(systemName: entry.state.lockIcon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(lockColor(entry.state.lockStatusRaw))
        }
        .widgetURL(URL(string: "mybikesmartkey://dashboard"))
    }
}

struct LockScreenRectView: View {
    let entry: BikeEntry
    private var state: SharedBikeState { entry.state }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.lockIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(lockColor(state.lockStatusRaw))
            VStack(alignment: .leading, spacing: 1) {
                Text(state.lockLabel)
                    .font(.caption.weight(.bold))
                Text(state.isConnected ? "Dat Bike" : "Mất kết nối")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.isConnected && state.batteryPercent > 0 {
                Text("\(state.batteryPercent)%")
                    .font(.caption2.weight(.medium))
            }
        }
        .widgetURL(URL(string: "mybikesmartkey://dashboard"))
    }
}

struct BikeLockScreenWidget: Widget {
    let kind = "BikeLockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BikeWidgetProvider()) { entry in
            Group {
                if #available(iOS 17.0, *) {
                    LockScreenRectView(entry: entry)
                        .containerBackground(.clear, for: .widget)
                } else {
                    LockScreenCircleView(entry: entry)
                }
            }
        }
        .configurationDisplayName("Dat Bike — Lock Screen")
        .description("Trạng thái xe trên màn hình khoá.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}
