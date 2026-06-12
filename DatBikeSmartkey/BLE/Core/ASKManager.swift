import Foundation
import CoreBluetooth
import Combine
import UIKit
#if canImport(AccessorySetupKit)
import AccessorySetupKit
#endif

@available(iOS 18.0, *)
class ASKManager: NSObject {
    static let shared = ASKManager()
    
    #if canImport(AccessorySetupKit)
    private var session: ASAccessorySession?
    #endif
    
    var onAccessorySelected: ((UUID) -> Void)?
    var onPickerDismissed: ((Error?) -> Void)?
    
    
    var hasAuthorizedAccessory: Bool {
        #if canImport(AccessorySetupKit)
        return !(session?.accessories.isEmpty ?? true)
        #else
        return false
        #endif
    }
    
    override private init() {
        super.init()
        #if canImport(AccessorySetupKit)
        self.session = ASAccessorySession()
        self.session?.activate(on: .main, eventHandler: { [weak self] event in
            self?.handleSessionEvent(event)
        })
        #endif
    }
    
    deinit {
        #if canImport(AccessorySetupKit)
        self.session?.invalidate()
        #endif
    }
    
    func showPicker() {
        #if canImport(AccessorySetupKit)
        let desc1 = ASDiscoveryDescriptor()
        desc1.bluetoothServiceUUID = CBUUID(string: "0000FCF1-0000-1000-8000-00805F9B34FB")
        
        let desc2 = ASDiscoveryDescriptor()
        desc2.bluetoothServiceUUID = CBUUID(string: "10CB0217-FF02-4474-A1EF-6FD88B5BDAEA") // Auth
        
        // Name substring descriptor 
        let desc3 = ASDiscoveryDescriptor()
        desc3.bluetoothServiceUUID = CBUUID(string: "0000FCF1-0000-1000-8000-00805F9B34FB")
        desc3.bluetoothNameSubstring = "Dat Bike"
        
        let desc4 = ASDiscoveryDescriptor()
        desc4.bluetoothServiceUUID = CBUUID(string: "0000FCF1-0000-1000-8000-00805F9B34FB")
        desc4.bluetoothNameSubstring = "QT_"
        
        let bikeImage = UIImage(named: "PickerBike") ?? UIImage(systemName: "motorcycle.fill") ?? UIImage()
        
        let items = [
            ASPickerDisplayItem(name: "Xe máy điện DAT BIKE QUANTUM", productImage: bikeImage, descriptor: desc1),
            ASPickerDisplayItem(name: "Xe máy điện DAT BIKE QUANTUM", productImage: bikeImage, descriptor: desc2),
            ASPickerDisplayItem(name: "Xe máy điện DAT BIKE QUANTUM", productImage: bikeImage, descriptor: desc3),
            ASPickerDisplayItem(name: "Xe máy điện DAT BIKE QUANTUM", productImage: bikeImage, descriptor: desc4),
        ]
        
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "ASKManager: Kích hoạt System Picker (Dat Bike)"))
        
        session?.showPicker(for: items) { [weak self] error in
            if let error = error {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning, message: "ASK showPicker lỗi hoặc user huỷ: \(error.localizedDescription)"))
                self?.onPickerDismissed?(error)
            }
        }
        #else
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning, message: "AccessorySetupKit không được hỗ trợ trên thiết bị này"))
        self.onPickerDismissed?(nil)
        #endif
    }
    
    
    func removeAccessory(withUUID uuidString: String) {
        #if canImport(AccessorySetupKit)
        guard let targetUUID = UUID(uuidString: uuidString) else { return }
        let accessories = session?.accessories ?? []
        for accessory in accessories {
            if accessory.bluetoothIdentifier == targetUUID {
                Task {
                    // Xoá thiết bị khỏi ASK (Apple đã đổi hàm này thành async throws trên iOS 18)
                    try? await session?.removeAccessory(accessory)
                }
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "ASKManager: Đã yêu cầu xóa (Unpair) phụ kiện \(uuidString) khỏi hệ thống iOS"))
            }
        }
        #endif
    }
    
    #if canImport(AccessorySetupKit)
    private func handleSessionEvent(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .accessoryAdded, .accessoryChanged:
            if let accessory = event.accessory, let uuid = accessory.bluetoothIdentifier {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "ASK Event: Đã xác nhận thiết bị (UUID: \(uuid.uuidString))"))
                
                self.onAccessorySelected?(uuid)
            }
        case .accessoryRemoved:
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning, message: "ASK Event: Thiết bị bị gỡ bỏ"))
        case .activated:
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "ASK Event: Session Activated"))
        case .invalidated:
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning, message: "ASK Event: Session Invalidated"))
        @unknown default:
            break
        }
    }
    #endif
}
