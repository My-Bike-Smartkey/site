import Foundation
import CoreBluetooth
import Combine
import UIKit
#if canImport(AccessorySetupKit)
import AccessorySetupKit
#endif

/// ASKManager — cầu nối AccessorySetupKit (iOS 18+), theo chuẩn Apple
/// "Discovering and configuring accessories"
/// (developer.apple.com/documentation/accessorysetupkit/discovering-and-configuring-accessories).
///
/// Bản chất ASK: cửa MỘT LẦN lúc ghép đôi (scoped Bluetooth permission) —
/// KHÔNG phát event proximity/kết nối. Reconnect khi lại gần xe là việc của
/// CoreBluetooth (pending connect + bluetooth-central + state restoration).
///
/// Các quy tắc Apple đã khắc phục so với bản cũ:
///  F1  Mỗi descriptor PHẢI có bluetoothServiceUUID/companyIdentifier VÀ ít nhất
///      1 identifier phụ (bluetoothNameSubstring) — service đơn độc không đạt chuẩn.
///      Mọi giá trị đều phải nằm trong Info.plist (NSAccessorySetupBluetooth*)
///      nếu không app crash.
///  F2  `session.accessories` chỉ đáng tin SAU event `.activated` → track
///      isActivated. showPicker() chỉ được gọi từ user gesture (startPairing),
///      không bao giờ tự mở (cold-launch / error path).
///  F3  showPicker completion chạy ở CẢ hai nhánh (user chọn xong HOẶC cancel)
///      → onPickerDismissed luôn fire đúng 1 lần mỗi lần mở picker.
///      Xử lý thêm pickerDidPresent/pickerDidDismiss theo Apple sample.
///  F4  `.accessoryRemoved` → onAccessoryRemoved(uuid) để core dọn pairing cũ
///      (user gỡ xe trong Settings iOS).
///  F5  `.accessoryChanged` (đổi tên/thông tin) tách khỏi `.accessoryAdded` —
///      KHÔNG trigger connect.
@available(iOS 18.0, *)
final class ASKManager: NSObject {
    static let shared = ASKManager()

    // MARK: - Trạng thái (F2)

    /// Đã nhận `.activated` từ hệ thống. `accessories` / `hasAuthorizedAccessory`
    /// chỉ đáng tin khi cờ này true. Reset khi session bị invalidate.
    @Published private(set) var isActivated = false

    // MARK: - Callbacks

    /// User vừa chọn xe trong picker (uuid = bluetoothIdentifier cho CoreBluetooth).
    var onAccessorySelected: ((UUID) -> Void)?

    /// F4: accessory bị gỡ khỏi hệ thống (Settings iOS) với UUID khớp.
    var onAccessoryRemoved: ((UUID) -> Void)?

    /// F3: picker đã đóng — chọn xong hoặc cancel. Fire đúng 1 lần/lần mở.
    var onPickerDismissed: ((Error?) -> Void)?

    private var session: ASAccessorySession?

    /// Đúng khi session đã activate VÀ có ít nhất 1 accessory đã authorize.
    /// Trước `.activated` luôn false — caller phải chờ `isActivated` (F2).
    var hasAuthorizedAccessory: Bool {
        guard isActivated else { return false }
        #if canImport(AccessorySetupKit)
        return !(session?.accessories.isEmpty ?? true)
        #else
        return false
        #endif
    }

    // MARK: - Vòng đời

    override private init() {
        super.init()
        #if canImport(AccessorySetupKit)
        let s = ASAccessorySession()
        s.activate(on: .main) { [weak self] event in
            self?.handleSessionEvent(event)
        }
        session = s
        #endif
    }

    // MARK: - Picker (F1 + F2)

