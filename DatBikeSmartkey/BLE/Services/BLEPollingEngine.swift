import Foundation
import CoreBluetooth
import Combine

/// Vòng lặp Timers chuyên trách để đọc thông số liên tục (RSSI, Telemetry, Echo)
/// khi xe đang trong trạng thái kết nối.
class BLEPollingEngine {
    
    private let context: BLEConnectionContext
    
    private var pollingTask: Task<Void, Never>?
    
    // Publishers
    @Published private(set) var currentRSSI: Double = 0.0
    
    init(context: BLEConnectionContext) {
        self.context = context
    }
    
    func startPolling() {
        stopPolling()
        
        pollingTask = Task { [weak self] in
            guard let self = self else { return }
            
            // Chạy 2 vòng lặp bất đồng bộ song song cho RSSI và Keep-Alive
            await withTaskGroup(of: Void.self) { group in
                
                // Vòng lặp 1: RSSI Polling (Mỗi 1s)
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        self?.context.peripheral.readRSSI() // Lệnh này không qua CharacteristicIO nên không cần Enqueue
                        do {
                            // Sleep 1s (Swift 6 chuẩn)
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                        } catch { break }
                    }
                }
                
                // Vòng lặp 2: Keep-Alive / Telemetry (Mỗi 30s)
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(nanoseconds: 30_000_000_000) // Sleep 30s
                            guard let self = self else { break }
                            
                            // ĐẨY VÀO QUEUE ĐỂ ĐẢM BẢO KHÔNG XUNG ĐỘT (GATT COLLISION)
                            let _ = try await self.context.queue.enqueue {
                                let echoChar = try self.context.requireCharacteristic(BLECharacteristic.smartkeyEcho)
                                return try await self.context.io.readValue(from: echoChar)
                            }
                        } catch {
                            // Bỏ qua lỗi huỷ hoặc kẹt BLE
                            if error is CancellationError { break }
                        }
                    }
                }
            }
        }
    }
    
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
    
    // Được Delegate CBPeripheralDelegate gọi lại
    func didReadRSSI(value: Double) {
        self.currentRSSI = value
    }
}
