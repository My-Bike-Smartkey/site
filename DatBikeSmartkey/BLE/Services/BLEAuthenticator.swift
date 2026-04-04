import Foundation
import CoreBluetooth

class BLEAuthenticator: IoTAuthService {
    
    private let context: BLEConnectionContext
    private let pin: String
    
    init(context: BLEConnectionContext, pin: String) {
        self.context = context
        self.pin = pin
    }
    
    func authenticate() async throws -> Bool {
        // Luồng xác thực 5 bước, phải tống vào Queue để chống phân mảnh package
        return try await context.queue.enqueue {
            do {
                let authChar = try self.context.requireCharacteristic(BLECharacteristic.authChallenge)
                let sessionChar = try self.context.requireCharacteristic(BLECharacteristic.sessionToken)
                let proximityChar = try self.context.requireCharacteristic(BLECharacteristic.autoUnlock)
                
                // 1. Phác thảo SHA-256 (Challenge / Response)
                let challengeBytes = try await self.context.io.readValue(from: authChar)
                let hashHexString = try BLECryptography.solveChallenge(challengeBytes: challengeBytes, pin: self.pin)
                guard let hashData = hashHexString.data(using: .utf8) else { throw IoTError.invalidResponseFormat }
                try await self.context.io.writeValue(hashData, to: authChar, type: .withResponse)
                
                // 2. Viết Session Token
                let randomSession = String(format: "%05d", Int.random(in: 10000...99999))
                if let tData = randomSession.data(using: .utf8) {
                    try await self.context.io.writeValue(tData, to: sessionChar, type: .withResponse)
                }
                
                // 3. Viết Proximity Token (Dùng lưu trữ local làm token)
                // Giả lập lấy UUID từ Defaults hoặc Keychain (trong Layer tiếp theo sẽ tiêm dependency)
                let proxString = UUID().uuidString
                if let pData = proxString.data(using: .utf8) {
                    try await self.context.io.writeValue(pData, to: proximityChar, type: .withResponse)
                }
                
                return true
            } catch {
                throw IoTError.shaChallengeFailed
            }
        }
    }
}