    /// CHỈ gọi từ user gesture (nút "Thêm xe", xác nhận ghép đôi...).
    /// Mọi giá trị descriptor phải được khai báo trong Info.plist — Apple
    /// crash app nếu match giá trị chưa khai báo.
    func showPicker() {
        #if canImport(AccessorySetupKit)
        // F1: service UUID + name substring cho MỌI descriptor (chuẩn Apple).
        // Names "Dat Bike"/"QT_" đã có trong NSAccessorySetupBluetoothNames;
        // 2 service UUID đã có trong NSAccessorySetupBluetoothServices.
        let names = ["Dat Bike", "QT_"]
        let services = [
            "0000FCF1-0000-1000-8000-00805F9B34FB",   // SmartKey service
            "10CB0217-FF02-4474-A1EF-6FD88B5BDAEA"     // Auth service
        ]

        var items: [ASPickerDisplayItem] = []
        if let bikeImage = UIImage(named: "PickerBike") ?? UIImage(systemName: "motorcycle.fill") {
            for service in services {
                for name in names {
                    let desc = ASDiscoveryDescriptor()
                    desc.bluetoothServiceUUID = CBUUID(string: service)
                    desc.bluetoothNameSubstring = name
                    items.append(ASPickerDisplayItem(
                        name: "Xe máy điện DAT BIKE QUANTUM",
                        productImage: bikeImage,
                        descriptor: desc
                    ))
                }
            }
        }

        guard !items.isEmpty else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "ASKManager: không tạo được picker items (thiếu ảnh/asset)"))
            onPickerDismissed?(nil)
            return
        }

        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "ASKManager: Kích hoạt System Picker (user gesture)"))

        session?.showPicker(for: items) { [weak self] error in
            guard let self else { return }
            if let error {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "ASK picker đóng với lỗi: \(error.localizedDescription)"))
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "ASK picker đã đóng (chọn xong hoặc cancel)"))
            }
            // F3: completion chạy ở CẢ HAI trường hợp — user cancel (error nil,
            // không chọn) cũng phải báo để caller reset isProcessing/UI.
            self.onPickerDismissed?(error)
        }
        #else
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
            message: "AccessorySetupKit không được hỗ trợ trên thiết bị này"))
        onPickerDismissed?(nil)
        #endif
    }

    // MARK: - Gỡ accessory

    func removeAccessory(withUUID uuidString: String) {
        #if canImport(AccessorySetupKit)
        guard let targetUUID = UUID(uuidString: uuidString) else { return }
        let accessories = session?.accessories ?? []
        for accessory in accessories where accessory.bluetoothIdentifier == targetUUID {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASKManager: Yêu cầu xóa (Unpair) phụ kiện \(uuidString) khỏi iOS"))
            Task {
                // Bridge async của ObjC completion API
                do {
                    try await session?.removeAccessory(accessory)
                } catch {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "ASK removeAccessory lỗi: \(error.localizedDescription)"))
                }
            }
        }
        #endif
    }

    // MARK: - Events (F3 + F4 + F5)

    #if canImport(AccessorySetupKit)
    private func handleSessionEvent(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            isActivated = true
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK Event: Session Activated (accessories=\(session?.accessories.count ?? 0))"))

        case .accessoryAdded:
            if let accessory = event.accessory, let uuid = accessory.bluetoothIdentifier {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "ASK Event: accessoryAdded (UUID: \(uuid.uuidString.prefix(8)))"))
                onAccessorySelected?(uuid)
            }

        case .accessoryChanged:
            // F5: chỉ đổi tên/thông tin của accessory ĐÃ ghép — không connect lại.
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK Event: accessoryChanged (đổi tên/thông tin — bỏ qua, không connect)"))

        case .accessoryRemoved:
            // F4: user gỡ xe trong Settings iOS → core dọn pairing nếu khớp.
            if let accessory = event.accessory, let uuid = accessory.bluetoothIdentifier {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "ASK Event: accessoryRemoved (UUID: \(uuid.uuidString.prefix(8)))"))
                onAccessoryRemoved?(uuid)
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "ASK Event: accessoryRemoved (không kèm UUID — bỏ qua)"))
            }

        case .pickerDidPresent:
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK Event: pickerDidPresent"))

        case .pickerDidDismiss:
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK Event: pickerDidDismiss"))

        case .invalidated:
            isActivated = false
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "ASK Event: Session Invalidated"))

        case .migrationComplete:
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK Event: migrationComplete"))

        @unknown default:
            break
        }
    }
    #endif
}
