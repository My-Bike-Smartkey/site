// SettingsView.swift — Settings, device info, auto-unlock config, and debug log

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct SettingsView: View {
    @EnvironmentObject var container: AppDIContainer
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showConnectionGuide = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Cài đặt ứng dụng")) {
                    NavigationLink(destination: MyBikeSettingsView(viewModel: viewModel).environmentObject(container)) {
                        HStack {
                            Image(systemName: "bicycle")
                                .foregroundColor(.cyan)
                                .frame(width: 24)
                            Text("Xe của tôi")
                        }
                    }
                    
                    NavigationLink(destination: ConnectionSettingsView(viewModel: viewModel)) {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(.green)
                                .frame(width: 24)
                            Text("Kết nối")
                        }
                    }
                    
                    NavigationLink(destination: NotificationSettingsView(viewModel: viewModel)) {
                        HStack {
                            Image(systemName: "bell.badge.fill")
                                .foregroundColor(.orange)
                                .frame(width: 24)
                            Text("Thông báo")
                        }
                    }
                    
                    NavigationLink(destination: DeveloperSettingsView(viewModel: viewModel)) {
                        HStack {
                            Image(systemName: "hammer.fill")
                                .foregroundColor(.purple)
                                .frame(width: 24)
                            Text("Chế độ nhà phát triển")
                        }
                    }
                }
                
                Section(header: Text("Khóa phụ")) {
                    NavigationLink(destination: SmartKeyManageView()
                        .environmentObject(container)) {
                        HStack {
                            Image(systemName: "cpu.fill")
                                .foregroundColor(.cyan)
                                .frame(width: 24)
                            Text("Khóa phụ ESP32")
                            Spacer()
                            if PreferencesManager.shared.savedESP32UUID != nil {
                                Text("Đã cấu hình")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            } else {
                                Text("Chưa cấu hình")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
                
                Section(header: Text("Hỗ trợ"), footer: VStack(alignment: .leading, spacing: 4) {
                    Text("D-SmartKey v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    Text("Sản phẩm được tạo bởi tình yêu dành cho chiếc xe Datbike của tôi.")
                }) {
                    Button(action: {
                        showConnectionGuide = true
                    }) {
                        HStack {
                            Image(systemName: "book.pages.fill")
                                .foregroundColor(.blue)
                                .frame(width: 24)
                            Text("Nguyên lý kết nối & Trạng thái")
                                .foregroundColor(.primary)
                        }
                    }
                    
                    Link(destination: URL(string: "https://t.me/+w9mYyeKjcLxlMDI1")!) {
                        HStack {
                            Image(systemName: "paperplane.fill")
                                .foregroundColor(Color(red: 0.15, green: 0.68, blue: 0.93))
                                .frame(width: 24)
                            Text("Cộng đồng D-SmartKey")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    
                    VStack(alignment: .center, spacing: 12) {
                        Text("Nếu app hữu ích, bạn có thể ủng hộ tác giả 🙏")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .padding(.top, 8)
                        
                        QRCodeView(content: "00020101021138630010A000000727013300069710250119PSP26089156000002310208QRIBFTTA53037045802VN62190515MOMOW2W3637058263049C27", size: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                        
                        VStack(spacing: 2) {
                            Text("NGUYỄN PHÚC TÚ")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("*******135")
                                .font(.caption)
                                .foregroundColor(.gray)
                            HStack(spacing: 6) {
                                Text("MoMo")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(Color(red: 0.87, green: 0.18, blue: 0.49))
                                Text("•")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                                Text("VietQR")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(Color(red: 0.87, green: 0.10, blue: 0.14))
                                Text("•")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                                Text("Napas 247")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(Color(red: 0.10, green: 0.65, blue: 0.25))
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Cài đặt")
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showConnectionGuide) {
            ConnectionGuideView()
        }
    }
}

// MARK: - Connection Guide View
struct ConnectionGuideView: View {
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.1, green: 0.1, blue: 0.12).ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Hiểu về kết nối D-SmartKey")
                            .font(.title2).bold()
                            .foregroundColor(.white)
                        
                        guideSection(
                            icon: "magnifyingglass", iconColor: .blue,
                            title: "1. Đang tìm xe",
                            content: "Điện thoại đang liên tục quét các sóng Bluetooth Low Energy (BLE) xung quanh để phát hiện xe Dat Bike của bạn. Trạng thái này thường mất từ 1-3 giây mỗi khi mở app."
                        )
                        
                        guideSection(
                            icon: "point.3.connected.trianglepath.dotted", iconColor: .orange,
                            title: "2. Đang kết nối & Xác thực",
                            content: "Ứng dụng đã tìm thấy sóng của xe và tiến hành thiết lập liên kết an toàn."
                        )
                        
                        guideSection(
                            icon: "sensor.tag.radiowaves.forward", iconColor: .green,
                            title: "3. Ngưỡng tự động kết nối",
                            content: "Mặc định, khi xe phát hiện bạn trong phạm vi phát sóng đủ lớn của 'Ngưỡng kết nối', biểu tượng Bluetooth trên mặt đồng hồ xe sẽ sáng nháp báo hiệu sự kết nối vật lý đã sẵn sàng. Bạn càng kéo thanh này về phía 'Xa' (như -80), xe sẽ bắt sóng bạn càng sớm."
                        )
                        
                        guideSection(
                            icon: "bolt.fill", iconColor: .yellow,
                            title: "4. Ngưỡng tự động bật xe",
                            content: "Nếu bạn đã bật tính năng này, sau khi kết nối, hệ thống sẽ tiếp tục đợi. Chỉ khi bạn tiến lại đủ gần chạm trúng vào 'Ngưỡng bật xe' (như -60), ứng dụng mới xuất lệnh đánh thức và BẬT HỆ THỐNG ĐIỆN của xe hoàn toàn."
                        )
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Mẹo thiết lập")
                                .font(.headline).foregroundColor(.white)
                            Text("• Luôn giữ Ngưỡng bật xe ĐẬM (Gần) hơn Ngưỡng kết nối để tránh việc xe tự bật sáng khi bạn chỉ đang lướt ngang qua sân nhà.")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(12)
                    }
                    .padding()
                    .padding(.top, 10)
                }
            }
            .navigationTitle("Trợ giúp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { presentationMode.wrappedValue.dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private func guideSection(icon: String, iconColor: Color, title: String, content: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(iconColor)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(content)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .lineSpacing(2)
            }
        }
    }
}


struct MyBikeSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showBatteryAnalytics = false
    @State private var showForgetConfirm = false
    @EnvironmentObject var container: AppDIContainer
    
    var body: some View {
        Form {
            let hasSavedBike = PreferencesManager.shared.savedBikeSerial != nil && PreferencesManager.shared.savedBikeSerial?.isEmpty == false
            let isConnectedWithInfo = viewModel.isConnected && !viewModel.bikeInfo.isEmpty
            
            if isConnectedWithInfo || hasSavedBike {
                Section(header: Text("Thông tin cơ bản")) {
                    HStack {
                        Image(systemName: "bicycle")
                            .foregroundColor(.cyan)
                            .frame(width: 24)
                        Text("Tên")
                        Spacer()
                        Text(isConnectedWithInfo ? viewModel.bikeInfo.name : (PreferencesManager.shared.savedBikeName ?? "Dat Bike"))
                            .foregroundColor(.gray)
                    }
                    
                    // Model — hiển thị từ BLE hoặc cache offline
                    let modelStr = isConnectedWithInfo ? viewModel.bikeInfo.model : (PreferencesManager.shared.savedBikeModel ?? "")
                    if !modelStr.isEmpty {
                        HStack {
                            Image(systemName: "cpu")
                                .foregroundColor(.cyan)
                                .frame(width: 24)
                            Text("Model")
                            Spacer()
                            Text(modelStr)
                                .foregroundColor(.gray)
                        }
                    }
                    
                    HStack {
                        Image(systemName: "number")
                            .foregroundColor(.cyan)
                            .frame(width: 24)
                        Text("Số khung")
                        Spacer()
                        Text(isConnectedWithInfo ? viewModel.bikeInfo.serial : (PreferencesManager.shared.savedBikeSerial ?? ""))
                            .foregroundColor(.gray)
                    }
                    
                    // Firmware — hiển thị từ BLE hoặc cache offline
                    let fwStr = isConnectedWithInfo ? viewModel.bikeInfo.firmware : (PreferencesManager.shared.savedBikeFirmware ?? "")
                    if !fwStr.isEmpty {
                        HStack {
                            Image(systemName: "gearshape.fill")
                                .foregroundColor(.cyan)
                                .frame(width: 24)
                            Text("Firmware")
                            Spacer()
                            Text(fwStr)
                                .foregroundColor(.gray)
                        }
                    }
                    
                    // MAC Address — hiển thị luôn nếu có (quan trọng cho ESP32 SmartKey)
                    if let macStr = PreferencesManager.shared.savedBikeMac, !macStr.isEmpty {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(.cyan)
                                .frame(width: 24)
                            Text("MAC")
                            Spacer()
                            Text(macStr)
                                .foregroundColor(.gray)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = macStr
                            } label: {
                                Label("Sao chép MAC", systemImage: "doc.on.doc")
                            }
                        }
                    }
                    
                    if isConnectedWithInfo && !viewModel.bikeInfo.deviceToken.isEmpty {
                        HStack {
                            Image(systemName: "key")
                                .foregroundColor(.cyan)
                                .frame(width: 24)
                            Text("Token")
                            Spacer()
                            Text(String(viewModel.bikeInfo.deviceToken.prefix(16)) + "…")
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                    }
                    
                    if !viewModel.isConnected {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .frame(width: 24)
                            Text("Trạng thái")
                            Spacer()
                            Text("Chưa kết nối")
                                .foregroundColor(.orange)
                        }
                    }
                }
                
                Section(header: Text("Quản lý")) {
                    if viewModel.isConnected {
                        Button {
                            showBatteryAnalytics = true
                        } label: {
                            HStack {
                                Image(systemName: "battery.100.bolt")
                                    .foregroundColor(.green)
                                    .frame(width: 24)
                                Text("Phân tích Pin (BMS)")
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                    
                    Button {
                        viewModel.syncTime()
                    } label: {
                        HStack {
                            Image(systemName: "clock.fill")
                                .foregroundColor(.blue)
                                .frame(width: 24)
                            Text(viewModel.isSyncingTime ? "Đang đồng bộ..." : "Đồng bộ giờ xe")
                                .foregroundColor(viewModel.isConnected ? .primary : .gray)
                            Spacer()
                            if viewModel.isSyncingTime {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!viewModel.isConnected || viewModel.isSyncingTime)
                }
                
                Section {
                    Button(role: .destructive) {
                        showForgetConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "trash.fill")
                                .frame(width: 24)
                            Text("Bỏ liên kết xe")
                        }
                    }
                }
            } else {
                Text("Chưa có thông tin xe.")
                    .foregroundColor(.gray)
            }
        }
        .navigationTitle("Xe của tôi")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBatteryAnalytics) {
            BatteryAnalyticsView(viewModel: container.batteryViewModel)
        }
        .alert("Bỏ liên kết xe", isPresented: $showForgetConfirm) {
            Button("Quên", role: .destructive) {
                viewModel.forgetBike()
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Xóa kết nối App với xe. Bạn có muốn tiếp tục?")
        }
    }
}


struct ConnectionSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    
    var body: some View {
        Form {
            Section(header: Text("Tự động kết nối"), footer: Text("Khi đạt ngưỡng này điện thoại sẽ tự động kết nối, biểu tượng bluetooth trên đồng hồ xe sẽ sáng.")) {
                Toggle(isOn: $viewModel.connectOnlyWhenNear) {
                    HStack {
                        Image(systemName: "sensor.tag.radiowaves.forward")
                            .foregroundColor(.green)
                            .frame(width: 24)
                        Text("Ngưỡng tự động kết nối với xe")
                    }
                }
                .tint(.green)
                
                if viewModel.connectOnlyWhenNear {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Độ nhạy: ")
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text("\(Int(viewModel.rssiThreshold)) dBm")
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(viewModel.rssiThreshold >= -65 ? "Gần" : (viewModel.rssiThreshold >= -75 ? "Vừa" : "Xa"))
                                .font(.caption2)
                                .foregroundColor(viewModel.rssiThreshold >= -65 ? .green : (viewModel.rssiThreshold >= -75 ? .orange : .red))
                        }
                        Slider(value: $viewModel.rssiThreshold, in: -95...(-50), step: 1.0)
                            .tint(.green)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            Section(header: Text("Tự động bật xe"), footer: Text("Khi đã kết nối, nếu đạt ngưỡng này và xe đang tắt thì tự động bật lên.")) {
                Toggle(isOn: $viewModel.autoUnlockEnabled) {
                    HStack {
                        Image(systemName: "bolt.fill")
                            .foregroundColor(.orange)
                            .frame(width: 24)
                        Text("Ngưỡng tự động bật xe")
                    }
                }
                .tint(.orange)
                
                if viewModel.autoUnlockEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Độ nhạy: ")
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text("\(Int(viewModel.autoTurnOnThreshold)) dBm")
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(viewModel.autoTurnOnThreshold >= -60 ? "Gần" : (viewModel.autoTurnOnThreshold >= -70 ? "Vừa" : "Xa"))
                                .font(.caption2)
                                .foregroundColor(viewModel.autoTurnOnThreshold >= -60 ? .green : (viewModel.autoTurnOnThreshold >= -70 ? .orange : .red))
                        }
                        Slider(value: $viewModel.autoTurnOnThreshold, in: -90...(-40), step: 1.0)
                            .tint(.orange)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Kết nối")
        .navigationBarTitleDisplayMode(.inline)
    }
}


struct DeveloperSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showLogs = false
    
    var body: some View {
        Form {
            Section(header: Text("Nhật ký hệ thống")) {
                Button {
                    showLogs = true
                } label: {
                    HStack {
                        Image(systemName: "list.bullet.rectangle.portrait")
                            .foregroundColor(.blue)
                            .frame(width: 24)
                        Text("Xem nhật ký đầy đủ (Full Logs)")
                            .foregroundColor(.primary)
                    }
                }
                
                Toggle(isOn: $viewModel.isLoggingEnabled) {
                    HStack {
                        Image(systemName: "doc.text.fill")
                            .foregroundColor(.purple)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ghi nhật ký BLE")
                            Text("Lưu log INFO/SUCCESS/WARNING/ERROR. TẮT để tiết kiệm pin.")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .tint(.purple)
                
                Toggle(isOn: $viewModel.verboseLoggingEnabled) {
                    HStack {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundColor(.indigo)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Log chi tiết (Verbose)")
                            Text("Ghi thêm RSSI mỗi 2s, STANDBY_CHECK... Chỉ bật khi cần debug sâu.")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .tint(.indigo)
                .disabled(!viewModel.isLoggingEnabled)
            }
            
            Section(header: Text("Bảo mật log"), footer: Text("Khi bật, số khung xe sẽ bị ẩn (thay bằng ***) trong log chia sẻ. Mặc định BẬT.")) {
                Toggle(isOn: $viewModel.redactFrameNumber) {
                    HStack {
                        Image(systemName: "eye.slash.fill")
                            .foregroundColor(.mint)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ẩn số khung xe trong log")
                            Text("Bảo vệ quyền riêng tư khi gửi log cho nhà phát triển.")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .tint(.mint)
            }
            
            Section(header: Text("Nâng cao"), footer: Text("Không gửi token lân cận khi xác thực (dùng khi test ASK)")) {
                Toggle(isOn: $viewModel.skipProximityToken) {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .foregroundColor(.orange)
                            .frame(width: 24)
                        Text("Bỏ qua Proximity Token")
                    }
                }
                .tint(.orange)
            }
        }
        .navigationTitle("Nhà phát triển")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogs) {
            LogView(logs: PersistentLogger.shared.loadLogs(daysBack: 1))
        }
    }
}


struct NotificationSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    
    var body: some View {
        Form {
            Section(header: Text("Chung"), footer: Text("Bật/tắt toàn bộ thông báo của app")) {
                Toggle(isOn: $viewModel.notificationsEnabled) {
                    HStack {
                        Image(systemName: "bell.badge.fill")
                            .foregroundColor(.orange)
                            .frame(width: 24)
                        Text("Thông báo hệ thống")
                    }
                }
                .tint(.orange)
            }
            
            if viewModel.notificationsEnabled {
                Section(header: Text("Loại thông báo")) {
                    notificationSubToggle(
                        icon: "checkmark.circle.fill", iconColor: .green,
                        title: "Kết nối thành công", subtitle: "Khi xác thực BLE hoàn tất",
                        binding: $viewModel.notifyOnConnected
                    )
                    notificationSubToggle(
                        icon: "figure.walk", iconColor: .cyan,
                        title: "Gần xe — Kết nối chờ", subtitle: "Khi phát hiện di chuyển gần xe",
                        binding: $viewModel.notifyOnStandby
                    )
                    notificationSubToggle(
                        icon: "arrow.uturn.backward.circle.fill", iconColor: .yellow,
                        title: "Ra xa xe — Chuyển chờ", subtitle: "Khi phát hiện di chuyển ra xa",
                        binding: $viewModel.notifyOnDisconnected
                    )
                    notificationSubToggle(
                        icon: "bolt.fill", iconColor: .orange,
                        title: "Tự động bật xe", subtitle: "Khi Auto Turn-On được kích hoạt",
                        binding: $viewModel.notifyOnAutoTurnOn
                    )
                    notificationSubToggle(
                        icon: "battery.100.bolt", iconColor: .green,
                        title: "Sạc đầy pin", subtitle: "Khi pin đạt 100%",
                        binding: $viewModel.notifyOnBatteryFull
                    )
                    notificationSubToggle(
                        icon: "bolt.slash.fill", iconColor: .red,
                        title: "Ngắt sạc bất ngờ", subtitle: "Báo động khi mất sạc lúc xe tắt",
                        binding: $viewModel.notifyOnChargeDisconnect
                    )
                    notificationSubToggle(
                        icon: "battery.25", iconColor: .orange,
                        title: "Cảnh báo pin yếu", subtitle: "Khi pin giảm xuống dưới ngưỡng",
                        binding: $viewModel.notifyOnBatteryThreshold
                    )
                    
                    if viewModel.notifyOnBatteryThreshold {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Ngưỡng cảnh báo: ")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                                Text("\(Int(viewModel.batteryLowThreshold))%")
                                    .font(.system(.caption, design: .monospaced))
                                Spacer()
                            }
                            Slider(value: $viewModel.batteryLowThreshold, in: 5...50, step: 1.0)
                                .tint(.orange)
                        }
                        .padding(.vertical, 4)
                        .animation(.easeInOut, value: viewModel.notifyOnBatteryThreshold)
                    }
                }
            }
            
            Section(header: Text("Tiện ích")) {
                Toggle(isOn: $viewModel.widgetAndLiveActivityEnabled) {
                    HStack {
                        Image(systemName: "bolt.badge.clock.fill")
                            .foregroundColor(.yellow)
                            .frame(width: 24)
                        Text("Bật Widget & Live Activity")
                    }
                }
                .tint(Color(red: 0.0, green: 0.96, blue: 1.0))
            }
        }
        .navigationTitle("Thông báo")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func notificationSubToggle(icon: String, iconColor: Color, title: String, subtitle: String, binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
        }
        .tint(iconColor)
    }
}

// MARK: - Log View

struct LogView: View {
    @State var logs: [BLELogEntry]
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirm = false
    @State private var showShareSheet = false
    @State private var shareURL: URL? = nil
    
    init(logs: [BLELogEntry]) {
        self._logs = State(initialValue: logs)
    }
    
    /// Danh sách keyword nhạy cảm — log chứa keyword này sẽ bị ẩn
    private static let sensitiveKeywords = [
        "SHA", "hash", "PIN", "pin", "auth", "Auth",
        "challenge", "counter", "nonce", "token", "Token",
        "session", "proximity", "Xác thực", "xác thực",
        "NOTIFY", "serviceChanged"
    ]
    
    /// Hiển thị toàn bộ nhật ký theo yêu cầu
    private var filteredLogs: [BLELogEntry] {
        return logs
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.08)
                    .ignoresSafeArea()
                
                if filteredLogs.isEmpty {
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
                            ForEach(filteredLogs.reversed()) { entry in
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
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button {
                        var fullString = filteredLogs.reversed().map { "[\($0.formattedTime)] \($0.level.rawValue) \($0.message)" }.joined(separator: "\n")
                        // Ẩn số khung xe nếu đã bật
                        if PreferencesManager.shared.redactFrameNumber,
                           let serial = PreferencesManager.shared.savedBikeSerial, !serial.isEmpty {
                            fullString = fullString.replacingOccurrences(of: serial, with: "***REDACTED***")
                        }
                        UIPasteboard.general.string = fullString
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    
                    Button {
                        let redact = PreferencesManager.shared.redactFrameNumber
                        let text = PersistentLogger.shared.exportAllAsText(redactFrameNumber: redact)
                        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("datbike_ble_logs.txt")
                        try? text.write(to: tempFile, atomically: true, encoding: .utf8)
                        shareURL = tempFile
                        showShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    
                    Button("Đóng") { dismiss() }
                        .foregroundColor(.blue)
                }
            }
            .alert("Xóa toàn bộ Log?", isPresented: $showClearConfirm) {
                Button("Xóa", role: .destructive) {
                    PersistentLogger.shared.clearAll()
                    logs.removeAll()
                }
                Button("Hủy", role: .cancel) {}
            } message: {
                Text("Hành động này sẽ xóa vĩnh viễn toàn bộ lịch sử kết nối lưu trên máy.")
            }
            .background(
                ActivityViewPresenter(isPresented: $showShareSheet, activityItems: [shareURL].compactMap { $0 })
            )
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }
}

struct ActivityViewPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        return vc
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        let isActivityShown = uiViewController.presentedViewController is UIActivityViewController
        
        if isPresented && !isActivityShown {
            let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
            controller.completionWithItemsHandler = { _, _, _, _ in
                self.isPresented = false
            }
            
            if let popover = controller.popoverPresentationController {
                popover.sourceView = uiViewController.view
                popover.sourceRect = CGRect(x: uiViewController.view.bounds.midX, y: uiViewController.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            
            uiViewController.present(controller, animated: true)
        }
    }
}

// MARK: - Live Time Text
struct LiveTimeText: View {
    @State private var currentTime = Date()
    
    var body: some View {
        Text(currentVNTimeString(currentTime))
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.gray)
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { input in
                currentTime = input
            }
    }
    
    private func currentVNTimeString(_ date: Date) -> String {
        let vnTZ = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        let formatter = DateFormatter()
        formatter.timeZone = vnTZ
        formatter.dateFormat = "HH:mm:ss (dd/MM/yyyy)"
        return formatter.string(from: date)
    }
}

// MARK: - QR Code View
struct QRCodeView: View {
    let content: String
    let size: CGFloat
    @State private var cachedImage: UIImage?
    
    var body: some View {
        Group {
            if let image = cachedImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Color.white.frame(width: size, height: size)
                    .overlay(ProgressView())
            }
        }
        .onAppear {
            Task {
                if cachedImage == nil {
                    cachedImage = generateQRCode(from: content)
                }
            }
        }
    }
    
    private func generateQRCode(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scale = size / ciImage.extent.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let inverted = CIFilter(name: "CIColorInvert", parameters: [kCIInputImageKey: scaled])?.outputImage,
              CIFilter(name: "CIMaskToAlpha", parameters: [kCIInputImageKey: inverted])?.outputImage != nil else {
            let context = CIContext()
            if let cgImage = context.createCGImage(scaled, from: scaled.extent) {
                return UIImage(cgImage: cgImage)
            }
            return nil
        }
        let bg = CIImage(color: CIColor.white).cropped(to: scaled.extent)
        guard let composed = CIFilter(name: "CISourceOverCompositing",
                                      parameters: [kCIInputImageKey: scaled,
                                         kCIInputBackgroundImageKey: bg])?.outputImage else { return nil }
        let context = CIContext()
        guard let cgImage = context.createCGImage(composed, from: composed.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
