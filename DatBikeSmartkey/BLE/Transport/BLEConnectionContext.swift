import Foundation
import CoreBluetooth

/// Đại diện 1:1 cho một chiếc xe vật lý trong môi trường kết nối.
/// Đóng gói CBPeripheral và các hệ thống Input/Output của riêng nó.
class BLEConnectionContext {
    let peripheral: CBPeripheral
    
    /// Hàng đợi lệnh ngăn chặn GATT Collision (Bảo đảm không gọi Read/Write đè lên nhau)
    let queue: BLETaskQueue
    
    /// Động cơ trao đổi Byte ở dạng Async Await
    let io: BLECharacteristicIO
    
    /// Danh mục các nốt (Characteristic) đã được dò tìm thành công
    private(set) var discoveredCharacteristics: [CBUUID: CBCharacteristic] = [:]
    
    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        self.queue = BLETaskQueue()
        self.io = BLECharacteristicIO(peripheral: peripheral)
    }
    
    // MARK: - Registry
    
    func register(characteristic: CBCharacteristic) {
        discoveredCharacteristics[characteristic.uuid] = characteristic
    }
    
    func requireCharacteristic(_ uuid: CBUUID) throws -> CBCharacteristic {
        guard let char = discoveredCharacteristics[uuid] else {
            throw IoTError.characteristicNotFound(uuid.uuidString)
        }
        return char
    }
    
    // MARK: - Teardown
    
    /// Dọn dẹp toàn bộ state — phiên bản sync (fire-and-forget) cho các call sites không cần đợi.
    func clearState() {
        discoveredCharacteristics.removeAll()
        Task {
            await io.cancelAll()
            await queue.cancelAll()
        }
    }
    
    /// Dọn dẹp toàn bộ state — phiên bản async đảm bảo io/queue đã cancel xong trước khi return.
    func clearStateAsync() async {
        discoveredCharacteristics.removeAll()
        await io.cancelAll()
        await queue.cancelAll()
    }
}
