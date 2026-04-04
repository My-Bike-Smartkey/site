// SettingsView.swift — Settings, device info, auto-unlock config, and debug log

import SwiftUI
import CoreImage.CIFilterBuiltins

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showLogs = false
    @State private var showForgetConfirm = false
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
                                            body: "Khi bật, app đo tín hiệu Bluetooth (RSSI) liên tục khi mở app. Khi RSSI vượt ngưỡng cài đặt (tức là bạn đang đứng đủ gần xe), app tự tự động mở khoá."
                                        )
                                    }
                                    Spacer()
                                    Toggle("", isOn: Binding(
                                        get: { viewModel.autoUnlockEnabled },
                                        set: { viewModel.autoUnlockEnabled = $0 }
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
                        Text("MyBike Smartkey v2.0.0")
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
            LogView(logs: viewModel.logs)
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
