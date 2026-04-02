// SettingsView.swift — Settings, device info, auto-unlock config, and debug log

import SwiftUI
import CoreImage.CIFilterBuiltins

struct SettingsView: View {
    @ObservedObject var viewModel: SmartKeyViewModel
    @State private var showLogs = false
    @State private var showForgetConfirm = false
    @State private var showTestPanel = false
    @State private var showInfoAutoConnect = false
    @State private var showInfoBgReconnect = false
    @State private var showInfoAutoUnlock = false
    
    @State private var currentTime = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
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
                    
                    // Auto-connect section
                    settingsSection(title: "TỰ ĐỘNG KẾT NỐI") {
                        VStack(spacing: 0) {
                            HStack {
                                    HStack(spacing: 10) {
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                            .font(.system(size: 14))
                                            .foregroundColor(.blue)
                                            .frame(width: 28, height: 28)
                                            .background(Color.blue.opacity(0.15))
                                            .clipShape(RoundedRectangle(cornerRadius: 6))

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Tự động kết nối lại")
                                                .font(.subheadline)
                                                .foregroundColor(.white)
                                            Text("Kết nối lại khi xe vào tầm phủ sóng")
                                                .font(.caption2)
                                                .foregroundColor(.gray)
                                        }
                                    }
                                    Button { showInfoAutoConnect = true } label: {
                                        Image(systemName: "info.circle")
                                            .font(.system(size: 15))
                                            .foregroundColor(.gray.opacity(0.6))
                                    }
                                    .popover(isPresented: $showInfoAutoConnect) {
                                        infoPopover(
                                            title: "Tự động kết nối lại",
                                            icon: "antenna.radiowaves.left.and.right",
                                            iconColor: .blue,
                                            body: "Bật: App sẽ tự đăng ký chờ kết nối với xe ngay khi Bluetooth phát hiện xe ở gần. Không cần mở app hay bấm gì thêm — khi bạn đến gần xe, kết nối xảy ra tự động trong nền.\n\nTắt: App chỉ kết nối khi bạn mở app lên."
                                        )
                                    }
                                    Spacer()
                                    Toggle("", isOn: Binding(
                                        get: { viewModel.autoConnectEnabled },
                                        set: { viewModel.setAutoConnect($0) }
                                    ))
                                    .tint(.blue)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)

                            Divider().background(Color.white.opacity(0.06))

                            HStack {
                                    HStack(spacing: 10) {
                                        Image(systemName: "wifi.slash")
                                            .font(.system(size: 14))
                                            .foregroundColor(.orange)
                                            .frame(width: 28, height: 28)
                                            .background(Color.orange.opacity(0.15))
                                            .clipShape(RoundedRectangle(cornerRadius: 6))

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Tự kết nối lại sau mất sóng")
                                                .font(.subheadline)
                                                .foregroundColor(.white)
                                            Text("Tắt: phải mở app khi quay lại gần xe")
                                                .font(.caption2)
                                                .foregroundColor(.gray)
                                        }
                                    }
                                    Button { showInfoBgReconnect = true } label: {
                                        Image(systemName: "info.circle")
                                            .font(.system(size: 15))
                                            .foregroundColor(.gray.opacity(0.6))
                                    }
                                    .popover(isPresented: $showInfoBgReconnect) {
                                        infoPopover(
                                            title: "Tự kết nối lại sau mất sóng",
                                            icon: "wifi.slash",
                                            iconColor: .orange,
                                            body: "Bật: Sau khi xe ra khỏi phủ sóng rồi quay lại, app tự kết nối lại mà không cần can thiệp.\n\nTắt: Khi mất kết nối (ra khỏi vùng phủ sóng, tắt Bluetooth...), app dừng hoàn toàn. Bạn phải mở app lên để thiết lập lại kết nối.\n\nPhù hợp nếu muốn kiểm soát thủ công hoặc tiết kiệm pin."
                                        )
                                    }
                                    Spacer()
                                    Toggle("", isOn: $viewModel.autoBackgroundReconnectEnabled)
                                        .tint(.orange)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)

