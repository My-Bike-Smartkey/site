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
            if container.dashboardViewModel.isConnected {
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
        .animation(.easeInOut, value: container.dashboardViewModel.isConnected)
        .preferredColorScheme(.dark)
        .onAppear {
            NotificationManager.shared.requestPermission()
            
            if !UserDefaults.standard.bool(forKey: "disclaimerAccepted") {
                showingDisclaimer = true
            } else {
                container.dashboardViewModel.initializeHardware()
                // Auto-connect nếu đã pair trước đó (có savedPin)
                // centralManagerDidUpdateState(.poweredOn) sẽ tự trigger connect()
                // nhưng gọi thêm ở đây để cover case BLE đã ready trước onAppear
                if PreferencesManager.shared.savedPin != nil {
                    container.dashboardViewModel.connectBike()
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
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.05, blue: 0.08), Color(red: 0.1, green: 0.1, blue: 0.15)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack {
                HStack {
                    Spacer()
                    
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.gray)
                            .padding()
                    }
                }
                Spacer()
            }
            
            VStack(spacing: 40) {
                // Logo
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.1))
                        .frame(width: 140, height: 140)
                    
                    Image("VHexaLogoWhite")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 70, height: 70)
                        .foregroundColor(.orange)
                }
                
                VStack(spacing: 12) {
                    Text("D-SmartKey")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                }
                
                // Status indicator
                VStack(spacing: 20) {
                    if let err = dashboardVM.pairingError {
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
                    } else if dashboardVM.connectionState == .scanning {
                        // MARK: - Bike Picker / Scanning
                        if dashboardVM.discoveredBikes.isEmpty {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                                .scaleEffect(1.3)
                            
                            Text("Đang tìm xe...")
                                .font(.headline)
                                .foregroundColor(.gray)
                        } else {
                            // Danh sách xe tìm thấy
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
                                            
                                            // Signal indicator
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
                                
                                // Vẫn đang quét thêm
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .gray))
                                        .scaleEffect(0.7)
                                    Text("Đang quét thêm...")
                                        .font(.caption)
                                        .foregroundColor(.gray.opacity(0.6))
                                }
                            }
                        }
                    } else if dashboardVM.connectionState == .connecting || dashboardVM.connectionState == .authenticating {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                            .scaleEffect(1.5)
                        
                        Text(dashboardVM.connectionState == .authenticating ? "Đang xác thực bảo mật..." : "Đang kết nối...")
                            .font(.headline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else {
                        // Idle — nút bắt đầu tìm xe
                        if #available(iOS 18.0, *) {
                            if dashboardVM.hasAuthorizedAccessory {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                                    .scaleEffect(1.2)
                                
                                Text("Đang kết nối lại xe...")
                                    .font(.headline)
                                    .foregroundColor(.gray)
                            } else {
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
                            }
                        } else {
                            Button(action: { dashboardVM.connectBike() }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.title2)
                                    Text("Tìm xe")
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
                        }
                    }
                }
                .frame(minHeight: 100)
            }
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

