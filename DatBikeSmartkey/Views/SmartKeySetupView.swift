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
                            Text("Bật ESP32 sang chế độ Provisioning (bằng cách gõ lệnh 'prov' hoặc giữ nút BOOT 3 giây) trước khi bắt đầu.")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .padding(.horizontal)
                        }
                        .padding(.top, 16)
                        
                        // Form fields
                        VStack(spacing: 16) {
                            inputField(title: "MÃ PIN", placeholder: "VD: 1234abcd (tối thiểu 6 ký tự)", text: $pinInput)
                            inputField(title: "ĐỊA CHỈ MAC XE", placeholder: "VD: C8:EA:F2:XX:YY:ZZ", text: $macInput)
                            inputField(title: "SỐ KHUNG XE", placeholder: "VD: RLCE123456789", text: $frameInput)
                        }
                        .padding(.horizontal)
                        
                        // Status Message
                        statusMessageView
                            .padding(.horizontal)
                            .padding(.top, 8)
                        
                        // Action Button
                        Button(action: startProvisioning) {
                            HStack {
                                Spacer()
                                Text(buttonTitle)
                                    .font(.system(size: 16, weight: .bold))
                                Spacer()
                            }
                            .padding()
                            .background(isButtonDisabled ? Color.gray.opacity(0.3) : Color.cyan)
                            .foregroundColor(isButtonDisabled ? .gray : .black)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(isButtonDisabled)
                        .padding(.horizontal)
                        .padding(.top, 16)
                    }
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
    
    private var isButtonDisabled: Bool {
        pinInput.count < 6 || provisioner.state == .scanning || provisioner.state == .connecting || provisioner.state == .discovering || provisioner.state == .pairingAndWriting
    }
    
    private var buttonTitle: String {
        switch provisioner.state {
        case .scanning, .connecting, .discovering, .pairingAndWriting:
            return "Đang xử lý..."
        default:
            return "BẮT ĐẦU GHI VÀO ESP32"
        }
    }
    
    @ViewBuilder
    private var statusMessageView: some View {
        HStack {
            switch provisioner.state {
            case .idle:
                EmptyView()
            case .scanning:
                ProgressView().padding(.trailing, 4)
                Text("Đang quét tìm mạch ESP-Smartkey...")
                    .foregroundColor(.white)
            case .connecting, .discovering:
                ProgressView().padding(.trailing, 4)
                Text("Đang kết nối tới mạch...")
                    .foregroundColor(.cyan)
            case .pairingAndWriting:
                ProgressView().padding(.trailing, 4)
                Text("Đang mã hóa dữ liệu. Nhấn 'Pair/Ghép đôi' nếu iOS yêu cầu.")
                    .foregroundColor(.orange)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Cấu hình thành công! Mạch ESP32 đã lưu thông tin.")
                    .foregroundColor(.green)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
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
    
    private func startProvisioning() {
        provisioner.startProvisioning(pin: pinInput, mac: macInput, frame: frameInput)
    }
    
    private func autofillData() {
        print("[PROV] Đang tạm dừng DatBikeCore để nhường sóng BLE cho Provisioner...")
        let core = container.bleCore
        core.suspendAutoFeatures()
        core.forceStopScan()
        
        // Auto-fill from app state to provide seamless UX
        if let savedPin = PreferencesManager.shared.savedPin {
            pinInput = savedPin
        }
        
        let dashboard = container.dashboardViewModel
        if dashboard.isConnected {
            frameInput = dashboard.bikeInfo.serial
        }
    }
}
