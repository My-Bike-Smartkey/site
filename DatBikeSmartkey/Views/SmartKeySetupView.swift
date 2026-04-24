import SwiftUI

struct SmartKeySetupView: View {
    @StateObject private var provisioner = SmartKeyProvisioner()
    @Environment(\.presentationMode) var presentationMode
    
    // Autofill data from the app's current state
    @EnvironmentObject var container: AppDIContainer
    
    @State private var pinInput: String = ""
    @State private var macInput: String = ""
    @State private var frameInput: String = ""
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.08)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Header info
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Bật ESP32 sang chế độ Provisioning (gõ lệnh 'prov' hoặc giữ nút BOOT 3 giây) trước khi bắt đầu.")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .padding(.horizontal)
                        }
                        .padding(.top, 16)
                        
                        // Bước 1: Ghép đôi
                        VStack(alignment: .leading, spacing: 12) {
                            Text("BƯỚC 1: KẾT NỐI KHÓA PHỤ")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.gray)
                                .padding(.horizontal)
                            
                            Button(action: { provisioner.findAndConnect() }) {
                                HStack {
                                    Spacer()
                                    if provisioner.state == .scanning || provisioner.state == .connecting || provisioner.state == .discovering {
                                        ProgressView().padding(.trailing, 4)
                                        Text("Đang kết nối...")
                                            .font(.system(size: 16, weight: .bold))
                                    } else if isConnectedToESP32 {
                                        Image(systemName: "checkmark.circle.fill")
                                        Text("Đã kết nối với Khóa Phụ")
                                            .font(.system(size: 16, weight: .bold))
                                    } else {
                                        Image(systemName: "magnifyingglass")
                                        Text("Tìm và kết nối Khóa Phụ")
                                            .font(.system(size: 16, weight: .bold))
                                    }
                                    Spacer()
                                }
                                .padding()
                                .background(isConnectedToESP32 ? Color.green.opacity(0.2) : Color.cyan.opacity(0.2))
                                .foregroundColor(isConnectedToESP32 ? .green : .cyan)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(isConnectedToESP32 ? Color.green : Color.cyan, lineWidth: 1)
                                )
                            }
                            .disabled(provisioner.state == .scanning || provisioner.state == .connecting || provisioner.state == .discovering)
                            .padding(.horizontal)
                        }
                        
                        // Bước 2: Đồng bộ dữ liệu (Chỉ hiện khi đã kết nối)
                        if isConnectedToESP32 {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("BƯỚC 2: ĐỒNG BỘ DỮ LIỆU")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.gray)
                                    .padding(.horizontal)
                                    .padding(.top, 8)
                                
                                VStack(spacing: 16) {
                                    inputField(title: "MÃ PIN", placeholder: "VD: 1234abcd (tối thiểu 6 ký tự)", text: $pinInput)
                                    inputField(title: "ĐỊA CHỈ MAC XE", placeholder: "VD: C8:EA:F2:XX:YY:ZZ", text: $macInput)
                                    inputField(title: "SỐ KHUNG XE", placeholder: "VD: RLCE123456789", text: $frameInput)
                                }
                                .padding(.horizontal)
                                
                                Button(action: { provisioner.syncData(pin: pinInput, mac: macInput, frame: frameInput) }) {
                                    HStack {
                                        Spacer()
                                        if provisioner.state == .pairingAndWriting {
                                            ProgressView().padding(.trailing, 4)
                                            Text("Đang đồng bộ...")
                                        } else {
                                            Text("ĐỒNG BỘ DỮ LIỆU")
                                        }
                                        Spacer()
                                    }
                                    .font(.system(size: 16, weight: .bold))
                                    .padding()
                                    .background(isSyncDisabled ? Color.gray.opacity(0.3) : Color.cyan)
                                    .foregroundColor(isSyncDisabled ? .gray : .black)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .disabled(isSyncDisabled)
                                .padding(.horizontal)
                                .padding(.top, 8)
                            }
                        }
                        
                        // Status Message
                        statusMessageView
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Cấu hình Khoá Phụ ESP32")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Đóng") {
                        provisioner.cancel()
                        presentationMode.wrappedValue.dismiss()
                    }
                    .foregroundColor(.cyan)
                }
            }
            .onAppear {
                autofillData()
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private var isConnectedToESP32: Bool {
        provisioner.state == .readyToWrite || provisioner.state == .success || provisioner.state == .pairingAndWriting
    }
    
    private var isSyncDisabled: Bool {
        pinInput.count < 6 || provisioner.state == .pairingAndWriting
    }
    
    private func inputField(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
            
            TextField(placeholder, text: text)
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(8)
                .foregroundColor(.white)
                .autocapitalization(.none)
                .disableAutocorrection(true)
        }
    }
    
    @ViewBuilder
    private var statusMessageView: some View {
        HStack {
            switch provisioner.state {
            case .idle:
                EmptyView()
            case .scanning:
                Text("Vui lòng chọn 'Khóa Phụ ESP-Smartkey' ở khung System Picker vừa xuất hiện...")
                    .foregroundColor(.white)
            case .connecting, .discovering:
                Text("Đang kết nối tới mạch...")
                    .foregroundColor(.cyan)
            case .readyToWrite:
                Text("Đã sẵn sàng. Vui lòng kiểm tra thông tin và bấm Đồng bộ.")
                    .foregroundColor(.green)
            case .pairingAndWriting:
                Text("Đang mã hóa dữ liệu. Nhấn 'Pair/Ghép đôi' nếu iOS yêu cầu.")
                    .foregroundColor(.orange)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Đồng bộ thành công! Mạch ESP32 đã lưu thông tin.")
                    .foregroundColor(.green)
            case .error(let msg):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(msg)
                    .foregroundColor(.red)
            }
            Spacer()
        }
        .font(.subheadline)
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
        .opacity(provisioner.state == .idle ? 0 : 1)
    }
    
    private func autofillData() {
        print("[PROV] SmartKeySetupView onAppear: Tạm dừng DatBikeCore...")
        let core = container.bleCore
        core.suspendAutoFeatures()
        
        // Auto-fill from app state to provide seamless UX
        if let savedPin = PreferencesManager.shared.savedPin {
            pinInput = savedPin
        }
        
        // Lấy số khung từ xe đang kết nối, hoặc xe đã lưu
        let dashboard = container.dashboardViewModel
        if dashboard.isConnected && !dashboard.bikeInfo.serial.isEmpty {
            frameInput = dashboard.bikeInfo.serial
        } else if let savedSerial = PreferencesManager.shared.savedBikeSerial {
            frameInput = savedSerial
        }
    }
}
