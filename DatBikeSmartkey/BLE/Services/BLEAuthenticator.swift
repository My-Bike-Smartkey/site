import Foundation
import CoreBluetooth

class BLEAuthenticator: IoTAuthService {
    
    private let context: BLEConnectionContext
    private let pin: String
    private let isKnownDevice: Bool
    
    init(context: BLEConnectionContext, pin: String, isKnownDevice: Bool) {
        self.context = context
        self.pin = pin
        self.isKnownDevice = isKnownDevice
    }
    
    func authenticate() async throws -> Bool {
        let authChar = try context.requireCharacteristic(BLECharacteristic.authChallenge)
        let pinData = Data(pin.utf8)
        
        if isKnownDevice {
            // ── RECONNECT FLOW (SHA-256 + Counter Verification) ──
            try await authenticateWithSHA(authChar: authChar)
        } else {
            // ── PAIRING FLOW (NFC PIN plain-text) ──
            try await pairWithPIN(authChar: authChar, pinData: pinData)
        }
        
        // ── TIME SYNC (44e2bde6) — seconds since midnight UTC+7 ──
        if let syncChar = try? context.requireCharacteristic(BLECharacteristic.timeSync) {
            let vnTZ = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = vnTZ
            let comps = cal.dateComponents([.hour, .minute, .second], from: Date())
            let secs = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
            let timeSyncValue = String(secs)
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "Auth: TIME_SYNC = \(timeSyncValue) (\(comps.hour ?? 0):\(String(format: "%02d", comps.minute ?? 0)):\(String(format: "%02d", comps.second ?? 0)) VN)"))
            try? await context.io.writeValue(Data(timeSyncValue.utf8), to: syncChar, type: .withResponse)
        }
        
        // ── PROXIMITY TOKEN ──
        if let autoChar = try? context.requireCharacteristic(BLECharacteristic.autoUnlock) {
            let token = UUID().uuidString
            try? await context.io.writeValue(Data(token.utf8), to: autoChar, type: .withResponse)
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "Auth: Proximity token set"))
        }
        
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
            message: "Auth hoàn tất thành công ✅"))
        return true
    }
    
    // MARK: - SHA-256 Reconnect Flow
    
    private func authenticateWithSHA(authChar: CBCharacteristic) async throws {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "Auth: SHA-256 reconnect mode. PIN=\(pin)"))
        
        // 1. Read challenge (counter)
        let challengeData = try await context.queue.enqueue {
            try await self.context.io.readValue(from: authChar)
        }
        guard challengeData.count >= 4 else {
            throw IoTError.invalidResponseFormat
        }
        
        let currentCounter = challengeData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "Auth: Challenge counter = \(currentCounter) (raw: \(challengeData.prefix(4).hexString))"))
        
        // 2. SHA-256(counter >> 1 + PIN)
        let hashHexStr = try BLECryptography.solveChallenge(challengeBytes: challengeData, pin: pin)
        
        // 3. Write hash tức thì — không đợi
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "Auth: Gửi hash response..."))
        try await context.queue.enqueue {
            try await self.context.io.writeValue(Data(hashHexStr.utf8), to: authChar, type: .withResponse)
        }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "Auth: Hash write ACK nhận. Verify counter (lẻ = thành công)..."))
        
        // 4. Verify counter chuyển sang LẺ — retry với delay tăng dần
        // Rule: counter CHẴN = chờ xác thực, counter LẺ = đã xác thực
        // Thành công = counter chuyển từ chẵn → lẻ
        let retryDelays: [UInt64] = [200, 400, 700, 1200]
        var authVerified = false
        var latestVerifiedCounter: UInt32? = nil
        
        for (attempt, delayMs) in retryDelays.enumerated() {
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            
            let verifyData = try await context.queue.enqueue {
                try await self.context.io.readValue(from: authChar)
            }
            guard verifyData.count >= 4 else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "Auth verify \(attempt+1): response ngắn (\(verifyData.count)b), retry..."))
                continue
            }
            
            let newCounter = verifyData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            latestVerifiedCounter = newCounter
            
            let isOdd = newCounter % 2 != 0
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "Auth verify \(attempt+1): counter \(currentCounter) → \(newCounter) (\(isOdd ? "lẻ ✓" : "chẵn ✗"))"))
            
            if isOdd {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                    message: "Auth: Counter lẻ → xác thực thành công ✅"))
                authVerified = true
                break
            }
            
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "Auth verify \(attempt+1): counter vẫn chẵn (\(newCounter)), chờ lâu hơn..."))
        }
        
        if !authVerified {
            // Kiểm tra: counter CÓ THAY ĐỔI không? Nếu nhảy sang chẵn MỚI → xe từ chối hash
            // nhưng sẵn sàng cho lần auth mới → retry 1 lần với counter mới
            if let latestCounter = latestVerifiedCounter {
                if latestCounter != currentCounter && latestCounter % 2 == 0 {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "Auth: Counter nhảy \(currentCounter) → \(latestCounter) (chẵn mới) — retry auth với counter mới"))
                    // Retry 1 lần với counter mới
                    try await retrySHAWithNewCounter(authChar: authChar, newCounter: latestCounter)
                    return
                }
            }
            
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "Auth: Counter vẫn chẵn sau \(retryDelays.count) lần verify — xác thực thất bại."))
            throw IoTError.shaChallengeFailed
        }
    }
    
    /// Retry SHA auth 1 lần khi counter nhảy sang chẵn mới (xe từ chối hash trước đó)
    private func retrySHAWithNewCounter(authChar: CBCharacteristic, newCounter: UInt32) async throws {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "Auth retry: counter = \(newCounter), tính hash mới..."))
        
        // Tạo challenge data giả từ counter mới
        var counterLE = newCounter.littleEndian
        let challengeData = Data(bytes: &counterLE, count: 4)
        
        let hashHexStr = try BLECryptography.solveChallenge(challengeBytes: challengeData, pin: pin)
        
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "Auth retry: Gửi hash response..."))
        try await context.queue.enqueue {
            try await self.context.io.writeValue(Data(hashHexStr.utf8), to: authChar, type: .withResponse)
        }
        
        // Verify counter chuyển lẻ
        let retryDelays: [UInt64] = [300, 600, 1000, 1500]
        for (attempt, delayMs) in retryDelays.enumerated() {
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            
            let verifyData = try await context.queue.enqueue {
                try await self.context.io.readValue(from: authChar)
            }
            guard verifyData.count >= 4 else { continue }
            
            let counter = verifyData.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let isOdd = counter % 2 != 0
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "Auth retry verify \(attempt+1): counter \(newCounter) → \(counter) (\(isOdd ? "lẻ ✓" : "chẵn ✗"))"))
            
            if isOdd {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                    message: "Auth retry: Counter lẻ → xác thực thành công ✅"))
                return
            }
        }
        
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
            message: "Auth retry: Vẫn thất bại sau retry — cần quẹt thẻ NFC."))
        throw IoTError.shaChallengeFailed
    }
    
    // MARK: - NFC Pairing Flow
    
    private func pairWithPIN(authChar: CBCharacteristic, pinData: Data) async throws {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "Auth: Pairing mode — chờ quẹt NFC..."))
        
        // Retry PIN write: mỗi 2s × 10 lần (tổng 20s timeout)
        var isPaired = false
        for i in 1...10 {
            do {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "Auth: Ghi PIN... (\(i)/10)"))
                try await context.queue.enqueue {
                    try await self.context.io.writeValue(pinData, to: authChar, type: .withResponse)
                }
                isPaired = true
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                    message: "Auth: Ghép đôi hoàn tất!"))
                break
            } catch {
                if i < 10 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
        
        if !isPaired {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "Auth: Ghép đôi thất bại — hết 20s timeout"))
            throw IoTError.shaChallengeFailed
        }
        
        // PIN confirm lần 1
        try? await context.queue.enqueue {
            try await self.context.io.writeValue(pinData, to: authChar, type: .withResponse)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // PIN confirm lần 2
        try? await context.queue.enqueue {
            try await self.context.io.writeValue(pinData, to: authChar, type: .withResponse)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
    }
}