                            if viewModel.autoConnectEnabled {
                                Divider().background(Color.white.opacity(0.06))

                                VStack(spacing: 8) {
                                    HStack {
                                        Text("Ngưỡng RSSI kết nối")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                        Spacer()
                                        Text("\(Int(viewModel.autoConnectRSSIThreshold)) dBm")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.blue)
                                    }

                                    Slider(value: $viewModel.autoConnectRSSIThreshold, in: -95...(-40), step: 5)
                                        .tint(.blue)

                                    HStack {
                                        Text("Xa hơn")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                        Spacer()
                                        Text("Gần hơn")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }

                                    // Live RSSI indicator
                                    HStack(spacing: 6) {
                                        Image(systemName: "dot.radiowaves.left.and.right")
                                            .font(.caption2)
                                            .foregroundColor(viewModel.isConnected ? rssiColor(viewModel.rssi) : .gray)
                                        Text(viewModel.isConnected
                                             ? "RSSI hiện tại: \(viewModel.rssi) dBm"
                                             : "Chưa kết nối — không đo được RSSI")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                        Spacer()
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                            }
                        }
                    }

                    // Auto-unlock section
                    settingsSection(title: "TỰ ĐỘNG MỞ KHÓA") {
                        VStack(spacing: 0) {
                            HStack {
                                    HStack(spacing: 10) {
                                        Image(systemName: "location.fill")
                                            .font(.system(size: 14))
                                            .foregroundColor(.purple)
                                            .frame(width: 28, height: 28)
                                            .background(Color.purple.opacity(0.15))
                                            .clipShape(RoundedRectangle(cornerRadius: 6))

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Auto Unlock")
                                                .font(.subheadline)
                                                .foregroundColor(.white)
                                            Text("Tự mở khóa khi đến gần xe")
                                                .font(.caption2)
                                                .foregroundColor(.gray)
                                        }
                                    }
                                    Button { showInfoAutoUnlock = true } label: {
                                        Image(systemName: "info.circle")
                                            .font(.system(size: 15))
                                            .foregroundColor(.gray.opacity(0.6))
                                    }
                                    .popover(isPresented: $showInfoAutoUnlock) {
                                        infoPopover(
                                            title: "Auto Unlock",
                                            icon: "location.fill",
                                            iconColor: .purple,
                                            body: "Khi bật, app đo tín hiệu Bluetooth (RSSI) liên tục trong nền. Khi RSSI vượt ngưỡng cài đặt (tức là bạn đang đứng đủ gần xe), app tự động gửi lệnh mở khóa — giống như Grab-key, không cần chạm màn hình.\n\n⚠️ Dùng thận trọng: xe có thể tự mở khóa nếu bạn đứng gần nhưng không có ý định đi — ví dụ khi đang đậu xe ở nhà và mang điện thoại lại gần."
                                        )
                                    }
                                    Spacer()
                                    Toggle("", isOn: Binding(
                                        get: { viewModel.autoUnlockEnabled },
                                        set: { viewModel.setAutoUnlock($0) }
                                    ))
                                    .tint(.purple)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)

                            if viewModel.autoUnlockEnabled {
                                Divider().background(Color.white.opacity(0.06))
                                
                                VStack(spacing: 8) {
                                    HStack {
                                        Text("Ngưỡng RSSI")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                        Spacer()
                                        Text("\(Int(viewModel.rssiThreshold)) dBm")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.purple)
                                    }
                                    
                                    Slider(value: $viewModel.rssiThreshold, in: -90...(-40), step: 5)
                                        .tint(.purple)
                                    
                                    HStack {
                                        Text("Xa hơn")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                        Spacer()
                                        Text("Gần hơn")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                            }
                        }
                    }
                    
                    // Device info section
                    if viewModel.isConnected && !viewModel.bikeInfo.isEmpty {
                        settingsSection(title: "THÔNG TIN XE") {
                            VStack(spacing: 0) {
                                settingsRow(icon: "bicycle", iconColor: .cyan,
                                           title: "Tên", value: viewModel.bikeInfo.name)
                                Divider().background(Color.white.opacity(0.06))
                                settingsRow(icon: "cpu", iconColor: .cyan,
                                           title: "Model", value: viewModel.bikeInfo.model)
                                Divider().background(Color.white.opacity(0.06))
                                settingsRow(icon: "number", iconColor: .cyan,
                                           title: "Serial", value: viewModel.bikeInfo.serial)
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
                            settingsButton(icon: "trash.fill", iconColor: .red, title: "Bỏ liên kết xe") {
                                showForgetConfirm = true
                            }
                        }
                    }

                    settingsSection(title: "THÔNG BÁO") {
                        VStack(spacing: 0) {
                            HStack {
                                HStack(spacing: 10) {
                                    Image(systemName: "bell.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(.yellow)
                                        .frame(width: 28, height: 28)
                                        .background(Color.yellow.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Thông báo")
                                            .font(.subheadline)
                                            .foregroundColor(.white)
                                        Text("Ấn: tắt cả thông báo kết nối / mất sóng")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                }
                                Spacer()
                                Toggle("", isOn: $viewModel.notificationsEnabled)
                                    .tint(.yellow)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
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
                                        Text(currentVNTimeString())
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.gray)
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

                    
                    // Debug section
                    settingsSection(title: "CÀI ĐẶT NHÀ PHÁT TRIỂN") {
                        VStack(spacing: 0) {
                            HStack {
                                HStack(spacing: 10) {
                                    Image(systemName: "ladybug.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(.green)
                                        .frame(width: 28, height: 28)
                                        .background(Color.green.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text("Chế độ Nhà phát triển")
                                        .font(.subheadline)
                                        .foregroundColor(.white)
                                }
                                Spacer()
                                Toggle("", isOn: $viewModel.isDebugModeEnabled)
                                    .tint(.green)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            
                            if viewModel.isDebugModeEnabled {
                                Divider().background(Color.white.opacity(0.06))
                                settingsButton(icon: "list.bullet.rectangle", iconColor: .green, title: "Xem BLE Log (\(viewModel.logs.count))") {
                                    showLogs = true
                                }
                                Divider().background(Color.white.opacity(0.06))
                                settingsButton(icon: "flask.fill", iconColor: .yellow, title: "BLE Test Panel") {
                                    showTestPanel = true
                                }
                            }
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
                        Text("MyBike Smartkey v1.0.3")
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
        .onReceive(timer) { input in
            currentTime = input
        }
        .sheet(isPresented: $showLogs) {
            LogView(logs: viewModel.logs)
        }
        .sheet(isPresented: $showTestPanel) {
            BLETestPanelView(viewModel: viewModel)
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

    private func currentVNTimeString() -> String {
        let vnTZ = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        let formatter = DateFormatter()
        formatter.timeZone = vnTZ
        formatter.dateFormat = "HH:mm:ss (dd/MM/yyyy)"
        return formatter.string(from: currentTime)
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
        .presentationCompactAdaptation(.popover)
    }
}

// MARK: - QR Code Generator

struct QRCodeView: View {
    let content: String
    let size: CGFloat

    var body: some View {
        if let image = generateQRCode(from: content) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Color.gray.frame(width: size, height: size)
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
              let white = CIFilter(name: "CIMaskToAlpha", parameters: [kCIInputImageKey: inverted])?.outputImage else {
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
    let logs: [BLELogEntry]
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.08)
                    .ignoresSafeArea()
                
                if logs.isEmpty {
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
                            ForEach(logs.reversed()) { entry in
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        let fullString = logs.reversed().map { "[\($0.formattedTime)] \($0.level.rawValue) \($0.message)" }.joined(separator: "\n")
                        UIPasteboard.general.string = fullString
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") { dismiss() }
                        .foregroundColor(.blue)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - BLE Test Panel

struct BLETestPanelView: View {
    @ObservedObject var viewModel: SmartKeyViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingTestLogShare = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.08).ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {

                        // Result box
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label("Kết quả", systemImage: "terminal.fill")
                                    .font(.caption.bold())
                                    .foregroundColor(.yellow)
                                Spacer()
                                // Save log button — appears once a test has started
                                if !viewModel.currentTestName.isEmpty {
                                    Button {
                                        viewModel.exportCurrentTestLog()
                                        showingTestLogShare = viewModel.lastTestLogURL != nil
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "square.and.arrow.up")
                                                .font(.system(size: 11))
                                            Text("Lưu log")
                                                .font(.caption.bold())
                                        }
                                        .foregroundColor(.cyan)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.cyan.opacity(0.12))
                                        .cornerRadius(6)
                                    }
                                    .disabled(viewModel.isTestRunning)
                                }
                            }
                            Text(viewModel.testResult.isEmpty ? "—" : viewModel.testResult)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(viewModel.testResult.hasPrefix("✅") ? .green
                                                 : viewModel.testResult.hasPrefix("❌") ? .red
                                                 : viewModel.testResult.hasPrefix("ERR") ? .orange
                                                 : .white)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(10)
                        }
                        .padding(.horizontal)
                        .sheet(isPresented: $showingTestLogShare) {
                            if let url = viewModel.lastTestLogURL {
                                ShareSheet(items: [url])
                            }
                        }

                        // ── Section 1: Counter & Auth ──
                        testSection(title: "COUNTER & AUTH") {
                            testScenarioRow(
                                icon: "number.circle", iconColor: .cyan,
                                title: "Đọc Counter",
                                description: "Đọc giá trị challenge counter hiện tại — không ghi gì."
                            ) { viewModel.testReadCounter() }

                            Divider().background(Color.white.opacity(0.06))

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "timer").foregroundColor(.orange)
                                    Text("Pre-write delay: \(String(format: "%.1f", viewModel.testPreWriteDelay))s")
                                        .font(.caption).foregroundColor(.white)
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                                Slider(value: $viewModel.testPreWriteDelay, in: 0...5, step: 0.5)
                                    .tint(.orange)
                                    .padding(.horizontal, 14)
                                HStack {
                                    Text("0s (không delay)")
                                    Spacer()
                                    Text("5s")
                                }
                                .font(.caption2).foregroundColor(.gray)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 4)
                            }

                            Divider().background(Color.white.opacity(0.06))

                            testScenarioRow(
                                icon: "lock.rotation", iconColor: .purple,
                                title: "Auth + Verify Counter",
                                description: "Ghi SHA-256 response, đọc lại counter 4 lần. Kiểm tra delay ảnh hưởng thế nào."
                            ) { viewModel.testAuthAndVerify() }

                            Divider().background(Color.white.opacity(0.06))

                            // Max retries stepper
                            HStack(spacing: 10) {
                                Image(systemName: "repeat.circle")
                                    .font(.system(size: 13))
                                    .foregroundColor(.yellow)
                                    .frame(width: 28, height: 28)
                                    .background(Color.yellow.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text("Số lần retry tối đa")
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                                Spacer()
                                Stepper("\(viewModel.testMaxRetries) lần", value: $viewModel.testMaxRetries, in: 1...20)
                                    .labelsHidden()
                                Text("\(viewModel.testMaxRetries)")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.yellow)
                                    .frame(minWidth: 28)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)

                            Divider().background(Color.white.opacity(0.06))

                            testScenarioRow(
                                icon: "arrow.clockwise.circle.fill", iconColor: .yellow,
                                title: "Retry Auth → Đến khi +1",
                                description: "Auth lại nhiều lần cho đến khi counter tăng đúng +1 (không phải +2). Dùng delay ở trên. Dừng khi đạt +1, counter=0 hoặc hết số lần."
                            ) { viewModel.testRetryUntilPlusOne() }
                        }

                        // ── Section 2: Connection ──
                        testSection(title: "KẾT NỐI") {
                            testScenarioRow(
                                icon: "info.circle", iconColor: .blue,
                                title: "Đọc trạng thái xe",
                                description: "Read lock status, log raw bytes."
                            ) { viewModel.testReadStatus() }

                            Divider().background(Color.white.opacity(0.06))

                            testScenarioRow(
                                icon: "bolt.horizontal", iconColor: .red,
                                title: "Force Disconnect (không reconnect)",
                                description: "Ngắt kết nối ngay, KHÔNG chạy scheduleReconnect. Test cold reconnect từ xe."
                            ) { viewModel.testForceDisconnect() }

                            Divider().background(Color.white.opacity(0.06))

                            testScenarioRow(
                                icon: "arrow.triangle.2.circlepath", iconColor: .green,
                                title: "Disconnect + Auto-Reconnect",
                                description: "Ngắt rồi đăng ký pending connection — test toàn bộ reconnect + auth flow."
                            ) { viewModel.testDisconnectAndReconnect() }
                        }

                        // ── Suggested Scenarios ──
                        testSection(title: "⚡ KỊCH BẢN GỢI Ý") {
                            VStack(alignment: .leading, spacing: 10) {
                                scenarioHint(num: 1, text: "Đọc Counter → Auth + Verify (delay=0s) → so sánh counter tăng mấy bước")
                                scenarioHint(num: 2, text: "Auth + Verify (delay=2s) → so sánh với delay=0s — tìm ngưỡng delay an toàn")
                                scenarioHint(num: 3, text: "Auth + Verify nhiều lần liên tiếp — xem counter tăng đều không hay skip")
                                scenarioHint(num: 4, text: "Force Disconnect → chờ 5s → xem app có tự reconnect không (pending connection)")
                                scenarioHint(num: 5, text: "Disconnect + AutoReconnect → icon BT xe có sáng không → kiểm tra Step 7 CCCD")
                                scenarioHint(num: 6, text: "Auth + Verify sau khi xe bị tắt nguồn → counter reset về 0 hay giữ?")
                                scenarioHint(num: 7, text: "Auth khi RSSI ~ -80 dBm (đứng xa) → counter có tăng không hay timeout")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 12)
                }
            }
            .navigationTitle("BLE Test Panel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func testSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.gray)
                .padding(.horizontal, 20)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
            )
            .padding(.horizontal)
        }
    }

    private func testScenarioRow(icon: String, iconColor: Color, title: String, description: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(iconColor)
                    .frame(width: 28, height: 28)
                    .background(iconColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Text(description)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                if viewModel.isTestRunning {
                    ProgressView().tint(.yellow).scaleEffect(0.8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .disabled(viewModel.isTestRunning)
    }

    private func scenarioHint(num: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(num).")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.yellow)
                .frame(width: 18, alignment: .leading)
            Text(text)
                .font(.caption)
                .foregroundColor(.gray.opacity(0.85))
                .multilineTextAlignment(.leading)
        }
    }
}
