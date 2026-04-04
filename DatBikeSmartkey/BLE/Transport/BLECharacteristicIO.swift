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
        
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let old = readContinuations[characteristic.uuid] {
                    print("⚠️ [BLE_IO] CẢNH BÁO ĐÈ LỆNH VÀ LEAK: Đang có luồng truy cập Read cho \(characteristic.uuid) bị huỷ đè!")
                    old.resume(throwing: CancellationError())
                }
                readContinuations[characteristic.uuid] = continuation
                peripheral.readValue(for: characteristic)
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelRead(for: characteristic.uuid) }
        }
    }
    
    func writeValue(_ data: Data, to characteristic: CBCharacteristic, type: CBCharacteristicWriteType = .withResponse) async throws {
        if peripheral.state != .connected { throw IoTError.notConnected }
        
        if type == .withResponse {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if let old = writeContinuations[characteristic.uuid] {
                        print("⚠️ [BLE_IO] CẢNH BÁO ĐÈ LỆNH VÀ LEAK: Đang có luồng truy cập Write cho \(characteristic.uuid) bị huỷ đè!")
                        old.resume(throwing: CancellationError())
                    }
                    writeContinuations[characteristic.uuid] = continuation
                    peripheral.writeValue(data, for: characteristic, type: type)
                }
            } onCancel: {
                Task { [weak self] in await self?.cancelWrite(for: characteristic.uuid) }
            }
        } else {
            peripheral.writeValue(data, for: characteristic, type: type)
        }
    }
    
    // MARK: - Cancellation Lifecycle
    func cancelRead(for targetUUID: CBUUID) {
        guard let continuation = readContinuations.removeValue(forKey: targetUUID) else { return }
        continuation.resume(throwing: CancellationError())
    }
    
    func cancelWrite(for targetUUID: CBUUID) {
        guard let continuation = writeContinuations.removeValue(forKey: targetUUID) else { return }
        continuation.resume(throwing: CancellationError())
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
