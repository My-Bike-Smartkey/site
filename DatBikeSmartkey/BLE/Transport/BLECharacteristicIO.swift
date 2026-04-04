import Foundation
import CoreBluetooth

/// Cỗ máy I/O Độc lập. Không chứa logic xe, chỉ giải quyết nghiệp vụ:
/// "Tôi cần gửi mảng Byte này tới Characteristic này, hãy cho tôi Continuation để chờ ACK".
/// Có thể sử dụng lại cho hàng trăm xe khác nhau, mỗi xe khởi tạo 1 class này đính kèm Peripheral.
actor BLECharacteristicIO {
    
    private let peripheral: CBPeripheral
    
    // Nơi cất giữ các luồng đang chờ Callbacks từ Delegate.
    private var readContinuations: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var writeContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    
    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
    }
    
    // MARK: - Core I/O
    
    func readValue(from characteristic: CBCharacteristic) async throws -> Data {
        if peripheral.state != .connected { throw IoTError.notConnected }
        
        return try await withCheckedThrowingContinuation { continuation in
            readContinuations[characteristic.uuid] = continuation
            peripheral.readValue(for: characteristic)
        }
    }
    
    func writeValue(_ data: Data, to characteristic: CBCharacteristic, type: CBCharacteristicWriteType = .withResponse) async throws {
        if peripheral.state != .connected { throw IoTError.notConnected }
        
        if type == .withResponse {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writeContinuations[characteristic.uuid] = continuation
                peripheral.writeValue(data, for: characteristic, type: type)
            }
        } else {
            peripheral.writeValue(data, for: characteristic, type: type)
        }
    }
    
    // MARK: - Delegate Bơm ngược (Feedbacks)
    
    /// Nhận tín hiệu từ CBPeripheralDelegate truyền vào (để resume async).
    func didReceiveReadResponse(for characteristic: CBCharacteristic, error: Error?) {
        guard let continuation = readContinuations.removeValue(forKey: characteristic.uuid) else { return }
        
        if let error = error {
            continuation.resume(throwing: error)
        } else if let value = characteristic.value {
            continuation.resume(returning: value)
        } else {
            continuation.resume(throwing: IoTError.invalidResponseFormat)
        }
    }
    
    func didReceiveWriteResponse(for characteristic: CBCharacteristic, error: Error?) {
        guard let continuation = writeContinuations.removeValue(forKey: characteristic.uuid) else { return }
        
        if let error = error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: ())
        }
    }
    
    func cancelAll() {
        for (_, cont) in readContinuations { cont.resume(throwing: IoTError.notConnected) }
        for (_, cont) in writeContinuations { cont.resume(throwing: IoTError.notConnected) }
        readContinuations.removeAll()
        writeContinuations.removeAll()
    }
}
