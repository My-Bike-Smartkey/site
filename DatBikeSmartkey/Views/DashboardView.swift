// DashboardView.swift — Main dashboard with lock control and status

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var container: AppDIContainer
    @ObservedObject var viewModel: DashboardViewModel
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
                            
                            IoTLockStateLabel(lockStatus: viewModel.lockStatus)
                        }
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
            Text("Debug Logs V2 - View from Settings")
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: container.settingsViewModel)
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("MyBike Smartkey")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                
                if !viewModel.bikeInfo.name.isEmpty {
                    Text(viewModel.bikeInfo.name)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
            }
            
            Spacer()
            
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.gray)
                    .padding(10)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            
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
                    action: { viewModel.turnOffBike() }
                )
                .disabled(viewModel.lockStatus.isLocked || viewModel.isProcessing)
                
                // Bật xe (0x31 → unlockCmd) — chỉ enable khi xe đang tắt
                ActionCard(
                    icon: "bolt.fill",
                    title: "Bật xe",
                    subtitle: "Power ON",
                    color: .green,
                    isActive: false,
                    action: { viewModel.turnOnBike() }
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


