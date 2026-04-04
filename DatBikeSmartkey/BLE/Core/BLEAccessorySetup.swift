import Foundation
import AccessorySetupKit
import CoreBluetooth

protocol BLEAccessorySetupDelegate: AnyObject {
    func didAuthorizeAccessory(_ accessory: ASAccessory)
    func didRemoveAccessory()
    func didFailToAuthorize(error: Error)
}

/// Đóng gói hoàn toàn logic của AccessorySetupKit (Giao diện ghép đôi chuẩn iOS 18+)
class BLEAccessorySetup: NSObject {
    private let session = ASAccessorySession()
    private(set) var currentAccessory: ASAccessory?
    
    weak var delegate: BLEAccessorySetupDelegate?
    
    // Config các UUID để iOS filter các thiết bị có thể add.
    let companyID = "0000" // Replace if needed
    
    override init() {
        super.init()
    }
    
    func activate() {
        session.activate(on: .main) { [weak self] event in
            self?.handleEvent(event)
        }
    }
    
    func showPicker() {
        // Build descriptors for Dat Bike UUIDs
        let datbike1 = ASPickerDisplayItem(name: "Dat Bike", productImage: UIImage(systemName: "bicycle")!, descriptor: ASDiscoveryDescriptor())
        let datbike2 = ASPickerDisplayItem(name: "MyBike", productImage: UIImage(systemName: "bicycle")!, descriptor: ASDiscoveryDescriptor())
        
        session.showPicker(for: [datbike1, datbike2]) { [weak self] error in
            if let error = error {
                self?.delegate?.didFailToAuthorize(error: error)
            }
        }
    }
    
    func removeCurrentAccessory() {
        guard let accessory = currentAccessory else { return }
        session.removeAccessory(accessory) { [weak self] error in
            if error == nil {
                self?.currentAccessory = nil
                self?.delegate?.didRemoveAccessory()
            }
        }
    }
    
    private func handleEvent(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            if let existing = session.accessories.first {
                self.currentAccessory = existing
                delegate?.didAuthorizeAccessory(existing)
            }
        case .accessoryAdded, .accessoryChanged:
            if let accessory = event.accessory {
                self.currentAccessory = accessory
                delegate?.didAuthorizeAccessory(accessory)
            }
        case .accessoryRemoved:
            self.currentAccessory = nil
            delegate?.didRemoveAccessory()
        default:
            break
        }
    }
}
