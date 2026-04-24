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
        
        return try await withTimeout(seconds: 8) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if let old = self.readContinuations[characteristic.uuid] {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                            message: "[BLE_IO] Đè lệnh Read cho \(characteristic.uuid) — huỷ luồng cũ"))
                        old.resume(throwing: CancellationError())
                    }
                    self.readContinuations[characteristic.uuid] = continuation
                    self.peripheral.readValue(for: characteristic)
                }
            } onCancel: {
                Task { [weak self] in await self?.cancelRead(for: characteristic.uuid) }
            }
        }
    }
    
    func writeValue(_ data: Data, to characteristic: CBCharacteristic, type: CBCharacteristicWriteType = .withResponse) async throws {
        if peripheral.state != .connected { throw IoTError.notConnected }
        
        if type == .withResponse {
            try await withTimeout(seconds: 8) {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        if let old = self.writeContinuations[characteristic.uuid] {
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                                message: "[BLE_IO] Đè lệnh Write cho \(characteristic.uuid) — huỷ luồng cũ"))
                            old.resume(throwing: CancellationError())
                        }
                        self.writeContinuations[characteristic.uuid] = continuation
                        self.peripheral.writeValue(data, for: characteristic, type: type)
                    }
                } onCancel: {
                    Task { [weak self] in await self?.cancelWrite(for: characteristic.uuid) }
                }
            }
        } else {
            peripheral.writeValue(data, for: characteristic, type: type)
        }
    }
    
    // MARK: - Timeout Helper
    
    /// Timeout wrapper: throw IoTError.commandTimeout nếu operation không hoàn thành trong `seconds` giây.
    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw IoTError.commandTimeout
            }
            // Lấy kết quả task nào xong trước, hủy task còn lại
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw IoTError.commandTimeout }
            return result
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
