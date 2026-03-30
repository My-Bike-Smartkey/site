// MainView.swift — Tab container

import SwiftUI

struct MainView: View {
    @StateObject private var viewModel = SmartKeyViewModel()
    @State private var showingSettings = false
    @State private var showingPINPrompt = false
    @State private var showingNFCPrompt = false
    @State private var enteredPIN = ""
    
    var body: some View {
        Group {
            if viewModel.isAuthenticated {
                DashboardView(viewModel: viewModel)
                    .transition(.opacity)
            } else {
                ConnectingSplashView(viewModel: viewModel, showingSettings: $showingSettings, showingPINPrompt: $showingPINPrompt)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: viewModel.isAuthenticated)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel)
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
            Text("Nhập mã PIN cấu hình của xe để xác thực. (Mặc định: \(BLEProtocol.authPIN))")
        }
        .alert("Yêu cầu quẹt thẻ NFC", isPresented: $showingNFCPrompt) {
            Button("Hủy", role: .cancel) {
                // Do nothing
            }
            Button("Đã đặt thẻ (OK)") {
                viewModel.connectSelectedBike()
            }
        } message: {
            Text("Vui lòng chạm sát thẻ NFC gốc của bạn vào mặt đồng hồ xe Dat Bike TRƯỚC khi bấm OK để hoàn tất ghép đôi.")
        }
    }
}

// MARK: - Connecting Splash View

struct ConnectingSplashView: View {
    @ObservedObject var viewModel: SmartKeyViewModel
    @Binding var showingSettings: Bool
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
                    Text("Dat Bike Smartkey")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    Text("Quantum S3")
                        .font(.subheadline)
                        .foregroundColor(.gray)
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
