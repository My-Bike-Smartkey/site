// MainView.swift — Tab container

import SwiftUI

struct MainView: View {
    @EnvironmentObject var container: AppDIContainer
    @State private var showingSettings = false
    @State private var showingLogs = false
    @State private var showingNFCPrompt = false
    @State private var showingDisclaimer = false
    
    var body: some View {
        Group {
            if container.dashboardViewModel.isConnected || container.dashboardViewModel.isPaused {
                DashboardView(viewModel: container.dashboardViewModel)
                    .transition(.opacity)
            } else {
                ConnectingSplashView(
                    dashboardVM: container.dashboardViewModel,
                    settingsVM: container.settingsViewModel,
                    showingSettings: $showingSettings,
                    showingLogs: $showingLogs,
                    showingNFCPrompt: $showingNFCPrompt
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: container.dashboardViewModel.isConnected || container.dashboardViewModel.isPaused)
        .preferredColorScheme(.dark)
        .onAppear {
            if !UserDefaults.standard.bool(forKey: "disclaimerAccepted") {
                NotificationManager.shared.requestPermission {
                    showingDisclaimer = true
                }
            } else {
                NotificationManager.shared.requestPermission {
                    container.dashboardViewModel.initializeHardware()
                    // Auto-connect nếu đã pair trước đó
                    if PreferencesManager.shared.savedPin != nil || PreferencesManager.shared.savedPeripheralUUID != nil {
                        container.dashboardViewModel.connectBike()
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: container.settingsViewModel)
        }
        .alert("Miễn trừ trách nhiệm", isPresented: $showingDisclaimer) {
            Button("Tôi đã hiểu và đồng ý") {
                UserDefaults.standard.set(true, forKey: "disclaimerAccepted")
                container.dashboardViewModel.initializeHardware()
                
                // Chỉ tự động connect nếu người dùng đã từng Add xe (có Pin/UUID cũ).
                // Nếu là lần đầu cài app trắng, sẽ đợi người dùng tự bấm nút (+) Thêm Xe
                if PreferencesManager.shared.savedPin != nil || PreferencesManager.shared.savedPeripheralUUID != nil {
                    container.dashboardViewModel.connectBike()
                }
            }
        } message: {
            Text("""
            Ứng dụng này được phát triển bởi bên thứ ba, KHÔNG liên kết với Dat Bike hoặc bất kỳ nhà sản xuất xe nào.

            Bằng việc sử dụng ứng dụng, bạn chấp nhận:
            • Tự chịu mọi rủi ro liên quan đến việc điều khiển xe qua Bluetooth.
            • Nhà phát triển không chịu trách nhiệm về bất kỳ thiệt hại, mất mát hoặc sự cố nào.
            • Không sử dụng ứng dụng cho mục đích trái pháp luật.
            """)
        }
        .alert("Xác nhận ghép đôi", isPresented: $showingNFCPrompt) {
            Button("Hủy", role: .cancel) {
                // Do nothing
            }
            Button("Bắt đầu ghép đôi") {
                // Trì hoãn 0.5s để hộp thoại (Alert) kịp đóng lại hoàn toàn.
                // Tránh lỗi "Application is not in foreground" của AccessorySetupKit trên iOS 18.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    container.dashboardViewModel.connectBike()
                }
            }
        } message: {
            Text("Đảm bảo thẻ NFC đã được đặt sẵn trên mặt đồng hồ xe. Bấm xác nhận để bắt đầu tìm xe và ghép đôi Bluetooth.")
        }
    }
}

// MARK: - Connecting Splash View

struct ConnectingSplashView: View {
    @ObservedObject var dashboardVM: DashboardViewModel
    @ObservedObject var settingsVM: SettingsViewModel
    @Binding var showingSettings: Bool
    @Binding var showingLogs: Bool
    @Binding var showingNFCPrompt: Bool
    
    @State private var pulsePhase: CGFloat = 0
    
    var body: some View {
        ZStack {
            // Background — tĩnh, không xoay
            Color(red: 0.05, green: 0.05, blue: 0.08)
                .ignoresSafeArea()
            
            // Header: hidden settings button
            VStack {
                HStack {
                    Spacer()
                    
                    if dashboardVM.connectionState == .active {
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            dashboardVM.forceStandby()
                        }) {
                            Image(systemName: "wifi.slash")
                                .font(.system(size: 20))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.vertical)
                        }
                    }
                    
                    // Nút bật/tắt chế độ "Đang ở gần"
                    if dashboardVM.connectionState == .active || dashboardVM.connectionState == .standby {
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            dashboardVM.activateNearbyMode()
                        }) {
                            Image(systemName: "location.circle")
                                .font(.system(size: 20))
                                .foregroundColor(.blue.opacity(0.6))
                                .padding(.vertical)
                        }
                    } else if case .nearby = dashboardVM.connectionState {
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            dashboardVM.deactivateNearbyMode()
                        }) {
                            Image(systemName: "location.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.blue)
                                .padding(.vertical)
                        }
                    }
                    
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.05))
                            .padding()
                    }
                }
                Spacer()
            }
            
            // Main content
            VStack(spacing: 0) {
                Spacer()
                
                // ── RADAR PULSE ──
                ZStack {
                    // Vòng tròn tỏa ra (1 ring duy nhất)
                    Circle()
                        .stroke(stateColor, lineWidth: 2)
                        .frame(width: 180, height: 180)
                        .scaleEffect(pulsePhase == 0 ? 1.0 : 2.5)
                        .opacity(pulsePhase == 0 ? 0.6 : 0.0)
                        .animation(
                            .easeOut(duration: 2.0)
                                .repeatForever(autoreverses: false),
                            value: pulsePhase
                        )
                    
                    // Vòng tròn nền trung tâm
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [stateColor.opacity(0.15), Color.clear],
                                center: .center,
                                startRadius: 30,
                                endRadius: 90
                            )
                        )
                        .frame(width: 180, height: 180)
                    
                    // Viền tròn cố định
                    Circle()
                        .stroke(stateColor.opacity(0.3), lineWidth: 1)
                        .frame(width: 180, height: 180)
                    
                    // Logo icon
                    Image("VHexaLogoWhite")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 90, height: 90)
                        .foregroundColor(stateColor)
                }
                .animation(.easeInOut(duration: 0.5), value: dashboardVM.connectionState)
                
                Spacer().frame(height: 28)
                
                // ── TÊN XE THỰC TẾ ──
                Text(bikeName)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Spacer().frame(height: 8)
                
                // ── TRẠNG THÁI NHỎ ──
                Text(statusLabel)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(stateColor.opacity(0.7))
                    .onReceive(dotTimer) { _ in
                        dotCount += 1
                    }
                
                Spacer()
                
                // ── BOTTOM STATUS AREA ──
                VStack(spacing: 16) {
                    if let err = dashboardVM.pairingError {
                        // Error state
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.red)
                        
                        Text(err)
                            .font(.subheadline)
                            .foregroundColor(.red.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        if err.contains("cấp quyền") {
                            Button(action: {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }) {
                                Text("Mở Cài Đặt")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 30)
                                    .padding(.vertical, 12)
                                    .background(Color.blue)
                                    .clipShape(Capsule())
                            }
                        } else {
                            Button(action: { dashboardVM.connectBike() }) {
                                Text("Thử lại")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 30)
                                    .padding(.vertical, 12)
                                    .background(Color.orange)
                                    .clipShape(Capsule())
                            }
                        }
                    } else if dashboardVM.connectionState == .pairingRequired {
                        // NFC pairing state
                        Image(systemName: "wave.3.left.circle.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.blue)
                        
                        Text("Vui lòng chạm thẻ NFC vào xe để xác thực.")
                            .font(.headline)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        Button(action: {
                            let securePin = BLEProtocol.generateSecurePIN()
                            dashboardVM.submitPairingPin(securePin)
                        }) {
                            Text("Đặt thẻ khóa NFC lên vị trí mở khóa")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.horizontal, 30)
                                .padding(.vertical, 12)
                                .background(Color.blue.opacity(0.8))
                                .clipShape(Capsule())
                        }
                    } else if dashboardVM.connectionState == .scanning && !dashboardVM.discoveredBikes.isEmpty {
                        // Bike list found
                        VStack(spacing: 16) {
                            Text("Chọn xe để kết nối")
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            ForEach(dashboardVM.discoveredBikes) { bike in
                                Button(action: { dashboardVM.selectBike(bike.id) }) {
                                    HStack(spacing: 14) {
                                        Image(systemName: "bicycle")
                                            .font(.title2)
                                            .foregroundColor(.orange)
                                            .frame(width: 36)
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(bike.name)
                                                .font(.headline)
                                                .foregroundColor(.white)
                                            Text("ID: \(String(bike.id.suffix(8)).uppercased())")
                                                .font(.caption)
                                                .foregroundColor(.orange.opacity(0.7))
                                        }
                                        
                                        Spacer()
                                        
                                        bikeSignalIcon(rssi: bike.rssi)
                                    }
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14)
                                            .fill(Color.white.opacity(0.06))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 14)
                                                    .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                                            )
                                    )
                                }
                            }
                            .padding(.horizontal)
                            
                            HStack(spacing: 8) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .gray))
                                    .scaleEffect(0.7)
                                Text("Đang quét thêm...")
                                    .font(.caption)
                                    .foregroundColor(.gray.opacity(0.6))
                            }
                        }
                    } else if case .nearby = dashboardVM.connectionState {
                        // ── NEARBY STATE: Hiện thông tin + nút kết nối ──
                        VStack(spacing: 16) {
                            // Thông tin xe cơ bản
                            HStack(spacing: 20) {
                                VStack(spacing: 4) {
                                    Image(systemName: "battery.75percent")
                                        .font(.title2)
                                        .foregroundColor(.green)
                                    Text("\(Int(dashboardVM.telemetry.soc))%")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.white)
                                }
                                
                                VStack(spacing: 4) {
                                    Image(systemName: dashboardVM.lockState == .unlocked ? "lock.open.fill" : (dashboardVM.lockState == .armed ? "shield.fill" : "lock.fill"))
                                        .font(.title2)
                                        .foregroundColor(dashboardVM.lockState == .unlocked ? .green : (dashboardVM.lockState == .armed ? .orange : .gray))
                                    Text(dashboardVM.lockState.description)
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                
                                VStack(spacing: 4) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.title2)
                                        .foregroundColor(.cyan)
                                    Text("\(dashboardVM.rssi) dBm")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                            }
                            .padding(.vertical, 8)
                            
                            // Nút kết nối
                            Button(action: {
                                let generator = UIImpactFeedbackGenerator(style: .heavy)
                                generator.impactOccurred()
                                dashboardVM.connectFromNearby()
                            }) {
                                HStack(spacing: 10) {
                                    Image(systemName: "bolt.circle.fill")
                                        .font(.title2)
                                    Text("Kết nối ngay")
                                        .font(.headline)
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 36)
                                .padding(.vertical, 14)
                                .background(
                                    LinearGradient(
                                        colors: [Color(red: 0.3, green: 0.7, blue: 1.0), Color(red: 0.2, green: 0.5, blue: 0.9)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(Capsule())
                                .shadow(color: Color(red: 0.3, green: 0.7, blue: 1.0).opacity(0.4), radius: 10, y: 5)
                            }
                            
                            Text("Chế độ gần xe • Bấm để kết nối & điều khiển")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.4))
                        }
                    } else if !dashboardVM.hasAuthorizedAccessory && PreferencesManager.shared.savedPeripheralUUID == nil {
                        // No bike paired — show add button
                        Button(action: { dashboardVM.connectBike() }) {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title2)
                                Text("Thêm xe")
                                    .font(.headline)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 30)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(
                                    colors: [.orange, .orange.opacity(0.8)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(Capsule())
                            .shadow(color: .orange.opacity(0.3), radius: 10, y: 5)
                        }
                        
                        Text("Hướng dẫn: Quẹt sẵn thẻ NFC lên đồng hồ xe trước khi bấm")
                            .font(.caption)
                            .foregroundColor(.orange.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                     } else if dashboardVM.connectionState == .scanning && PreferencesManager.shared.savedPin != nil {
                        // ── SCANNING + đã pair trước đó: hiện nút Kết nối lại ──
                        // Escape hatch cho user khi bị kẹt ở scanning (scan loop, stale flags...)
                        VStack(spacing: 12) {
                            Button(action: {
                                let generator = UIImpactFeedbackGenerator(style: .heavy)
                                generator.impactOccurred()
                                dashboardVM.forceReconnect()
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("Kết nối lại")
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .foregroundColor(.white.opacity(0.9))
                                .padding(.horizontal, 28)
                                .padding(.vertical, 11)
                                .background(
                                    Capsule()
                                        .fill(Color.white.opacity(0.08))
                                        .overlay(
                                            Capsule()
                                                .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
                                        )
                                )
                            }
                            
                            Text("Bấm nếu chờ quá lâu")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.3))
                        }
                    } else {
                        // Trạng thái chờ/kết nối -> ẩn (đã hiển thị ở trên)
                    }
                }
                .frame(minHeight: 100)
                .padding(.bottom, 60)
            }
        }
        .onAppear {
            pulsePhase = 1
        }
    }
    
    @State private var dotCount = 0
    let dotTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    
    private var bikeName: String {
        let infoName = dashboardVM.bikeInfo.name
        // Nếu bikeInfo đã có tên thực (không phải default)
        if !infoName.isEmpty && infoName != "Dat Bike" {
            return infoName
        }
        // Fallback: tên đã lưu từ lần kết nối trước
        if let saved = PreferencesManager.shared.sharedDefaults.string(forKey: "widgetBikeName"),
           !saved.isEmpty && saved != "Dat Bike" {
            return saved
        }
        return "D-SmartKey"
    }
    
    private var statusLabel: String {
        let baseText: String
        switch dashboardVM.connectionState {
        case .scanning: baseText = "Đang tìm xe"
        case .connecting: baseText = "Đang kết nối"
        case .authenticating: baseText = "Đang xác thực & Ghép đôi"
        case .standby: baseText = "Kết nối chờ"
        case .nearby: baseText = "Đang ở gần xe"
        default: baseText = "Đang kết nối"
        }
        let dots = String(repeating: ".", count: (dotCount % 3) + 1)
        return baseText + dots
    }
    
    // Dynamic theme color based on connection state
    private var stateColor: Color {
        switch dashboardVM.connectionState {
        case .scanning: return .cyan
        case .connecting: return .orange
        case .authenticating: return .yellow
        case .standby: return Color(red: 0.2, green: 0.8, blue: 0.4)
        case .nearby: return Color(red: 0.3, green: 0.7, blue: 1.0)
        default: return .orange
        }
    }
    

    private func bikeSignalIcon(rssi: Int) -> some View {
        let (bars, color): (Int, Color) = {
            if rssi >= -60 { return (4, .green) }
            if rssi >= -75 { return (3, .green) }
            if rssi >= -85 { return (2, .yellow) }
            return (1, .red)
        }()
        
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level <= bars ? color : Color.gray.opacity(0.3))
                    .frame(width: 4, height: CGFloat(level * 5))
            }
        }
    }
}

