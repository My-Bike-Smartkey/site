// SettingsView.swift — Settings, device info, auto-unlock config, and debug log

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SmartKeyViewModel
    @State private var showLogs = false
    @State private var showPINEditor = false
    @State private var editedPIN = ""
    @State private var showForgetConfirm = false
    @State private var showForgetInstructions = false
    
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
                    
                    // Connection section
                    settingsSection(title: "KẾT NỐI") {
                        VStack(spacing: 0) {
                            settingsRow(icon: "antenna.radiowaves.left.and.right",
                                       iconColor: .blue,
                                       title: "Trạng thái BLE",
                                       value: viewModel.connectionState.displayText)
                            
                            Divider().background(Color.white.opacity(0.06))
                            
                            if viewModel.isConnected {
                                settingsRow(icon: "wifi",
                                           iconColor: viewModel.signalStrength.color,
                                           title: "Cường độ tín hiệu",
                                           value: "\(viewModel.rssi) dBm (\(viewModel.signalStrength.label))")
                                
                                Divider().background(Color.white.opacity(0.06))
                            }
                            
                            settingsButton(icon: viewModel.isConnected ? "xmark.circle" : "magnifyingglass",
                                          iconColor: viewModel.isConnected ? .red : .green,
                                          title: viewModel.isConnected ? "Ngắt kết nối" : "Quét & kết nối") {
                                if viewModel.isConnected {
                                    viewModel.disconnect()
                                } else {
                                    viewModel.startScan()
                                }
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
                            settingsButton(icon: "key.fill", iconColor: .orange, title: "Đổi mã PIN") {
                                editedPIN = viewModel.authPIN
                                showPINEditor = true
                            }
                            Divider().background(Color.white.opacity(0.06))
                            settingsButton(icon: "trash.fill", iconColor: .red, title: "Quên xe (Xóa kết nối bản sao)") {
                                showForgetConfirm = true
                            }
                        }
                    }
                    
                    // Debug section
                    settingsSection(title: "GỠ LỖI") {
                        VStack(spacing: 0) {
                            settingsButton(icon: "list.bullet.rectangle", iconColor: .green, title: "Xem BLE Log (\(viewModel.logs.count))") {
                                showLogs = true
                            }
                        }
                    }
                    
                    // App info
                    VStack(spacing: 4) {
                        Text("Dat Bike Smartkey v1.0 (Build: Mar 30, 12:55)")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("Native iOS • CoreBluetooth • Background Optimized")
                            .font(.caption2)
                            .foregroundColor(.gray.opacity(0.6))
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
        .alert("Mã PIN xác thực", isPresented: $showPINEditor) {
            TextField("Nhập PIN BLE", text: $editedPIN)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Lưu") { viewModel.authPIN = editedPIN }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("PIN dùng để xác thực BLE với xe. Mặc định: \(BLEProtocol.authPIN)")
        }
        .alert("Quên xe", isPresented: $showForgetConfirm) {
            Button("Quên", role: .destructive) {
                viewModel.forgetBike()
                showForgetInstructions = true
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Xóa kết nối App với xe. Bạn có muốn tiếp tục?")
        }
        .alert("⚠️ Hoàn tất bằng tay", isPresented: $showForgetInstructions) {
            Button("Mở Cài đặt Bluetooth") {
                if let url = URL(string: "App-Prefs:Bluetooth") {
                    UIApplication.shared.open(url)
                }
            }
            Button("Bỏ qua", role: .cancel) {}
        } message: {
            Text("iOS không cho phép ứng dụng xóa ghép đôi Bluetooth tự động.\n\nHãy vào Cài đặt → Bluetooth → tìm xe Dat Bike → nhấn ⓘ → chọn \"Quên thiết bị\" để xóa hoàn toàn.")
        }
    }
    
    // MARK: - Section Builder
    
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
