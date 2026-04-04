import Foundation
import CoreBluetooth
import Combine

/// Vòng lặp Timers chuyên trách để đọc thông số liên tục (RSSI, Telemetry, Echo)
/// khi xe đang trong trạng thái kết nối.
class BLEPollingEngine {
    
    private let context: BLEConnectionContext
    
    private var rssiTimer: Timer?
    private var keepAliveTimer: Timer?
    
    // Publishers
    @Published private(set) var currentRSSI: Double = 0.0
    
    init(context: BLEConnectionContext) {
        self.context = context
    }
    
    func startPolling() {
        stopPolling()
        
        // 1. RSSI Polling
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.rssiTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.context.peripheral.readRSSI()
            }
        }
        
        // 2. Keep-Alive / Telemetry Polling
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                // Đẩy vào Queue để đọc an toàn
                Task {
                    do {
                        let echoChar = try self.context.requireCharacteristic(BLECharacteristic.smartkeyEcho)
                        let _ = try await self.context.io.readValue(from: echoChar)
                    } catch {
                        // Bỏ qua lỗi Keep Alive tạm thời
                    }
                }
            }
        }
    }
    
    func stopPolling() {
        DispatchQueue.main.async { [weak self] in
            self?.rssiTimer?.invalidate()
            self?.rssiTimer = nil
            self?.keepAliveTimer?.invalidate()
            self?.keepAliveTimer = nil
        }
    }
    
    // Được Delegate CBPeripheralDelegate gọi lại
    func didReadRSSI(value: Double) {
        self.currentRSSI = value
    }
}
