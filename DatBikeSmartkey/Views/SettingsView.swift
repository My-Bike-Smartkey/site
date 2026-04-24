// SettingsView.swift — Settings, device info, auto-unlock config, and debug log

import SwiftUI
import CoreImage.CIFilterBuiltins

struct SettingsView: View {
    @EnvironmentObject var container: AppDIContainer
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showLogs = false
    @State private var showBatteryAnalytics = false
    @State private var showForgetConfirm = false
    @State private var showConnectionGuide = false
    @State private var showInfoAutoConnect = false
    @State private var showInfoBgReconnect = false
    @State private var showInfoAutoUnlock = false
    
    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.08)
                .ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    // Header
                    HStack {
                        Text("Cài đặt")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.horizontal)
                    
                    
                    // Device info section
                    if viewModel.isConnected && !viewModel.bikeInfo.isEmpty {
                        settingsSection(title: "THÔNG TIN XE") {
                            VStack(spacing: 0) {
                                settingsButton(icon: "battery.100.bolt", iconColor: .green, title: "Phân tích Pin (BMS)") {
                                    showBatteryAnalytics = true
                                }
                                Divider().background(Color.white.opacity(0.06))
                                settingsRow(icon: "bicycle", iconColor: .cyan,
                                            title: "Tên", value: viewModel.bikeInfo.name)
                                Divider().background(Color.white.opacity(0.06))
                                settingsRow(icon: "cpu", iconColor: .cyan,
                                            title: "Model", value: viewModel.bikeInfo.model)
                                Divider().background(Color.white.opacity(0.06))
                                settingsRow(icon: "number", iconColor: .cyan,
                                            title: "Số khung", value: viewModel.bikeInfo.serial)
                                if !viewModel.bikeInfo.firmware.isEmpty {
                                    Divider().background(Color.white.opacity(0.06))
                                    settingsRow(icon: "gearshape.fill", iconColor: .cyan,
                                                title: "Firmware", value: viewModel.bikeInfo.firmware)
                                }
                                if !viewModel.bikeInfo.deviceToken.isEmpty {
                                    Divider().background(Color.white.opacity(0.06))
                                    settingsRow(icon: "key", iconColor: .cyan,
                                                title: "Token", value: String(viewModel.bikeInfo.deviceToken.prefix(16)) + "…")
                                }
                            }
                        }
                    }
                    
                    // Security section
                    settingsSection(title: "BẢO MẬT") {
                        VStack(spacing: 0) {
                            Toggle(isOn: $viewModel.connectOnlyWhenNear) {
                                HStack(spacing: 12) {
                                    Image(systemName: "sensor.tag.radiowaves.forward")
                                        .font(.system(size: 16))
                                        .foregroundColor(.green)
                                        .frame(width: 28, height: 28)
                                        .background(Color.green.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Ngưỡng tự động kết nối với xe")
                                            .font(.subheadline)
                                            .foregroundColor(.white)
                                        Text("Khi đạt ngưỡng này điện thoại sẽ tự động kết nối, biểu tượng bluetooth trên đồng hồ xe sẽ sáng.")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, viewModel.connectOnlyWhenNear ? 4 : 10)
                            
                            if viewModel.connectOnlyWhenNear {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("Độ nhạy: ")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                        + Text("\(Int(viewModel.rssiThreshold)) dBm")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.white)
                                        Spacer()
                                        Text(viewModel.rssiThreshold >= -65 ? "Gần" : (viewModel.rssiThreshold >= -75 ? "Vừa" : "Xa"))
                                            .font(.caption2)
                                            .foregroundColor(viewModel.rssiThreshold >= -65 ? .green : (viewModel.rssiThreshold >= -75 ? .orange : .red))
                                    }
                                    Slider(value: $viewModel.rssiThreshold, in: -95...(-50), step: 1.0)
                                        .tint(.green)
                                }
                                .padding(.horizontal, 14)
                                .padding(.bottom, 14)
                            }
                            Divider().background(Color.white.opacity(0.06))
                            
                            // NEW: Tự động bật xe
                            Toggle(isOn: $viewModel.autoUnlockEnabled) {
                                HStack(spacing: 12) {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.orange)
                                        .frame(width: 28, height: 28)
                                        .background(Color.orange.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Ngưỡng tự động bật xe")
                                            .font(.subheadline)
                                            .foregroundColor(.white)
                                        Text("Khi đã kết nối, nếu đạt ngưỡng này và xe đang tắt thì tự động bật lên.")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, viewModel.autoUnlockEnabled ? 4 : 10)
                            
                            if viewModel.autoUnlockEnabled {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("Độ nhạy: ")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                        + Text("\(Int(viewModel.autoTurnOnThreshold)) dBm")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.white)
                                        Spacer()
                                        Text(viewModel.autoTurnOnThreshold >= -60 ? "Gần" : (viewModel.autoTurnOnThreshold >= -70 ? "Vừa" : "Xa"))
                                            .font(.caption2)
                                            .foregroundColor(viewModel.autoTurnOnThreshold >= -60 ? .green : (viewModel.autoTurnOnThreshold >= -70 ? .orange : .red))
                                    }
                                    Slider(value: $viewModel.autoTurnOnThreshold, in: -90...(-40), step: 1.0)
                                        .tint(.orange)
                                }
                                .padding(.horizontal, 14)
                                .padding(.bottom, 14)
                            }
                            Divider().background(Color.white.opacity(0.06))
                            
                            settingsButton(icon: "trash.fill", iconColor: .red, title: "Bỏ liên kết xe") {
                                showForgetConfirm = true
                            }
                        }
                    }
                    
                    // App preferences section
                    settingsSection(title: "ỨNG DỤNG") {
                        VStack(spacing: 0) {
                            Toggle(isOn: $viewModel.notificationsEnabled) {
                                HStack(spacing: 12) {
                                    Image(systemName: "bell.badge.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.orange)
                                        .frame(width: 28, height: 28)
                                        .background(Color.orange.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Thông báo hệ thống")
                                            .font(.subheadline)
                                            .foregroundColor(.white)
                                        Text("Bật/tắt toàn bộ thông báo của app")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                }
                            }
                            .tint(.orange)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            
                            // Granular toggles — chỉ hiển thị khi master bật
                            if viewModel.notificationsEnabled {
                                Divider().background(Color.white.opacity(0.06))
                                
                                // Sub-header
                                HStack {
                                    Text("LOẠI THÔNG BÁO")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.gray.opacity(0.6))
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                                
                                notificationSubToggle(
                                    icon: "checkmark.circle.fill",
                                    iconColor: .green,
                                    title: "Kết nối thành công",
                                    subtitle: "Khi xác thực BLE hoàn tất",
                                    binding: $viewModel.notifyOnConnected
                                )
                                
                                Divider().background(Color.white.opacity(0.04)).padding(.leading, 52)
                                
                                notificationSubToggle(
                                    icon: "figure.walk",
                                    iconColor: .cyan,
                                    title: "Gần xe — Kết nối chờ",
                                    subtitle: "Khi phát hiện di chuyển gần xe",
                                    binding: $viewModel.notifyOnStandby
                                )
                                
                                Divider().background(Color.white.opacity(0.04)).padding(.leading, 52)
                                
                                notificationSubToggle(
                                    icon: "arrow.uturn.backward.circle.fill",
                                    iconColor: .yellow,
                                    title: "Ra xa xe — Chuyển chờ",
                                    subtitle: "Khi phát hiện di chuyển ra xa",
                                    binding: $viewModel.notifyOnDisconnected
                                )
                                
                                Divider().background(Color.white.opacity(0.04)).padding(.leading, 52)
                                
                                notificationSubToggle(
                                    icon: "bolt.fill",
                                    iconColor: .orange,
                                    title: "Tự động bật xe",
                                    subtitle: "Khi Auto Turn-On được kích hoạt",
                                    binding: $viewModel.notifyOnAutoTurnOn
                                )
                                
                                Divider().background(Color.white.opacity(0.04)).padding(.leading, 52)
                                
                                notificationSubToggle(
                                    icon: "battery.100.bolt",
                                    iconColor: .green,
                                    title: "Sạc đầy pin",
                                    subtitle: "Khi pin đạt 100%",
                                    binding: $viewModel.notifyOnBatteryFull
                                )
                                
                                Divider().background(Color.white.opacity(0.04)).padding(.leading, 52)
                                
                                notificationSubToggle(
                                    icon: "bolt.slash.fill",
                                    iconColor: .red,
                                    title: "Ngắt sạc bất ngờ",
                                    subtitle: "Báo động khi mất sạc lúc xe tắt",
                                    binding: $viewModel.notifyOnChargeDisconnect
                                )
                                
                                Divider().background(Color.white.opacity(0.04)).padding(.leading, 52)
                                
                                notificationSubToggle(
                                    icon: "battery.25",
                                    iconColor: .orange,
                                    title: "Cảnh báo pin yếu",
                                    subtitle: "Khi pin giảm xuống dưới ngưỡng",
                                    binding: $viewModel.notifyOnBatteryThreshold
                                )
                                
                                if viewModel.notifyOnBatteryThreshold {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("Ngưỡng cảnh báo: ")
                                                .font(.caption2)
                                                .foregroundColor(.gray)
                                            + Text("\(Int(viewModel.batteryLowThreshold))%")
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundColor(.white)
                                            Spacer()
                                        }
                                        Slider(value: $viewModel.batteryLowThreshold, in: 5...50, step: 1.0)
                                            .tint(.orange)
                                    }
                                    .padding(.leading, 52)
                                    .padding(.trailing, 14)
                                    .padding(.bottom, 8)
                                    .animation(.easeInOut, value: viewModel.notifyOnBatteryThreshold)
                                }
                                
                                Spacer().frame(height: 6)
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: viewModel.notificationsEnabled)
                    }

                    
                    // Documentation section
                    settingsSection(title: "TRỢ GIÚP") {
                        VStack(spacing: 0) {
                            settingsButton(icon: "book.pages.fill", iconColor: .blue, title: "Nguyên lý kết nối & Trạng thái") {
                                showConnectionGuide = true
                            }
                        }
                    }
                    
                    // Logs section
                    settingsSection(title: "NHẬT KÝ") {
                        VStack(spacing: 0) {
                            settingsButton(icon: "list.bullet.rectangle.portrait", iconColor: .blue, title: "Xem nhật ký đầy đủ (Full Logs)") {
                                showLogs = true
                            }
                        }
                    }
                    
                    // Time Sync section
                    settingsSection(title: "ĐỒNG BỘ GIỜ XE") {
                        VStack(spacing: 0) {
                            // Current device time display
                            HStack {
                                HStack(spacing: 10) {
                                    Image(systemName: "clock.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.blue)
                                        .frame(width: 28, height: 28)
                                        .background(Color.blue.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Giờ điện thoại (UTC+7)")
                                            .font(.subheadline)
                                            .foregroundColor(.white)
                                        LiveTimeText()
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            
                            Divider().background(Color.white.opacity(0.06))
                            
                            // Sync Now button
                            Button {
                                viewModel.syncTime()
                            } label: {
                                HStack {
                                    HStack(spacing: 10) {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.system(size: 12))
                                            .foregroundColor(.blue)
                                            .frame(width: 28, height: 28)
                                            .background(Color.blue.opacity(0.15))
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                        Text(viewModel.isSyncingTime ? "Đang đồng bộ..." : "Đồng bộ ngay")
                                            .font(.subheadline)
                                            .foregroundColor(viewModel.isConnected ? .white : .gray)
                                    }
                                    Spacer()
                                    if viewModel.isSyncingTime {
                                        ProgressView()
                                            .tint(.blue)
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                            }
                            .disabled(!viewModel.isConnected || viewModel.isSyncingTime)
                        }
                    }
                    
                    settingsSection(title: "WIDGET & HOẠT ĐỘNG NGẦM") {
                        Toggle(isOn: $viewModel.widgetAndLiveActivityEnabled) {
                            HStack(spacing: 12) {
                                Image(systemName: "bolt.badge.clock.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(.yellow)
                                    .frame(width: 28, height: 28)
                                    .background(Color.yellow.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text("Bật Widget & Live Activity")
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                            }
                        }
                        .tint(Color(red: 0.0, green: 0.96, blue: 1.0))
                    }
                    
                    settingsSection(title: "GỠ LỖI (NÂNG CAO)") {
                        VStack(spacing: 0) {
                            Toggle(isOn: $viewModel.isDebugModeEnabled) {
                                HStack(spacing: 12) {
                                    Image(systemName: "terminal.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.purple)
                                        .frame(width: 28, height: 28)
                                        .background(Color.purple.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text("Bật Nhật Ký BLE (Logs)")
                                        .font(.subheadline)
                                        .foregroundColor(.white)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            
                            Divider().background(Color.white.opacity(0.06))
                            
                            Toggle(isOn: $viewModel.skipProximityToken) {
                                HStack(spacing: 12) {
                                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                        .font(.system(size: 16))
                                        .foregroundColor(.orange)
                                        .frame(width: 28, height: 28)
                                        .background(Color.orange.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Bỏ qua Proximity Token")
                                            .font(.subheadline)
                                            .foregroundColor(.white)
                                        Text("Không gửi token lân cận khi xác thực (dùng khi test ASK)")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                }
                            }
                            .tint(.orange)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                    
                    // Donate section
                    settingsSection(title: "ỦNG HỘ DỰ ÁN") {
                        VStack(spacing: 12) {
                            Text("Nếu app hữu ích, bạn có thể ủng hộ tác giả 🙏")
                                .font(.caption)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                                .padding(.top, 12)
                            
                            QRCodeView(content: "00020101021138630010A000000727013300069710250119PSP26089156000002310208QRIBFTTA53037045802VN62190515MOMOW2W3637058263049C27", size: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                            
                            VStack(spacing: 2) {
                                Text("NGUYỄN PHÚC TÚ")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                Text("*******135")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                HStack(spacing: 6) {
                                    Text("MoMo")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .foregroundColor(Color(red: 0.87, green: 0.18, blue: 0.49))
                                    Text("•")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                    Text("VietQR")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .foregroundColor(Color(red: 0.87, green: 0.10, blue: 0.14))
                                    Text("•")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                    Text("Napas 247")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .foregroundColor(Color(red: 0.10, green: 0.65, blue: 0.25))
                                }
                            }
                            .padding(.bottom, 12)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    
                    // App info
                    VStack(spacing: 4) {
                        Text("D-SmartKey v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("Sản phẩm được tạo bởi tình yêu dành cho chiếc xe Datbike của tôi")
                            .font(.caption2)
                            .foregroundColor(.gray.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
                .padding(.top, 8)
            }
        }
        .sheet(isPresented: $showLogs) {
            LogView(logs: PersistentLogger.shared.loadLogs(daysBack: 1))
        }
        .sheet(isPresented: $showConnectionGuide) {
            ConnectionGuideView()
        }
        .sheet(isPresented: $showBatteryAnalytics) {
            BatteryAnalyticsView(viewModel: container.batteryViewModel)
        }
        .alert("Bỏ liên kết xe", isPresented: $showForgetConfirm) {
            Button("Quên", role: .destructive) {
                viewModel.forgetBike()
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Xóa kết nối App với xe. Bạn có muốn tiếp tục?")
        }
    }
    
    // MARK: - Section Builder
    
    private func rssiColor(_ rssi: Int) -> Color {
        switch rssi {
        case ..<(-80): return .red
        case -80 ..< -65: return .orange
        default: return .green
        }
    }
    
    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.gray)
                .padding(.horizontal, 20)
            
            content()
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                        )
                )
                .padding(.horizontal)
        }
    }
    
    private func settingsRow(icon: String, iconColor: Color, title: String, value: String) -> some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(iconColor)
                    .frame(width: 28, height: 28)
                    .background(iconColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.white)
            }
            
            Spacer()
            
            Text(value)
                .font(.subheadline)
                .foregroundColor(.gray)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
    
    private func settingsButton(icon: String, iconColor: Color, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(iconColor)
                        .frame(width: 28, height: 28)
                        .background(iconColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
    
    private func notificationSubToggle(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        binding: Binding<Bool>
    ) -> some View {
        Toggle(isOn: binding) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(iconColor)
                    .frame(width: 24, height: 24)
                    .background(iconColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
        }
        .tint(iconColor)
        .padding(.leading, 24)  // indent so sánh với master toggle
        .padding(.trailing, 14)
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private func infoPopover(title: String, icon: String, iconColor: Color, body: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(iconColor)
                    .frame(width: 36, height: 36)
                    .background(iconColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
            }
            Text(body)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(minWidth: 280, maxWidth: 340)
    }
    
    
    // MARK: - QR Code Generator
    
    struct QRCodeView: View {
        let content: String
        let size: CGFloat
        @State private var cachedImage: UIImage?
        
        var body: some View {
            Group {
                if let image = cachedImage {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                } else {
                    Color.white.frame(width: size, height: size)
                        .overlay(ProgressView())
                }
            }
            .onAppear {
                Task {
                    if cachedImage == nil {
                        cachedImage = generateQRCode(from: content)
                    }
                }
            }
        }
        
        private func generateQRCode(from string: String) -> UIImage? {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(string.utf8)
            filter.correctionLevel = "M"
            guard let ciImage = filter.outputImage else { return nil }
            let scale = size / ciImage.extent.width
            let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            // White QR on white background — invert for dark mode friendliness
            guard let inverted = CIFilter(name: "CIColorInvert", parameters: [kCIInputImageKey: scaled])?.outputImage,
                  CIFilter(name: "CIMaskToAlpha", parameters: [kCIInputImageKey: inverted])?.outputImage != nil else {
                let context = CIContext()
                if let cgImage = context.createCGImage(scaled, from: scaled.extent) {
                    return UIImage(cgImage: cgImage)
                }
                return nil
            }
            // Compose: black QR on white background
            let bg = CIImage(color: CIColor.white).cropped(to: scaled.extent)
            guard let composed = CIFilter(name: "CISourceOverCompositing",
                                          parameters: [kCIInputImageKey: scaled,
                                             kCIInputBackgroundImageKey: bg])?.outputImage else { return nil }
            let context = CIContext()
            guard let cgImage = context.createCGImage(composed, from: composed.extent) else { return nil }
            return UIImage(cgImage: cgImage)
        }
    }
    
    // MARK: - Log View
    
    struct LogView: View {
        @State var logs: [BLELogEntry]
        @Environment(\.dismiss) private var dismiss
        @State private var showClearConfirm = false
        @State private var showShareSheet = false
        @State private var shareURL: URL? = nil
        
        init(logs: [BLELogEntry]) {
            self._logs = State(initialValue: logs)
        }
        
        /// Danh sách keyword nhạy cảm — log chứa keyword này sẽ bị ẩn
        private static let sensitiveKeywords = [
            "SHA", "hash", "PIN", "pin", "auth", "Auth",
            "challenge", "counter", "nonce", "token", "Token",
            "session", "proximity", "Xác thực", "xác thực",
            "NOTIFY", "serviceChanged"
        ]
        
        /// Hiển thị toàn bộ nhật ký theo yêu cầu
        private var filteredLogs: [BLELogEntry] {
            return logs
        }
        
        var body: some View {
            NavigationView {
                ZStack {
                    Color(red: 0.04, green: 0.04, blue: 0.08)
                        .ignoresSafeArea()
                    
                    if filteredLogs.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundColor(.gray)
                            Text("Chưa có log")
                                .foregroundColor(.gray)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(filteredLogs.reversed()) { entry in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text(entry.formattedTime)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.gray)
                                        
                                        Text(entry.level.rawValue)
                                            .font(.system(size: 10))
                                        
                                        Text(entry.message)
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.85))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 3)
                                    .contextMenu {
                                        Button {
                                            UIPasteboard.general.string = "[\(entry.formattedTime)] \(entry.level.rawValue) \(entry.message)"
                                        } label: {
                                            Label("Copy", systemImage: "doc.on.doc")
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
                .navigationTitle("BLE Log")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarLeading) {
                        Button {
                            let fullString = filteredLogs.reversed().map { "[\($0.formattedTime)] \($0.level.rawValue) \($0.message)" }.joined(separator: "\n")
                            UIPasteboard.general.string = fullString
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        
                        Button {
                            let text = PersistentLogger.shared.exportAllAsText()
                            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("datbike_ble_logs.txt")
                            try? text.write(to: tempFile, atomically: true, encoding: .utf8)
                            shareURL = tempFile
                            showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button {
                            showClearConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        
                        Button("Đóng") { dismiss() }
                            .foregroundColor(.blue)
                    }
                }
                .alert("Xóa toàn bộ Log?", isPresented: $showClearConfirm) {
                    Button("Xóa", role: .destructive) {
                        PersistentLogger.shared.clearAll()
                        logs.removeAll()
                    }
                    Button("Hủy", role: .cancel) {}
                } message: {
                    Text("Hành động này sẽ xóa vĩnh viễn toàn bộ lịch sử kết nối lưu trên máy.")
                }
                .background(
                    ActivityViewPresenter(isPresented: $showShareSheet, activityItems: [shareURL].compactMap { $0 })
                )
            }
            .navigationViewStyle(.stack)
            .preferredColorScheme(.dark)
        }
    }
    
    struct ActivityViewPresenter: UIViewControllerRepresentable {
        @Binding var isPresented: Bool
        var activityItems: [Any]
        
        func makeUIViewController(context: Context) -> UIViewController {
            let vc = UIViewController()
            vc.view.backgroundColor = .clear
            return vc
        }
        
        func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
            let isActivityShown = uiViewController.presentedViewController is UIActivityViewController
            
            if isPresented && !isActivityShown {
                let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
                controller.completionWithItemsHandler = { _, _, _, _ in
                    self.isPresented = false
                }
                
                if let popover = controller.popoverPresentationController {
                    popover.sourceView = uiViewController.view
                    popover.sourceRect = CGRect(x: uiViewController.view.bounds.midX, y: uiViewController.view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
                
                uiViewController.present(controller, animated: true)
            }
        }
    }
    
    // MARK: - Live Time Text
    struct LiveTimeText: View {
        @State private var currentTime = Date()
        
        var body: some View {
            Text(currentVNTimeString(currentTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.gray)
                .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { input in
                    currentTime = input
                }
        }
        
        private func currentVNTimeString(_ date: Date) -> String {
            let vnTZ = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
            let formatter = DateFormatter()
            formatter.timeZone = vnTZ
            formatter.dateFormat = "HH:mm:ss (dd/MM/yyyy)"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Connection Guide View
struct ConnectionGuideView: View {
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.1, green: 0.1, blue: 0.12).ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Hiểu về kết nối D-SmartKey")
                            .font(.title2).bold()
                            .foregroundColor(.white)
                        
                        guideSection(
                            icon: "magnifyingglass", iconColor: .blue,
                            title: "1. Đang tìm xe",
                            content: "Điện thoại đang liên tục quét các sóng Bluetooth Low Energy (BLE) xung quanh để phát hiện xe Dat Bike của bạn. Trạng thái này thường mất từ 1-3 giây mỗi khi mở app."
                        )
                        
                        guideSection(
                            icon: "point.3.connected.trianglepath.dotted", iconColor: .orange,
                            title: "2. Đang kết nối & Xác thực",
                            content: "Ứng dụng đã tìm thấy sóng của xe và tiến hành thiết lập liên kết an toàn."
                        )
                        
                        guideSection(
                            icon: "sensor.tag.radiowaves.forward", iconColor: .green,
                            title: "3. Ngưỡng tự động kết nối",
                            content: "Mặc định, khi xe phát hiện bạn trong phạm vi phát sóng đủ lớn của 'Ngưỡng kết nối', biểu tượng Bluetooth trên mặt đồng hồ xe sẽ sáng nháp báo hiệu sự kết nối vật lý đã sẵn sàng. Bạn càng kéo thanh này về phía 'Xa' (như -80), xe sẽ bắt sóng bạn càng sớm."
                        )
                        
                        guideSection(
                            icon: "bolt.fill", iconColor: .yellow,
                            title: "4. Ngưỡng tự động bật xe",
                            content: "Nếu bạn đã bật tính năng này, sau khi kết nối, hệ thống sẽ tiếp tục đợi. Chỉ khi bạn tiến lại đủ gần chạm trúng vào 'Ngưỡng bật xe' (như -60), ứng dụng mới xuất lệnh đánh thức và BẬT HỆ THỐNG ĐIỆN của xe hoàn toàn."
                        )
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Mẹo thiết lập")
                                .font(.headline).foregroundColor(.white)
                            Text("• Luôn giữ Ngưỡng bật xe ĐẬM (Gần) hơn Ngưỡng kết nối để tránh việc xe tự bật sáng khi bạn chỉ đang lướt ngang qua sân nhà.")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(12)
                    }
                    .padding()
                    .padding(.top, 10)
                }
            }
            .navigationTitle("Trợ giúp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { presentationMode.wrappedValue.dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private func guideSection(icon: String, iconColor: Color, title: String, content: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(iconColor)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(content)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .lineSpacing(2)
            }
        }
    }
}
