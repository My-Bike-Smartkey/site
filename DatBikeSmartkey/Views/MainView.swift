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
            if !UserDefaults.standard.bool(forKey: "disclaimerAccepted") {
                showingDisclaimer = true
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: container.settingsViewModel)
        }
        .alert("Miễn trừ trách nhiệm", isPresented: $showingDisclaimer) {
            Button("Tôi đã hiểu và đồng ý") {
                UserDefaults.standard.set(true, forKey: "disclaimerAccepted")
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
            Button("Bắt đầu") {
                container.dashboardViewModel.connectBike()
            }
        } message: {
            Text("Vui lòng chuẩn bị thẻ NFC và đưa lại gần điện thoại để tiến hành xác thực khi được yêu cầu.")
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
                    if settingsVM.isDebugModeEnabled {
                        Button(action: { showingLogs = true }) {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.cyan)
                                .padding()
                        }
                    }
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
                    
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 70))
                        .foregroundColor(.orange)
                }
                
                VStack(spacing: 12) {
                    Text("MyBike Smartkey")
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
                            // Giả lập hệ thống NFC trả về một mã PIN 6 số hoặc lấy tự động
                            let simulatedPin = String(format: "%06d", Int.random(in: 100000...999999))
                            dashboardVM.submitPairingPin(simulatedPin)
                        }) {
                            Text("Giả lập chạm thẻ NFC (Sinh PIN)")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.horizontal, 30)
                                .padding(.vertical, 12)
                                .background(Color.blue.opacity(0.8))
                                .clipShape(Capsule())
                        }
                    } else if dashboardVM.connectionState == .connecting || dashboardVM.connectionState == .authenticating {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                            .scaleEffect(1.5)
                        
                        Text(dashboardVM.connectionState == .authenticating ? "Đang xác thực bằng cơ chế ẩn..." : "Đang thiết lập kết nối mã hoá...")
                            .font(.headline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else {
                        Button(action: { showingNFCPrompt = true }) {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title2)
                                Text("Thêm xe / Kết nối")
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
                        
                        Text("Sử dụng kiến trúc IoT V2")
                            .font(.caption)
                            .foregroundColor(.gray.opacity(0.6))
                    }
                }
                .frame(minHeight: 100)
            }
        }
    }
}
