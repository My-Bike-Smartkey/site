// DashboardView.swift — Main dashboard with lock control and status

import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: SmartKeyViewModel
    @State private var showingLogs = false
    @State private var showingSettings = false
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.04, blue: 0.08),
                    Color(red: 0.06, green: 0.06, blue: 0.14),
                    Color(red: 0.04, green: 0.04, blue: 0.08)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // Header
                    headerView
                    
                    // Connection status card
                    Button(action: {
                        viewModel.refreshStatus()
                    }) {
                        StatusCard(
                            connectionState: viewModel.connectionState,
                            rssi: viewModel.rssi,
                            signalStrength: viewModel.signalStrength,
                            bikeInfo: viewModel.bikeInfo,
                            batteryPercentage: viewModel.batteryPercentage,
                            odometer: viewModel.odometer
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Spacer(minLength: 20)
                    
                    // Lock button
                    if viewModel.isConnected {
                        VStack(spacing: 16) {
                            LockButton(
                                lockStatus: viewModel.lockStatus,
                                isProcessing: viewModel.isProcessing,
                                action: { viewModel.toggleLock() }
                            )
                            
                            LockStatusLabel(lockStatus: viewModel.lockStatus)
                            
                            Text(viewModel.lockStatus.isLocked ? "Nhấn để \(viewModel.lockStatus == .armed ? "tắt" : "bật") chống trộm" : "Nhấn để tắt xe")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    } else {
                        disconnectedView
                    }
                    
                    Spacer(minLength: 20)
                    
                    // Quick actions
                    if viewModel.isConnected {
                        quickActionsView
                            .padding(.horizontal)
                    }
                    
                    Spacer(minLength: 40)
                }
                .padding(.top, 8)
            }
        }
        .alert("Lỗi", isPresented: $viewModel.showError) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage)
        }
        .sheet(isPresented: $showingLogs) {
            DebugLogView(logs: viewModel.logs)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel)
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dat Bike")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                
                Text("Quantum S3 Smartkey")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.gray)
                    .padding(10)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .padding(.trailing, 8)
            
            // BLE status indicator
            Circle()
                .fill(viewModel.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .fill(viewModel.isConnected ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                        .opacity(viewModel.connectionState.isWorking ? 1 : 0)
                        .scaleEffect(viewModel.connectionState.isWorking ? 2.5 : 1)
                        .opacity(viewModel.connectionState.isWorking ? 0 : 1)
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false), value: viewModel.connectionState.isWorking)
                )
        }
        .padding(.horizontal)
    }
    
    // MARK: - Disconnected View
    
    private var disconnectedView: some View {
        VStack(spacing: 20) {
            Image(systemName: viewModel.connectionState == .pairingRequired ? "sensor.tag.radiowaves.forward" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 56))
                .foregroundColor(viewModel.connectionState == .pairingRequired ? .orange : .gray.opacity(0.5))
                .opacity(viewModel.connectionState == .scanning ? 0.5 : 1.0)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: viewModel.connectionState == .scanning)
            
            VStack(spacing: 6) {
                Text(viewModel.connectionState == .scanning ? "Đang tìm xe..." : (viewModel.connectionState == .pairingRequired ? "Xe yêu cầu ghép đôi" : "Chưa kết nối"))
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundColor(viewModel.connectionState == .pairingRequired ? .orange : .white)
                
                Text(viewModel.connectionState == .scanning
                     ? "Tìm kiếm Dat Bike Quantum S3 trong phạm vi BLE"
                     : (viewModel.connectionState == .pairingRequired
                        ? "Vui lòng quẹt thẻ NFC vào chữ N trên xe và bấm Xác nhận trên bảng hỏi của iPhone."
                        : "Nhấn quét để tìm xe của bạn"))
                    .font(.caption)
                    .foregroundColor(viewModel.connectionState == .pairingRequired ? .white.opacity(0.8) : .gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            
            if viewModel.connectionState != .scanning && viewModel.connectionState != .connecting && viewModel.connectionState != .pairingRequired && viewModel.connectionState != .authenticating {
                Button(action: { viewModel.startScan() }) {
                    // Start Scan Button Code... (kept intact below)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text("Quét tìm xe Dat Bike")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.3, green: 0.5, blue: 1.0),
                                Color(red: 0.2, green: 0.35, blue: 0.85)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(Capsule())
                    .shadow(color: Color(red: 0.3, green: 0.5, blue: 1.0).opacity(0.4), radius: 12, y: 4)
                }
                .padding(.horizontal, 60)
            }
            
            if viewModel.connectionState == .scanning {
                if let selectedBike = viewModel.selectedBike {
                    VStack(spacing: 20) {
                        Image(systemName: "sensor.tag.radiowaves.forward")
                            .font(.system(size: 56))
                            .foregroundColor(.orange)
                        
                        VStack(spacing: 8) {
                            Text("Chuẩn bị kết nối: \(selectedBike.name)")
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("BƯỚC YÊU CẦU BẮT BUỘC:")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                Text("1. Áp thẻ NFC vào vị trí chữ N trên xe.")
                                Text("2. GIỮ NGUYÊN THẺ và bấm Bắt đầu.")
                                Text("3. Bấm Pair khi iPhone hiện bảng hỏi.")
                                Text("4. Lấy thẻ ra khi app báo Xác thực hoàn tất.")
                            }
                            .font(.caption)
                            .foregroundColor(.orange)
                            .padding()
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(12)
                        }
                        
                        Button(action: { viewModel.connectSelectedBike() }) {
                            HStack {
                                Image(systemName: "bolt.fill")
                                Text("Bắt đầu kết nối")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.orange)
                            .clipShape(Capsule())
                            .shadow(color: Color.orange.opacity(0.4), radius: 12, y: 4)
                        }
                        .padding(.horizontal, 40)
                        
                        Button(action: { viewModel.startScan() }) {
                            Text("Quay lại")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.top, 20)
                } else if viewModel.discoveredBikes.isEmpty {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                        .scaleEffect(1.2)
                        .padding(.top, 10)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Chọn xe để thiết lập lần đầu:")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .padding(.horizontal)
                        
                        ForEach(viewModel.discoveredBikes) { bike in
                            Button {
                                viewModel.selectBike(bike)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(bike.name)
                                            .font(.headline)
                                            .foregroundColor(.white)
                                        Text("Bluetooth LE Device")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing) {
                                        Image(systemName: "wifi")
                                            .foregroundColor(bike.rssi > -65 ? .green : (bike.rssi > -80 ? .orange : .red))
                                        Text("\(bike.rssi) dBm")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                    }
                                }
                                .padding()
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.top, 10)
                }
            }
            
            if viewModel.connectionState.isWorking && viewModel.connectionState != .pairingRequired && viewModel.connectionState != .scanning {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                    .scaleEffect(1.2)
                    .padding(.top, 10)
            }
            
            if viewModel.connectionState == .pairingRequired {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                    .scaleEffect(1.2)
                    .padding(.top, 10)
            }
        }
        .padding(.vertical, 40)
    }
    
    // MARK: - Quick Actions
    
    private var quickActionsView: some View {
        VStack(spacing: 12) {
            Text("ĐIỀU KHIỂN XE")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 12) {
                ActionCard(
                    icon: "shield.fill",
                    title: "Chống trộm",
                    subtitle: "Lock",
                    color: .orange,
                    isActive: viewModel.lockStatus == .armed,
                    action: { viewModel.lock() }
                )
                .disabled(!viewModel.lockStatus.isLocked)
                
                // Tắt xe (0x30 → unlockCmd) — chỉ enable khi xe đang bật
                ActionCard(
                    icon: "power",
                    title: "Tắt xe",
                    subtitle: "Power OFF",
                    color: .red,
                    isActive: false,
                    action: { viewModel.unlock() }
                )
                .disabled(viewModel.lockStatus.isLocked || viewModel.isProcessing)
                
                // Bật xe (0x31 → unlockCmd) — chỉ enable khi xe đang tắt
                ActionCard(
                    icon: "bolt.fill",
                    title: "Bật xe",
                    subtitle: "Power ON",
                    color: .green,
                    isActive: false,
                    action: { viewModel.turnOff() }
                )
                .disabled(!viewModel.lockStatus.isLocked || viewModel.isProcessing)
                
                ActionCard(
                    icon: viewModel.isFinding ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                    title: "Tìm xe",
                    subtitle: viewModel.isFinding ? "Đang kêu" : "Tìm",
                    color: .blue,
                    isActive: viewModel.isFinding,
                    action: { viewModel.findBike() }
                )
                .disabled(!viewModel.lockStatus.isLocked)
                
                ActionCard(
                    icon: "arrow.clockwise",
                    title: "Làm mới",
                    subtitle: "Query",
                    color: .purple,
                    isActive: false,
                    action: { viewModel.refreshStatus() }
                )
            }
        }
    }
}


