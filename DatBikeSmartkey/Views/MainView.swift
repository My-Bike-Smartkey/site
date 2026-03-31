// MainView.swift — Tab container

import SwiftUI

struct MainView: View {
    @StateObject private var viewModel = SmartKeyViewModel()
    @State private var showingSettings = false
    @State private var showingLogs = false
    @State private var showingPINPrompt = false
    @State private var showingNFCPrompt = false
    @State private var showingDisclaimer = false
    @State private var enteredPIN = ""
    
    var body: some View {
        Group {
            if viewModel.isAuthenticated {
                DashboardView(viewModel: viewModel)
                    .transition(.opacity)
            } else {
                ConnectingSplashView(viewModel: viewModel, showingSettings: $showingSettings, showingLogs: $showingLogs, showingPINPrompt: $showingPINPrompt)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: viewModel.isAuthenticated)
        .preferredColorScheme(.dark)
        .onAppear {
            if !UserDefaults.standard.bool(forKey: "disclaimerAccepted") {
                showingDisclaimer = true
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingLogs) {
            DebugLogView(bleManager: BLEManager.shared)
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
        .alert("Mã PIN ghép đôi", isPresented: $showingPINPrompt) {
            TextField("Nhập mã PIN", text: $enteredPIN)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            Button("Hủy", role: .cancel) { }
            Button("Tiếp tục") {
                if !enteredPIN.isEmpty {
                    viewModel.authPIN = enteredPIN
                }
                showingNFCPrompt = true
            }
        } message: {
            Text("Nhập mã PIN cấu hình của xe để xác thực. Để trống để dùng PIN tự sinh.")
        }
        .alert("Xác nhận ghép đôi", isPresented: $showingNFCPrompt) {
            Button("Hủy", role: .cancel) {
                // Do nothing
            }
            Button("Bắt đầu ghép đôi") {
                viewModel.connectSelectedBike()
            }
        } message: {
            Text("Đảm bảo thẻ NFC đã được đặt trên mặt đồng hồ xe. Bấm xác nhận để bắt đầu ghép đôi Bluetooth.")
        }
    }
}

// MARK: - Connecting Splash View

struct ConnectingSplashView: View {
    @ObservedObject var viewModel: SmartKeyViewModel
    @Binding var showingSettings: Bool
    @Binding var showingLogs: Bool
    @Binding var showingPINPrompt: Bool
    
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
                    Button(action: { showingLogs = true }) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.cyan)
                            .padding(.top)
                            .padding(.leading)
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
                    if let _ = viewModel.connectionState.displayText.range(of: "Lỗi") {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.red)
                        
                        Button(action: { viewModel.startScan() }) {
                            Text("Thử lại")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.horizontal, 30)
                                .padding(.vertical, 12)
                                .background(Color.orange)
                                .clipShape(Capsule())
                        }
                    } else if viewModel.connectionState.isWorking {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                            .scaleEffect(1.5)
                    } else if viewModel.connectionState == .bluetoothOff || viewModel.connectionState == .disconnected {
                        Button(action: { viewModel.startScan() }) {
                            Text("Quét tìm xe")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.horizontal, 30)
                                .padding(.vertical, 12)
                                .background(Color.orange)
                                .clipShape(Capsule())
                        }
                    }
                    
                    Text(viewModel.connectionState.displayText)
                        .font(.headline)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(height: 100)
                
                // Discovered Bikes List for First Time Connection
                if !viewModel.discoveredBikes.isEmpty && viewModel.connectionState == .scanning {
                    VStack(spacing: 12) {
                        Text("CHỌN XE ĐỂ KẾT NỐI")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .padding(.top, 10)
                        
                        ScrollView {
                            VStack(spacing: 10) {
                                ForEach(viewModel.discoveredBikes) { bike in
                                    Button(action: {
                                        viewModel.selectBike(bike)
                                        showingPINPrompt = true
                                    }) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(bike.name)
                                                    .font(.headline)
                                                    .foregroundColor(.white)
                                                Text(bike.id)
                                                    .font(.caption2)
                                                    .foregroundColor(.gray)
                                            }
                                            Spacer()
                                            
                                            HStack(spacing: 4) {
                                                Image(systemName: "wifi")
                                                Text("\(bike.rssi)")
                                            }
                                            .font(.caption)
                                            .foregroundColor(.green)
                                        }
                                        .padding()
                                        .background(Color(white: 0.15))
                                        .cornerRadius(12)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                    }
                    .padding(.horizontal, 30)
                }
            }
        }
    }
}
