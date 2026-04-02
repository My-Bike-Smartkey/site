// BikeWidgetViews.swift — SwiftUI views cho tất cả widget families

import WidgetKit
import SwiftUI

// MARK: - Design tokens

private let accentOrange = Color(red: 1.0,  green: 0.62, blue: 0.04)
private let accentGreen  = Color(red: 0.20, green: 0.78, blue: 0.35)
private let accentRed    = Color(red: 1.0,  green: 0.27, blue: 0.23)
private let accentBlue   = Color(red: 0.04, green: 0.52, blue: 1.0)
private let textSecondary = Color.secondary

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
    var color: Color { percent <= 20 ? accentRed : percent <= 40 ? accentOrange : accentGreen }
    var icon: String {
        switch percent {
        case ...20:  return "battery.25"
        case ...50:  return "battery.50"
        case ...75:  return "battery.75"
        default:     return "battery.100"
        }
    }
    var body: some View {
        Label("\(percent)%", systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }
}

private struct PhaseBadge: View {
    let phase: String
    var label: String {
        switch phase {
        case "connecting":     return "Đang kết nối"
        case "authenticating": return "Đang xác thực"
        case "ready":          return "Đã kết nối"
        default:               return "Mất kết nối"
        }
    }
    var icon: String {
        switch phase {
        case "connecting":     return "antenna.radiowaves.left.and.right"
        case "authenticating": return "key.fill"
        case "ready":          return "checkmark.circle.fill"
        default:               return "wifi.slash"
        }
    }
    var color: Color {
        switch phase {
        case "ready":      return accentGreen
        case "disconnected": return .secondary
        default:           return accentOrange
        }
    }
    var body: some View {
        Label(label, systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }
}

// MARK: - ── Small Widget ────────────────────────────────────────

struct SmallWidgetView: View {
    let entry: BikeEntry
    private var state: SharedBikeState { entry.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ─ Top bar: bicycle icon + name + connection dot
            HStack(spacing: 4) {
                Image(systemName: "bicycle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(state.bikeName.isEmpty ? "Dat Bike" : state.bikeName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(state.connectionPhase == "ready" ? accentGreen :
                          state.connectionPhase == "disconnected" ? accentRed.opacity(0.7) : accentOrange)
                    .frame(width: 7, height: 7)
            }

            Spacer()

            // ─ Lock icon (centered)
            Image(systemName: state.lockIcon)
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(state.isConnected ? lockColor(state.lockStatusRaw) : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .shadow(color: state.isConnected ? lockColor(state.lockStatusRaw).opacity(0.3) : .clear,
                        radius: 8, x: 0, y: 3)

            Spacer()

            // ─ Status text
            Text(state.isConnected ? state.lockLabel : state.phaseLabel)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)

            // ─ Battery or phase badge
            if state.connectionPhase == "ready" && state.batteryPercent > 0 {
                BatteryView(percent: state.batteryPercent)
                    .padding(.top, 3)
            } else if state.connectionPhase != "ready" {
                PhaseBadge(phase: state.connectionPhase)
                    .padding(.top, 3)
            }
        }
        .padding(14)
        .widgetURL(URL(string: state.isConnected
            ? "mybikesmartkey://dashboard"
            : "mybikesmartkey://connect"))
    }
}

struct BikeSmallWidget: Widget {
    let kind = "BikeSmallWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BikeWidgetProvider()) { entry in
            SmallWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(uiColor: .systemBackground)
                }
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
        HStack(spacing: 14) {

            // ─── LEFT: lock icon + name + status
            VStack(alignment: .leading, spacing: 6) {
                // Lock icon in a rounded background
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(lockColor(state.lockStatusRaw).opacity(state.isConnected ? 0.15 : 0.07))
                        .frame(width: 52, height: 52)
                    Image(systemName: state.lockIcon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(state.isConnected ? lockColor(state.lockStatusRaw) : Color.secondary)
                }

                Text(state.bikeName.isEmpty ? "Dat Bike" : state.bikeName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(state.isConnected ? state.lockLabel : "—")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.primary)

                Spacer()

                PhaseBadge(phase: state.connectionPhase)
            }

            Divider().padding(.vertical, 6)

            // ─── RIGHT: battery + odometer + action buttons
            VStack(alignment: .leading, spacing: 0) {

                // Stats row
                HStack(alignment: .top) {
                    if state.batteryPercent > 0 {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pin")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            BatteryView(percent: state.batteryPercent)
                        }
                    }

                    Spacer()

                    if state.odometerKm > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Odometer")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.0f km", state.odometerKm))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                }

                Spacer()

                // Action buttons
                if state.isConnected {
                    HStack(spacing: 8) {
                        if state.lockStatusRaw == "unlocked" {
                            Button(intent: LockBikeIntent()) {
                                Label("Khoá xe", systemImage: "lock.fill")
                                    .font(.caption2.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(accentOrange.opacity(0.18),
                                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .foregroundStyle(accentOrange)
                            }
                            .buttonStyle(.plain)
                            .disabled(state.connectionPhase != "ready")
                        } else {
                            Button(intent: UnlockBikeIntent()) {
                                Label("Mở khoá", systemImage: "lock.open.fill")
                                    .font(.caption2.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(accentGreen.opacity(0.18),
                                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .foregroundStyle(accentGreen)
                            }
                            .buttonStyle(.plain)
                            .disabled(state.connectionPhase != "ready")
                        }

                        Button(intent: FindBikeIntent()) {
                            Label("Tìm xe", systemImage: "location.fill")
                                .font(.caption2.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(accentBlue.opacity(0.18),
                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .foregroundStyle(accentBlue)
                        }
                        .buttonStyle(.plain)
                        .disabled(state.connectionPhase != "ready")
                    }
                } else {
                    Button(intent: ConnectBikeIntent()) {
                        Label("Kết nối xe", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption2.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(accentBlue.opacity(0.18),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .foregroundStyle(accentBlue)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
    }
}

struct BikeMediumWidget: Widget {
    let kind = "BikeMediumWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BikeWidgetProvider()) { entry in
            MediumWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(uiColor: .systemBackground)
                }
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
