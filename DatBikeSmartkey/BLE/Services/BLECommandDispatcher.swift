import Foundation
import CoreBluetooth

/// Vận hành các lệnh tương tác vật lý với xe. Được bơm 1 ConnectionContext.
/// Tuân thủ Dependency Injection nguyên thuỷ.
class BLECommandDispatcher: IoTCommandService {
    
    private let context: BLEConnectionContext
    
    init(context: BLEConnectionContext) {
        self.context = context
    }
    
    // MARK: - Vehicle Control
    
    /// Bật xe: ghi 0x31 → unlockCmd, poll cho đến khi xe unlock (0x02)
    func turnOnBike() async throws -> IoTLockState {
        let char = try context.requireCharacteristic(BLECharacteristic.unlockCmd)
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "CMD: BẬT XE (0x31 → unlockCmd)"))
        try await context.queue.enqueue {
            try await self.context.io.writeValue(BLECommand.powerOn, to: char, type: .withResponse)
        }
        return try await pollLockStatus(until: { $0 == .unlocked }, label: "BẬT XE")
    }
    
    /// Tắt xe: ghi 0x30 → unlockCmd, poll cho đến khi xe lock (0x00)
    func turnOffBike() async throws -> IoTLockState {
        let char = try context.requireCharacteristic(BLECharacteristic.unlockCmd)
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "CMD: TẮT XE (0x30 → unlockCmd)"))
        try await context.queue.enqueue {
            try await self.context.io.writeValue(BLECommand.powerOff, to: char, type: .withResponse)
        }
        return try await pollLockStatus(until: { $0 == .locked }, label: "TẮT XE")
    }
    
    /// Chống trộm (Arm): ghi 0x31 → smartkeyEcho, poll cho đến khi armed
    func armAntiTheft() async throws -> IoTLockState {
        let char = try context.requireCharacteristic(BLECharacteristic.smartkeyEcho)
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "CMD: CHỐNG TRỘM (0x31 → smartkeyEcho)"))
        try await context.queue.enqueue {
            try await self.context.io.writeValue(BLECommand.lock, to: char, type: .withResponse)
        }
        return try await pollLockStatus(until: { $0 == .locked || $0 == .armed }, label: "CHỐNG TRỘM")
    }
    
    /// Toggle: dựa trên state hiện tại → bật hoặc tắt
    func toggleLock(currentState: IoTLockState) async throws -> IoTLockState {
        if currentState == .locked || currentState == .armed {
            return try await turnOnBike()
        } else {
            return try await turnOffBike()
        }
    }
    
    // MARK: - Other Commands
    
    func findBike(start: Bool) async throws {
        try await context.queue.enqueue {
            let char = try self.context.requireCharacteristic(BLECharacteristic.findBike)
            let cmd = start ? BLECommand.findStart : BLECommand.findStop
            try await self.context.io.writeValue(cmd, to: char, type: .withResponse)
        }
    }
    
    func syncTime() async throws {
        try await context.queue.enqueue {
            let syncChar = try self.context.requireCharacteristic(BLECharacteristic.timeSync)
            let vnTZ = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = vnTZ
            let now = Date()
            
            let comps = cal.dateComponents([.hour, .minute, .second], from: now)
            let secs = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
            let value = String(secs)
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "TIME_SYNC = \(value) (\(comps.hour ?? 0):\(String(format: "%02d", comps.minute ?? 0)):\(String(format: "%02d", comps.second ?? 0)) VN)"))
            try await self.context.io.writeValue(Data(value.utf8), to: syncChar, type: .withResponse)
        }
    }
    
    // MARK: - Lock Status Polling
    
    /// Đọc lock status 1 lần từ smartkeyEcho
    func readLockStatus() async throws -> IoTLockState {
        let char = try context.requireCharacteristic(BLECharacteristic.smartkeyEcho)
        let data = try await context.queue.enqueue {
            try await self.context.io.readValue(from: char)
        }
        let status = IoTLockState.parse(from: data)
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "Lock status: \(status.description) (raw: \(data.hexString))"))
        return status
    }
    
    /// Poll readLockStatus mỗi 400ms cho đến khi predicate đúng hoặc hết 8 attempts.
    private func pollLockStatus(
        until predicate: @escaping (IoTLockState) -> Bool,
        label: String,
        attempts: Int = 8,
        initialDelayMs: UInt64 = 400,
        intervalMs: UInt64 = 400
    ) async throws -> IoTLockState {
        // Delay ban đầu để firmware kịp xử lý lệnh
        try await Task.sleep(nanoseconds: initialDelayMs * 1_000_000)
        
        var lastStatus: IoTLockState = .unknown(Data())
        
        for i in 0..<attempts {
            if i > 0 {
                try await Task.sleep(nanoseconds: intervalMs * 1_000_000)
            }
            
            lastStatus = try await readLockStatus()
            
            if predicate(lastStatus) {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                    message: "[\(label)] Xe xác nhận trạng thái sau \(i + 1) lần poll ✅"))
                return lastStatus
            }
            
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[\(label)] Poll \(i + 1)/\(attempts): \(lastStatus.description) — chờ..."))
        }
        
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
            message: "[\(label)] Hết \(attempts) lần poll — trạng thái hiện tại: \(lastStatus.description)"))
        return lastStatus
    }
}
